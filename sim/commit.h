#pragma once

#include <cstdint>
#include <cstdio>

// 書き込み 1 つ。RTL（core_top.sv の dpi_reg_commit / dpi_mem_commit）と命令シミュレータの両方で使う
//   RTL : レジスタへの書き込みは WB、メモリへの書き込みは MEM で報告される。
//         core_top.sv は同じサイクルでは WB（古い命令）→ MEM（新しい命令）の順に呼ぶので、報告は命令の順に届く。
//   sim : 1 命令実行するごとに、書き込みがあればそれを 1 つ取り出す。
struct Commit {
  bool is_mem;     // false: レジスタへの書き込み, true: メモリへの書き込み
  uint32_t idx;    // レジスタ: rf_idx（0-31: x, 32-63: f） / メモリ: アドレス（ワード）
  uint32_t value;  // 書き込んだ値
  uint64_t cycle;  // RTL: core_top.sv の cycle / sim: 何命令目か（0 始まり。sim の --trace の c= と同じ）
  uint32_t pc;     // RTL: そのサイクルにフェッチしていた pc（dpi_pc_report。書き込んだ命令の pc ではない）
                   // sim: 書き込んだ命令の pc
};

// トレース（core.trace / sim.trace）の形式。どちらも同じ形式で、書き込みを 1 行ずつ書く
//   Commit: 書き込みだけ
//             x03=00000001
//             M[000003fe]=00000003
//   Cycle : "#" の後ろにサイクルと pc を付ける
//             x03=00000001  # c=2854 pc=00000004
//   halt したら最後に "halt"（Cycle なら "halt  # c=... pc=..."）の 1 行が付く。
//   "#" 以降は cmp_trace.py で比較しない。
enum class TraceMode { Commit, Cycle };

// 書き込み部分だけを書く（改行なし）
inline void print_write(FILE *fp, const Commit &c) {
  if(c.is_mem)
    std::fprintf(fp, "M[%08x]=%08x", c.idx, c.value);
  else
    std::fprintf(fp, "%c%02u=%08x", c.idx < 32 ? 'x' : 'f', c.idx % 32, c.value);
}

// 1 行書く
inline void print_commit(FILE *fp, const Commit &c, TraceMode mode) {
  print_write(fp, c);
  if(mode == TraceMode::Cycle)
    std::fprintf(fp, "  # c=%llu pc=%08x", (unsigned long long)c.cycle, c.pc);
  std::fprintf(fp, "\n");
}

// halt の行を書く
inline void print_halt(FILE *fp, uint64_t cycle, uint32_t pc, TraceMode mode) {
  if(mode == TraceMode::Cycle)
    std::fprintf(fp, "halt  # c=%llu pc=%08x\n", (unsigned long long)cycle, pc);
  else
    std::fprintf(fp, "halt\n");
}

// x0 / f0 への書き込みか（何も変えないので、比較では RTL・sim のどちらからも除く。トレースには残す）
inline bool is_zero_reg_write(const Commit &c) { return !c.is_mem && c.idx % 32 == 0; }
