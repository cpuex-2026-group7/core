#pragma once

#include <cstdint>
#include <string>

#include "commit.h"
// 以下は命令シミュレータ（sim/sim_repository/src）のヘッダ
#include "mem.h"
#include "reg.h"

// 命令シミュレータが 1 命令実行してできた書き込み 1 つ
struct SimWrite {
  Commit w;        // 書き込みの中身（cycle = 何命令目か、pc = 書き込んだ命令の pc）
  uint32_t instr;  // 書き込んだ命令
};

// 命令シミュレータの Reg / Mem / Inst をそのまま使った参照モデル。
// RTL は書き込みしか報告しないので、こちらも sim を命令順に進めて書き込みだけを取り出し、
// RTL の書き込みと 1 つずつ突き合わせる。
// 書き込みは sim が書いたとおりに返す（x0 / f0 への書き込みも含む）。比べるかどうかは呼び出し側で決める。
class RefModel {
 public:
  // プログラムを命令シミュレータのメモリに読み込む。
  //   .bin: 命令シミュレータと同じ、ヘッダ無しのビッグエンディアン生バイナリ（sim_repository/test/*.bin）
  //   それ以外: $readmemh 形式の .mem
  bool load(const std::string &path);

  // sim を進めて、次の書き込みを 1 つ取り出す。
  // 書き込みを見つけたら true。halt まで書き込みが無かったら false（halted() が true になる）。
  // pc がメモリの範囲外に出た、または max_steps 命令進めても書き込みが無いときも false を返し、error に理由を入れる。
  bool next_write(SimWrite &out, std::string &error, uint64_t max_steps = 100'000'000ULL);

  bool halted() const { return halted_; }
  uint32_t halt_pc() const { return halt_pc_; }    // halted() のときだけ意味がある
  uint64_t executed() const { return executed_; }  // sim が実行した命令の数（halt は数えない）
  uint64_t halt_cycle() const { return executed_; } // halt が何命令目か（sim の --trace の c= と同じ）

 private:
  Reg reg;
  Mem mem;
  bool halted_ = false;
  uint32_t halt_pc_ = 0;
  uint64_t executed_ = 0;
};
