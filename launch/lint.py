#!/usr/bin/env python3
"""リポジトリ内のコードをまとめて静的チェックする（WSL で動かす。Verilator を使うので）

    make lint                         全部（Windows の make から。中で wsl python3 launch/lint.py を呼ぶ）
    make lint iq_top                  iq_top から下の階層だけ（backend は backend_top、top は全体の top）
    make lint iq_top ALL=1 STRICT=1   オプションは ALL=1（-a）、STRICT=1（--strict）、V=1（-v）

    python3 launch/lint.py [モジュール]   WSL で直接
    --strict   style も失敗扱いにする
    -a         note（未使用信号など）も表示
    -v         ツールの生の出力も表示

モジュールを指定したときは、そのモジュールから下の階層のファイルだけを見る
（.xpr との対応、テストベンチ、Python のチェックはしない）

チェック内容
  1. Vivado プロジェクト (.xpr) とファイルの対応   追加し忘れ・消し忘れ
  2. 書き方の規約                                  `default_nettype none / wire
  3. Verilator lint (-Wall)                        合成対象 (src/) と テストベンチ (sim/)
  4. Verible lint                                  スタイル（入っていれば）
  5. Python                                        構文チェック（pyflakes があれば未定義名なども）

レベル
  error  コンパイルが通らない・プロジェクトの不整合        → 失敗
  warn   Verilator の警告（幅の不一致・ラッチなど、だいたいバグ）→ 失敗
  style  スタイル・規約（Verible など）                    → --strict のときだけ失敗
  note   未使用信号など、作りかけなら出て当然のもの        → 失敗しない

終了コード: 0 = 問題なし、1 = 失敗
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict

# このファイルは launch/ の中にある。ROOT はリポジトリ直下
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Verilator の警告のうち、失敗にはせず「注意」として出すもの
SOFT_RULES = {"UNUSEDSIGNAL", "UNUSEDPARAM", "UNUSEDGENVAR", "UNUSED", "DECLFILENAME", "PINCONNECTEMPTY"}
# そもそも出さないもの（パッケージに `timescale が無いのは問題ない）
OFF_RULES = ["TIMESCALEMOD", "MULTITOP"]

# Vivado IP の代わりにする空モジュール（中身はシミュレーションできないので形だけ）
IP_STUBS = {
    "clk_wiz_0": """
module clk_wiz_0 (
  output logic clk_out1, output logic clk_out2, output logic locked,
  input  logic reset,    input  logic clk_in1
);
  assign clk_out1 = clk_in1;
  assign clk_out2 = clk_in1;
  assign locked   = ~reset;
