#include "ref_model.h"

#include <cstdio>
#include <fstream>
#include <regex>
#include <sstream>

// 以下は命令シミュレータ（src/sim_repository/src）のヘッダ
#include "const.h"
#include "inst.h"

static std::string hex8(uint32_t v) {
  char buf[16];
  std::snprintf(buf, sizeof buf, "%08x", v);
  return buf;
}

static std::string reg_name(int i) {
  char buf[8];
  std::snprintf(buf, sizeof buf, "%c%02d", i < 32 ? 'x' : 'f', i % 32);
  return buf;
}

bool RefModel::load(const std::string &path) {
  std::ifstream in(path);
  if (!in) {
    std::fprintf(stderr, "%s を開けない\n", path.c_str());
    return false;
  }
  uint32_t addr = 0;
  std::string line;
  while (std::getline(in, line)) {
    line = std::regex_replace(line, std::regex("//.*"), "");
    std::istringstream ss(line);
    std::string tok;
    while (ss >> tok) {
      if (tok[0] == '@') { // @アドレス（16 進、ワード単位）
        addr = std::stoul(tok.substr(1), nullptr, 16);
        continue;
      }
      if (addr >= (uint32_t)Mem::mem_size) {
        std::fprintf(stderr,
                     "%s: プログラムが命令シミュレータのメモリに収まらない\n",
                     path.c_str());
        return false;
      }
      mem.mem[addr++] = std::stoul(tok, nullptr, 16);
    }
  }
  return true;
}

bool RefModel::step(const Commit &c, std::string &why, std::string &sim_line) {
  // 1. sim も同じ pc・同じ命令を実行しようとしているか
  if (reg.pc != c.pc) {
    why = "pc が違う（直前の命令の飛び先がずれている）";
    sim_line = "pc=" + hex8(reg.pc);
    return false;
  }
  if (c.pc >= (uint32_t)Mem::mem_size) {
    why = "pc が命令シミュレータのメモリの範囲外";
    sim_line = "";
    return false;
  }
  const uint32_t raw = mem.mem[c.pc];
  if (raw != c.instr) {
    why = "同じ pc の命令が違う（命令メモリの中身が違うか、sim "
          "側でプログラム領域に store した）";
    sim_line = "pc=" + hex8(c.pc) + " ins=" + hex8(raw);
    return false;
  }

  // 2. sim で 1 命令実行
  Inst inst(raw);
  const bool sim_store = (inst.eff_type == EFF_MEM);
  const uint32_t sim_addr =
      reg.read_x(inst.rs1) +
      inst.imm; // store のときのアドレス（実行前の rs1 で計算）
  if (!inst.exec(reg, mem)) {
    why = "sim はこの命令を halt として扱った";
    sim_line = "pc=" + hex8(c.pc) + " ins=" + hex8(raw) + " (halt)";
    return false;
  }

  // sim 側の実行結果を、RTL
  // のトレースと同じ形式の文字列にする（不一致のときの表示用）
  auto make_sim_line = [&] {
    std::string s = "pc=" + hex8(c.pc) + " ins=" + hex8(raw);
    for (int i = 0; i < 64; i++)
      if (sim_reg(i) != shadow[i])
        s += " " + reg_name(i) + "=" + hex8(sim_reg(i));
    if (sim_store)
      s += " M[" + hex8(sim_addr) + "]=" + hex8(mem.mem[sim_addr]);
    return s;
  };

  // 3. レジスタを全部比べる（x0/f0 は RTL も sim も書き込まないので 0 のまま）
  const int rd_idx = (c.rd_is_f ? 32 : 0) + (int)c.rd;
  for (int i = 0; i < 64; i++) {
    const uint32_t expect =
        (c.reg_we && i == rd_idx && c.rd != 0) ? c.wdata : shadow[i];
    if (sim_reg(i) != expect) {
      why = reg_name(i) + " が違う（rtl=" + hex8(expect) +
            ", sim=" + hex8(sim_reg(i)) + "）";
      sim_line = make_sim_line();
      return false;
    }
  }

  // 4. メモリへの書き込みを比べる
  if (sim_store != c.mem_we) {
    why = c.mem_we ? "rtl だけがメモリに書いた" : "sim だけがメモリに書いた";
    sim_line = make_sim_line();
    return false;
  }
  if (sim_store &&
      (sim_addr != c.mem_addr || mem.mem[sim_addr] != c.mem_wdata)) {
    why = "メモリへの書き込み（アドレスか値）が違う";
    sim_line = make_sim_line();
    return false;
  }

  // 5. 一致したので RTL の書き込みを反映
  if (c.reg_we && c.rd != 0)
    shadow[rd_idx] = c.wdata;
  return true;
}

bool RefModel::check_halt(uint32_t pc, std::string &why) {
  if (reg.pc != pc) {
    why = "rtl は pc=" + hex8(pc) + " で halt したが、sim の pc は " +
          hex8(reg.pc);
    return false;
  }
  Inst inst(mem.mem[pc]);
  if (inst.exec(reg, mem)) {
    why = "rtl は pc=" + hex8(pc) +
          " で halt したが、sim はこの命令を halt として扱わない";
    return false;
  }
  return true;
}
