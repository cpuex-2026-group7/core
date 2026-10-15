#include "ref_model.h"

#include <cstdio>
#include <fstream>
#include <iterator>
#include <regex>
#include <sstream>

// 以下は命令シミュレータ（sim/sim_repository/src）のヘッダ
#include "const.h"
#include "inst.h"

static std::string hex8(uint32_t v) {
  char buf[16];
  std::snprintf(buf, sizeof buf, "%08x", v);
  return buf;
}

static bool ends_with(const std::string &s, const std::string &suffix) {
  return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

bool RefModel::load(const std::string &path) {
  if(ends_with(path, ".bin")) {
    // 命令シミュレータの Core と同じ読み方（ヘッダ無し、ビッグエンディアン、アドレス 0 から）
    std::ifstream in(path, std::ios::binary);
    if(!in) {
      std::fprintf(stderr, "%s を開けない\n", path.c_str());
      return false;
    }
    const std::string bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if(bytes.size() > (size_t)Mem::mem_size * 4) {
      std::fprintf(stderr, "%s: プログラムが命令シミュレータのメモリに収まらない\n", path.c_str());
      return false;
    }
    for(size_t i = 0; i < bytes.size(); i++)
      mem.mem[i / 4] |= (uint32_t)(uint8_t)bytes[i] << (8 * (3 - i % 4));
    return true;
  }

  std::ifstream in(path);
  if(!in) {
    std::fprintf(stderr, "%s を開けない\n", path.c_str());
    return false;
  }
  uint32_t addr = 0;
  std::string line;
  while(std::getline(in, line)) {
    line = std::regex_replace(line, std::regex("//.*"), "");
    std::istringstream ss(line);
    std::string tok;
    while(ss >> tok) {
      if(tok[0] == '@') {  // @アドレス（16 進、ワード単位）
        addr = std::stoul(tok.substr(1), nullptr, 16);
        continue;
      }
      if(addr >= (uint32_t)Mem::mem_size) {
        std::fprintf(stderr, "%s: プログラムが命令シミュレータのメモリに収まらない\n",
                     path.c_str());
        return false;
      }
      mem.mem[addr++] = std::stoul(tok, nullptr, 16);
    }
  }
  return true;
}

bool RefModel::next_write(SimWrite &out, std::string &error, uint64_t max_steps) {
  error.clear();
  for(uint64_t step = 0; !halted_; step++) {
    if(step >= max_steps) {
      error = "sim を " + std::to_string(max_steps) + " 命令進めても書き込みも halt も無い（pc=" +
              hex8(reg.pc) + "）";
      return false;
    }
    const uint32_t pc = reg.pc;
    if(pc >= (uint32_t)Mem::mem_size) {
      error = "sim の pc が命令シミュレータのメモリの範囲外（pc=" + hex8(pc) + "）";
      return false;
    }
    const uint32_t raw = mem.mem[pc];

    // 1 命令実行する。書き込みは reg.trace / mem.trace に残る
    reg.trace.valid = false;
    mem.trace.valid = false;
    Inst inst(raw);
    if(!inst.exec(reg, mem)) {  // halt
      halted_ = true;
      halt_pc_ = pc;
      return false;
    }
    const uint64_t cycle = executed_++;  // この命令が何命令目か（0 始まり）

    if(reg.trace.valid) {
      out.w = { false, (uint32_t)((reg.trace.is_f ? 32 : 0) + reg.trace.num), reg.trace.value, cycle, pc };
      out.instr = raw;
      return true;
    }
    if(mem.trace.valid) {
      out.w = { true, mem.trace.addr, mem.trace.value, cycle, pc };
      out.instr = raw;
      return true;
    }
    // 書き込みの無い命令（分岐など）は飛ばして次へ
  }
  return false;
}
