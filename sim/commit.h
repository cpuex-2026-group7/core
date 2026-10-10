#pragma once

#include <cstdint>
#include <cstdio>

// RTL で命令が 1 つ完了したときの情報（core_top.sv の dpi_commit
// の引数そのまま）
struct Commit {
  uint64_t cycle;      // リセット解除後のサイクル数
  uint32_t pc;         // 完了した命令の pc
  uint32_t instr;      // 完了した命令
  bool reg_we;         // レジスタに書いたか（x0/f0 宛ても 1）
  bool rd_is_f;        // 書き込み先が f レジスタか
  uint32_t rd;         // 書き込み先の番号
  uint32_t wdata;      // 書き込んだ値
  bool mem_we;         // メモリに書いたか
  uint32_t mem_addr;   // 書き込んだアドレス（ワード）
  uint32_t mem_wdata;  // 書き込んだ値
};

// トレース 1 行の形式:
//   pc=00000002 ins=28200002 x02=00000003  # c=2
//   pc=00000008 ins=78008802 M[000001fe]=00000003  # c=7
inline void print_commit(FILE *fp, const Commit &c) {
  std::fprintf(fp, "pc=%08x ins=%08x", c.pc, c.instr);
  if(c.reg_we)
    std::fprintf(fp, " %c%02u=%08x", c.rd_is_f ? 'f' : 'x', c.rd, c.wdata);
  if(c.mem_we)
    std::fprintf(fp, " M[%08x]=%08x", c.mem_addr, c.mem_wdata);
  std::fprintf(fp, "  # c=%llu\n", (unsigned long long)c.cycle);
}
