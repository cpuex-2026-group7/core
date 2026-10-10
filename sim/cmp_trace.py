#!/usr/bin/env python3
"""RTL と命令シミュレータのトレースを先頭から比べ、最初に食い違った命令を表示する

    python3 cmp_trace.py rtl.trace sim.trace [-n 文脈の行数]

1 行 = 完了した命令 1 個。"#" 以降（RTL のサイクル数など）は比較しない。
ファイルの代わりに名前付きパイプ (mkfifo) を渡せば、巨大なトレースも保存せずに比べられる。
"""
import argparse
import collections
import itertools
import sys


def key(line):
    return line.split("#", 1)[0].strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rtl")
    ap.add_argument("sim")
    ap.add_argument("-n", type=int, default=10, help="不一致の手前に表示する行数")
    args = ap.parse_args()

    hist = collections.deque(maxlen=args.n)
    n = 0
    with open(args.rtl) as fr, open(args.sim) as fs:
        for n, (lr, ls) in enumerate(itertools.zip_longest(fr, fs, fillvalue="<EOF>")):
            if key(lr) != key(ls):
                print(f"MISMATCH at instruction #{n}")
                for h in hist:
                    print("       ", h)
                print("  rtl: ", lr.rstrip())
                print("  sim: ", ls.rstrip())
                sys.exit(1)
            hist.append(lr.rstrip())
    print(f"trace: OK ({n + 1} lines)")


if __name__ == "__main__":
    main()
