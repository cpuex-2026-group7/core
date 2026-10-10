#!/usr/bin/env python3
"""$readmemh 形式の .mem を、命令シミュレータ用のビッグエンディアン生バイナリに変換する

    python3 mem2bin.py in.mem out.bin
"""
import re
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    words = []
    with open(sys.argv[1]) as f:
        for line in f:
            line = re.sub(r"//.*", "", line).strip()
            if not line:
                continue
            if line.startswith("@"):
                sys.exit("@アドレス指定には未対応")
            words += [int(w, 16) for w in line.split()]
    with open(sys.argv[2], "wb") as f:
        for w in words:
            f.write(w.to_bytes(4, "big"))


if __name__ == "__main__":
    main()