endmodule
""",
}

USE_COLOR = sys.stdout.isatty()


def color(s, c):
    codes = {"red": 31, "yellow": 33, "green": 32, "cyan": 36, "bold": 1, "dim": 2}
    return f"\033[{codes[c]}m{s}\033[0m" if USE_COLOR else s


def rel(p):
    p = os.path.abspath(p)
    return os.path.relpath(p, ROOT) if p.startswith(ROOT) else p


class Report:
    def __init__(self):
        self.items = []  # (level, tool, file, line, msg)

    def add(self, level, tool, file, line, msg):
        self.items.append((level, tool, rel(file) if file else "", line, msg))

    def count(self, level):
        return sum(1 for it in self.items if it[0] == level)

    def print(self, show_notes):
        by_file = defaultdict(list)
        for it in self.items:
            if it[0] == "note" and not show_notes:
                continue
            by_file[it[2]].append(it)
        for f in sorted(by_file, key=lambda x: (x == "", x)):
            print(color(f or "(全体)", "bold"))
            for level, tool, _, line, msg in sorted(by_file[f], key=lambda x: (x[3] or 0)):
                tag = {"error": color("error", "red"), "warn": color("warn ", "yellow"),
                       "style": color("style", "cyan"), "note": color("note ", "dim")}[level]
                loc = f"{line:>4}" if line else "    "
                print(f"  {loc}  {tag}  {msg}  {color('[' + tool + ']', 'dim')}")
            print()


# ---------------------------------------------------------------------------
# ファイル集め
# ---------------------------------------------------------------------------
# ビルドに使っていない他の班員のリポジトリ（中身は向こうの担当なので見ない）
SKIP_DIRS = ["memory_repository"]


def sv_files(subdir):
    files = sorted(glob.glob(os.path.join(ROOT, subdir, "**", "*.sv"), recursive=True))
    return [f for f in files if os.sep + "ip" + os.sep not in f
            and not any(os.sep + d + os.sep in f for d in SKIP_DIRS)]


def order_packages(files):
    """package を import の依存順に並べ、その後ろに残りのファイルを置く"""
    pkgs, others = {}, []
    for f in files:
        text = open(f, encoding="utf-8", errors="replace").read()
        m = re.search(r"^\s*package\s+(\w+)\s*;", text, re.M)
        if m:
            deps = set(re.findall(r"\bimport\s+(\w+)::", text)) - {m.group(1)}
            pkgs[m.group(1)] = (f, deps)
        else:
            others.append(f)
    ordered, done = [], set()

    def visit(name, stack=()):
        if name in done or name not in pkgs:
            return
        if name in stack:
            raise SystemExit(f"package の循環 import: {' -> '.join(stack + (name,))}")
        for d in pkgs[name][1]:
            visit(d, stack + (name,))
        done.add(name)
        ordered.append(pkgs[name][0])

    for n in sorted(pkgs):
        visit(n)
    return ordered, others


def module_defs(files):
    """モジュール名 -> 定義しているファイル"""
    defs = {}
    for f in files:
        for m in re.findall(r"^\s*module\s+(\w+)", open(f, encoding="utf-8", errors="replace").read(), re.M):
            defs[m] = f
    return defs


def hierarchy_files(top, defs):
    """top から下の階層で使っているモジュールのファイル（インスタンスを正規表現で拾う）"""
    seen, files, stack = set(), set(), [top]
    while stack:
        name = stack.pop()
        if name in seen or name not in defs:
            continue
        seen.add(name)
        f = defs[name]
        files.add(f)
        text = re.sub(r"//.*", "", open(f, encoding="utf-8", errors="replace").read())
        m = re.search(r"^\s*module\s+" + name + r"\b(.*?)^\s*endmodule", text, re.M | re.S)
        body = m.group(1) if m else text
        for inst in re.findall(r"^\s*(\w+)\s*(?:#\s*\(|\w+\s*(?:\[[^\]]*\]\s*)?\()", body, re.M):
            if inst in defs and inst not in seen:
                stack.append(inst)
    return sorted(files)


def used_packages(pkgs, files):
    """files が使っている package（package が import しているものも含む）を pkgs の順のまま返す"""
    info = {}
    for f in pkgs:
        text = open(f, encoding="utf-8", errors="replace").read()
        name = re.search(r"^\s*package\s+(\w+)\s*;", text, re.M).group(1)
        info[name] = (f, set(re.findall(r"\b(\w+)::", text)) - {name})
    need, stack = set(), []
    for f in files:
        stack += re.findall(r"\b(\w+)::", open(f, encoding="utf-8", errors="replace").read())
    while stack:
        n = stack.pop()
        if n in info and n not in need:
            need.add(n)
            stack += list(info[n][1])
    return [f for f in pkgs if any(info[n][0] == f for n in need)]


# ---------------------------------------------------------------------------
# 1. Vivado プロジェクトとの対応
# ---------------------------------------------------------------------------
def check_xpr(rep):
    xprs = glob.glob(os.path.join(ROOT, "*.xpr"))
    if len(xprs) != 1:
        rep.add("note", "xpr", None, None, f".xpr が {len(xprs)} 個あるのでプロジェクトとの照合はスキップ")
        return
    xpr = xprs[0]
    text = open(xpr, encoding="utf-8", errors="replace").read()
    registered = {os.path.normpath(p) for p in re.findall(r'Path="\$PPRDIR/([^"]+)"', text)}
    on_disk = set()
    for ext in ("sv", "v", "svh", "vh", "xdc", "mem"):
        for f in glob.glob(os.path.join(ROOT, "src", "**", f"*.{ext}"), recursive=True):
            r = os.path.normpath(rel(f))
            # 他の班員のリポジトリ（*_repository）はプロジェクトに入れるかをビルドの側で決めるので見ない
            if not r.startswith(os.path.join("src", "ip")) and "_repository" not in r:
                on_disk.add(r)
    for f in sorted(on_disk - registered):
        rep.add("error", "xpr", f, None, "Vivado プロジェクトに追加されていない（Add Sources を忘れている）")
    for f in sorted(registered - on_disk):
        if not os.path.exists(os.path.join(ROOT, f)):
            rep.add("error", "xpr", xpr, None, f"プロジェクトに登録されているが存在しない: {f}")


# ---------------------------------------------------------------------------
# 2. 規約
# ---------------------------------------------------------------------------
def check_conventions(rep, files):
    for f in files:
        text = open(f, encoding="utf-8", errors="replace").read()
        if not re.search(r"^\s*module\s", text, re.M):
            continue  # package などはスキップ
        code = [ln for ln in text.splitlines() if ln.strip() and not ln.strip().startswith("//")]
        first_mod = next((i for i, ln in enumerate(code) if re.match(r"\s*module\s", ln)), len(code))
        if not any("`default_nettype none" in ln for ln in code[:first_mod]):
            rep.add("style", "規約", f, 1, "module の前に `default_nettype none が無い（typo の配線が暗黙の wire になる）")
        if code and "`default_nettype wire" not in code[-1]:
            rep.add("style", "規約", f, len(text.splitlines()),
                    "末尾に `default_nettype wire が無い（Xilinx IP など他のファイルに影響する）")


# ---------------------------------------------------------------------------
# 3. Verilator
# ---------------------------------------------------------------------------
VL_MSG = re.compile(r"^%(Error|Warning)(?:-(\w+))?: (?:(\S+?):(\d+):(?:\d+:)?\s*)?(.*)$")


def run_verilator(rep, files, label, extra, verbose):
    if not shutil.which("verilator"):
        rep.add("error", "verilator", None, None, "verilator が見つからない")
        return
    cmd = ["verilator", "--lint-only", "-Wall", *[f"-Wno-{r}" for r in OFF_RULES], *extra, *files]
    vlt = os.path.join(ROOT, "lint.vlt")
    if os.path.exists(vlt):
        cmd.insert(1, vlt)
    out = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT).stderr
    if verbose:
        print(color(f"$ {' '.join(cmd)}", "dim"))
        print(out)
    seen = set()
    for line in out.splitlines():
        m = VL_MSG.match(line)
        if not m:
            continue
        kind, rule, file, lno, msg = m.groups()
        if msg.startswith("Exiting due to") or (file is None and "See the manual" in msg):
            continue
        key = (rule, file, lno, msg)
        if key in seen:
            continue
        seen.add(key)
        if kind == "Error":
            level = "error"
        elif rule in SOFT_RULES:
            level = "note"
        else:
            level = "warn"
        tool = f"verilator:{label}" + (f" {rule}" if rule else "")
        rep.add(level, tool, file, int(lno) if lno else None, msg)


# ---------------------------------------------------------------------------
# 4. Verible
# ---------------------------------------------------------------------------
VB_MSG = re.compile(r"^(\S+?):(\d+):\d+(?:-\d+)?:\s*(.*?)\s*(?:\[Style: [^\]]*\])?\s*\[([\w-]+)\]$")


def run_verible(rep, files, verbose):
    exe = shutil.which("verible-verilog-lint")
    if not exe:
        rep.add("note", "verible", None, None, "verible-verilog-lint が無いのでスタイルチェックはスキップ")
        return
    cmd = [exe, "--rules_config_search", "--rules=+line-length=length:120", *files]
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    out = r.stdout + r.stderr
    if verbose:
        print(color(f"$ {' '.join(cmd)}", "dim"))
        print(out)
    for line in out.splitlines():
        m = VB_MSG.match(line)
        if m:
            file, lno, msg, rule = m.groups()
            rep.add("style", f"verible {rule}", file, int(lno), msg)
        elif "syntax error" in line:
            parts = line.split(":")
            rep.add("error", "verible", parts[0], int(parts[1]) if parts[1].isdigit() else None, line)


# ---------------------------------------------------------------------------
# 5. Python
# ---------------------------------------------------------------------------
def run_python(rep, verbose):
    files = [f for f in glob.glob(os.path.join(ROOT, "**", "*.py"), recursive=True)
             if not re.search(r"(obj_dir|\.runs|\.cache|\.sim|\.Xil|__pycache__)", f)]
    for f in files:
        r = subprocess.run([sys.executable, "-m", "py_compile", f], capture_output=True, text=True)
        if r.returncode:
            m = re.search(r'line (\d+)', r.stderr)
            rep.add("error", "python", f, int(m.group(1)) if m else None, r.stderr.strip().splitlines()[-1])
    r = subprocess.run([sys.executable, "-m", "pyflakes", "--version"], capture_output=True)
    if r.returncode == 0 and files:
        out = subprocess.run([sys.executable, "-m", "pyflakes", *files], capture_output=True, text=True).stdout
        if verbose:
            print(out)
        for line in out.splitlines():
            m = re.match(r"^(.+?):(\d+):(?:\d+:?)?\s*(.*)$", line)
            if m:
                rep.add("warn", "pyflakes", m.group(1), int(m.group(2)), m.group(3))


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--strict", action="store_true", help="style も失敗扱いにする")
    ap.add_argument("-a", "--all", action="store_true", help="note（未使用信号など）も表示")
    ap.add_argument("-v", "--verbose", action="store_true", help="各ツールの生の出力も表示")
    ap.add_argument("module", nargs="?", help="このモジュールから下の階層だけを見る（backend は backend_top）")
    args = ap.parse_args()

    rep = Report()
    src = sv_files("src")
    pkgs, mods = order_packages(src)
    tbs = sv_files("sim")

    if args.module:
        top = "backend_top" if args.module == "backend" else args.module
        defs = module_defs(mods)
        if top not in defs:
            raise SystemExit(f"モジュール {top} が src/ に無い")
        files = hierarchy_files(top, defs)
        print(color(f"{top} から下: {len(files)} ファイル（package {len(used_packages(pkgs, files))} 個）", "dim"))
        check_conventions(rep, files)
        with tempfile.TemporaryDirectory() as tmp:
            stubs = []
            for name, body in IP_STUBS.items():
                if name not in defs:
                    p = os.path.join(tmp, f"{name}.sv")
                    with open(p, "w") as fh:
                        fh.write(f"// verilator lint_off UNUSEDSIGNAL\n// verilator lint_off DECLFILENAME\n{body}")
                    stubs.append(p)
            # top から下のファイルだけを渡す（関係ないファイルの書きかけで止まらないように）
            run_verilator(rep, used_packages(pkgs, files) + files + stubs, top, ["--top-module", top], args.verbose)
        run_verible(rep, files, args.verbose)
        finish(rep, args)

    check_xpr(rep)
    check_conventions(rep, src)

    with tempfile.TemporaryDirectory() as tmp:
        defined = {m for f in mods for m in re.findall(r"^\s*module\s+(\w+)",
                                                       open(f, encoding="utf-8", errors="replace").read(), re.M)}
        stubs = []
        for name, body in IP_STUBS.items():
            if name not in defined:
                p = os.path.join(tmp, f"{name}.sv")
                with open(p, "w") as fh:
                    fh.write(f"// verilator lint_off UNUSEDSIGNAL\n// verilator lint_off DECLFILENAME\n{body}")
                stubs.append(p)

        # 合成対象：トップが複数あっても全部チェックされる
        run_verilator(rep, pkgs + mods + stubs, "src", [], args.verbose)

        # テストベンチ：1 本ずつトップにして（合成できない書き方も許す）
        for tb in tbs:
            text = open(tb, encoding="utf-8", errors="replace").read()
            m = re.search(r"^\s*module\s+(\w+)", text, re.M)
            if m:
                run_verilator(rep, pkgs + mods + stubs + [tb], os.path.basename(tb),
                              ["--timing", "--top-module", m.group(1), "-Wno-INITIALDLY"], args.verbose)

    run_verible(rep, src + tbs, args.verbose)
    run_python(rep, args.verbose)
    finish(rep, args)


def finish(rep, args):
    rep.print(args.all)
    e, w, s, n = (rep.count(x) for x in ("error", "warn", "style", "note"))
    summary = f"{e} error, {w} warning, {s} style, {n} note" + ("" if args.all or n == 0 else "（note は -a で表示）")
    failed = e > 0 or w > 0 or (args.strict and s > 0)
    print(color(("FAIL  " if failed else "OK    ") + summary, "red" if failed else "green"))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
