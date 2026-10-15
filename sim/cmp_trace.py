#!/usr/bin/env python3
"""RTL と命令シミュレータのトレースを、書き込みの列として先頭から比べ、最初に食い違った所を表示する

    python3 cmp_trace.py rtl.trace sim.trace [-n 文脈の行数]

RTL のトレース（tb_cpu.cpp の +trace=）は書き込みだけを命令順に 1 行ずつ書く。
sim のトレース（--trace）は命令 1 個につき 1 行なので、次のように揃えてから比べる。
  - "#" 以降（サイクル数・pc など）は比べない（RTL の +trace_mode=cycle でも commit でも比べられる）
  - "pc=..." と "ins=..." は消す
  - x0 / f0 への書き込みは消す（何も変えないので RTL 側は報告しない）
  - 書き込みが残らなかった行（分岐など）は飛ばす
  - "halt ..." は "halt" にする
ファイルの代わりに名前付きパイプ (mkfifo) を渡せば、巨大なトレースも保存せずに比べられる。
"""
import argparse
import collections
import itertools
import re
import sys

ZERO_REG = re.compile(r"^[xf]00=")


def writes(f):
    """(元の行, 比較用の文字列) を順に返す"""
    for line in f:
        body = line.split("#", 1)[0].strip()
        if not body:
            continue
        if body.startswith("halt"):
            yield line.rstrip(), "halt"
            continue
        toks = [t for t in body.split() if not t.startswith(("pc=", "ins=")) and not ZERO_REG.match(t)]
        if toks:
            yield line.rstrip(), " ".join(toks)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rtl")
    ap.add_argument("sim")
    ap.add_argument("-n", type=int, default=10, help="不一致の手前に表示する行数")
    args = ap.parse_args()

    hist = collections.deque(maxlen=args.n)
    n = 0
    eof = ("<EOF>", "<EOF>")
    with open(args.rtl) as fr, open(args.sim) as fs:
        for n, ((lr, kr), (ls, ks)) in enumerate(itertools.zip_longest(writes(fr), writes(fs), fillvalue=eof)):
            if kr != ks:
                print(f"MISMATCH at write #{n}")
                for h in hist:
                    print("       ", h)
                print("  rtl: ", lr)
                print("  sim: ", ls)
                sys.exit(1)
            hist.append(f"{lr}    | sim: {ls}")
    print(f"trace: OK ({n + 1} lines)")


if __name__ == "__main__":
    main()
