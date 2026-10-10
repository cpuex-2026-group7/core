#pragma once

#include <cstdint>
#include <string>

#include "commit.h"
// 以下は命令シミュレータ（sim/sim_repository/src）のヘッダ
#include "mem.h"
#include "reg.h"

// 命令シミュレータの Reg / Mem / Inst をそのまま使った参照モデル。
// RTL が命令を 1 つ完了するたびに、こちらも 1 命令実行して結果を比べる。
class RefModel {
 public:
  // $readmemh 形式の .mem を命令シミュレータのメモリに読み込む（RTL
  // と同じファイルを渡す）
  bool load(const std::string &path);

  // RTL が完了した命令 c と同じ命令を実行し、結果を比べる。
  // 一致すれば true。不一致なら false を返し、why に理由、sim_line に sim
  // 側の実行結果を入れる。
  bool step(const Commit &c, std::string &why, std::string &sim_line);

  // RTL が pc の halt で止まったとき、sim も同じ場所で止まるかを確かめる
  bool check_halt(uint32_t pc, std::string &why);

 private:
  Reg reg;
  Mem mem;
  // RTL のコミットから復元したレジスタの値（0-31: x, 32-63: f）。
  // 毎命令 sim のレジスタと全部比べるので、書き込み先の取り違えも見つかる。
  uint32_t shadow[64] = {};

  uint32_t sim_reg(int i) const { return i < 32 ? reg.x[i] : reg.f[i - 32]; }
};
