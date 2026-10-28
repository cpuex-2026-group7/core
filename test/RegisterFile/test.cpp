// lvt_rf のランダムテスト（C++ テストベンチ）
// 毎サイクル、ランダムなポートが互いに異なるアドレスにランダムな値を書き、ランダムなアドレスを読む
// ビルド例: verilator --cc --exe --build -GR=5 -GW=3 -DRP=5 -DWP=3 types.sv lvt_rf.sv tb_lvt_rf.cpp --top-module lvt_rf
#include <cstdint>
#include <cstdio>
#include <random>

#include "Vlvt_rf.h"
#include "verilated.h"

#ifndef RP
#define RP 5
#endif
#ifndef WP
#define WP 3
#endif

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  constexpr int SIZE = 64;
  constexpr long CYCLES = 200000;

  Vlvt_rf dut;
  std::mt19937 rng(12345);
  uint32_t model[SIZE] = {};
  long errors = 0;

  dut.clk = 0;
  dut.eval();

  for (long c = 0; c < CYCLES; c++) {
    // 入力をランダムに決める（書き込みアドレスは互いに異なるようにする）
    for (int i = 0; i < WP; i++) {
      dut.w_en[i] = (rng() % 4) != 0;
      bool dup;
      do {
        dut.w_addr[i] = rng() % SIZE;
        dup = false;
        for (int j = 0; j < i; j++)
          if (dut.w_en[j] && dut.w_addr[j] == dut.w_addr[i]) dup = true;
      } while (dut.w_en[i] && dup);
      dut.w_data[i] = rng();
    }
    for (int i = 0; i < RP; i++) dut.r_addr[i] = rng() % SIZE;
    dut.eval();

    // 書き込み前の値が読めていることを確認（非同期読み出し）
    for (int i = 0; i < RP; i++) {
      uint32_t exp = model[dut.r_addr[i]];
      if (dut.r_data[i] != exp) {
        if (++errors < 10)
          std::printf("NG: cycle %ld port %d addr %d: %08x != %08x\n", c, i, (int)dut.r_addr[i],
                      (unsigned)dut.r_data[i], (unsigned)exp);
      }
    }

    // クロックを1周期進める
    dut.clk = 1;
    dut.eval();
    dut.clk = 0;
    dut.eval();

    // 参照モデルを更新
    for (int i = 0; i < WP; i++)
      if (dut.w_en[i]) model[dut.w_addr[i]] = dut.w_data[i];
  }

  if (errors == 0) std::printf("PASS: %dW%dR, %ld サイクル\n", WP, RP, CYCLES);
  else std::printf("FAIL: %dW%dR, %ld 件の不一致\n", WP, RP, errors);
  dut.final();
  return errors != 0;
}
