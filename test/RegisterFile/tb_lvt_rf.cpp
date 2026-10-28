// lvt_rf（LVT 方式のマルチポートレジスタファイル）のテストベンチ
//
// ポートの数とエントリ数はビルド時に決める（Makefile が -G と -D の両方で渡す）
//   SIZE : エントリ数, RP : 読み出しポート数, WP : 書き込みポート数
//
// 実行時オプション
//   +cycles=N   ランダムテストのサイクル数（既定 200000）
//   +seed=N     乱数の種（既定 1）
//   +trace      wave.fst に波形を出す（Makefile で TRACE=1 を付けてビルドしたときだけ有効）
//
// 確認している性質
//   1. 起動直後は全エントリが 0
//   2. 書いた次のサイクルから、全読み出しポートで書いた値が読める
//   3. 書いたのと同じサイクルの読み出しは、書く前の値（非同期読み出し・同期書き込み）
//   4. 同じアドレスを別々のポートが順番に書いたとき、最後に書いた値が読める（LVT の切り替わり）
//   5. 全ポートが同時に別々のアドレスへ書いても、互いに干渉しない
//   6. 上をランダムに混ぜたもの（同時書き込みのアドレスは互いに異なる）
//
// 同じアドレスへの同時書き込みは仕様で禁止なので、このテストでは発生させない

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include "Vlvt_rf.h"
#include "verilated.h"
#ifdef LVT_TRACE
#include "verilated_fst_c.h"
#endif

#ifndef SIZE
#error "SIZE を -D で指定すること"
#endif
#ifndef RP
#error "RP を -D で指定すること"
#endif
#ifndef WP
#error "WP を -D で指定すること"
#endif

// -G と -D の食い違いをビルド時に検出する
static_assert(sizeof(Vlvt_rf::r_addr) / sizeof(Vlvt_rf::r_addr[0]) == RP, "RP と -GR が一致しない");
static_assert(sizeof(Vlvt_rf::w_addr) / sizeof(Vlvt_rf::w_addr[0]) == WP, "WP と -GW が一致しない");

namespace {

struct Bench {
  std::unique_ptr<VerilatedContext> ctx;
  std::unique_ptr<Vlvt_rf> dut;
#ifdef LVT_TRACE
  std::unique_ptr<VerilatedFstC> tfp;
#endif
  uint32_t model[SIZE] = {};  // 参照モデル
  uint64_t cycle = 0;
  uint64_t checks = 0;
  uint64_t errors = 0;
  std::string phase;

  explicit Bench(int argc, char** argv) : ctx(new VerilatedContext) {
    ctx->commandArgs(argc, argv);
    dut.reset(new Vlvt_rf{ctx.get()});
#ifdef LVT_TRACE
    if (ctx->commandArgsPlusMatch("trace")[0]) {
      ctx->traceEverOn(true);
      tfp.reset(new VerilatedFstC);
      dut->trace(tfp.get(), 99);
      tfp->open("wave.fst");
    }
#endif
    idle();
    dut->clk = 0;
    dut->eval();
    dump();
  }

  ~Bench() {
    dut->final();
#ifdef LVT_TRACE
    if (tfp) tfp->close();
#endif
  }

  void dump() {
#ifdef LVT_TRACE
    if (tfp) tfp->dump(ctx->time());
#endif
  }

  // 書き込みを全部止める
  void idle() {
    for (int i = 0; i < WP; i++) {
      dut->w_en[i] = 0;
      dut->w_addr[i] = 0;
      dut->w_data[i] = 0;
    }
  }

  // 現在の入力で読み出しを確認する（クロックの立ち上がり前 = 書き込み前の値が見えるはず）
  void check_reads() {
    dut->eval();
    for (int i = 0; i < RP; i++) {
      const uint32_t addr = dut->r_addr[i];
      const uint32_t got = dut->r_data[i];
      const uint32_t exp = model[addr];
      checks++;
      if (got != exp) {
        errors++;
        if (errors <= 20) {
          std::printf("NG [%s] cycle %" PRIu64 ": 読み出しポート %d, アドレス %u: %08x（期待値 %08x）\n",
                      phase.c_str(), cycle, i, addr, got, exp);
        }
      }
    }
  }

  // クロックを 1 周期進め、参照モデルに書き込みを反映する
  void step() {
    check_reads();
    ctx->timeInc(5);
    dut->clk = 1;
    dut->eval();
    dump();
    ctx->timeInc(5);
    dut->clk = 0;
    dut->eval();
    dump();
    for (int i = 0; i < WP; i++) {
      if (dut->w_en[i]) model[dut->w_addr[i]] = dut->w_data[i];
    }
    cycle++;
  }

  // 全読み出しポートで、アドレス a から順に読む（1 サイクル分の読み出しアドレスを設定）
  void set_reads_from(uint32_t a) {
    for (int i = 0; i < RP; i++) dut->r_addr[i] = (a + i) % SIZE;
  }

  // 全アドレスを全読み出しポートで読んで確認する（書き込みなし）
  void sweep_all() {
    idle();
    for (uint32_t a = 0; a < SIZE; a++) {
      for (int i = 0; i < RP; i++) dut->r_addr[i] = a;
      step();
    }
  }
};

uint32_t make_value(int port, uint32_t addr, uint32_t salt) {
  return (static_cast<uint32_t>(port + 1) << 28) ^ (addr << 16) ^ salt;
}

// 1. 起動直後は全エントリが 0
void test_initial_zero(Bench& b) {
  b.phase = "初期値";
  b.sweep_all();
}

// 2. 各ポートで書いて、次のサイクルから全読み出しポートで読める
void test_each_port(Bench& b) {
  b.phase = "ポートごとの書き込み";
  for (int p = 0; p < WP; p++) {
    for (uint32_t a = 0; a < SIZE; a++) {
      b.idle();
      b.dut->w_en[p] = 1;
      b.dut->w_addr[p] = a;
      b.dut->w_data[p] = make_value(p, a, 0x1234);
      b.set_reads_from(a);  // 3. 同じサイクルの読み出しは古い値
      b.step();
    }
    b.sweep_all();
  }
}

// 4. 同じアドレスを別々のポートが順番に書く（LVT の切り替わり）
void test_ownership_transfer(Bench& b) {
  b.phase = "書き込みポートの切り替わり";
  for (uint32_t a = 0; a < SIZE; a++) {
    for (int round = 0; round < 2; round++) {
      for (int p = 0; p < WP; p++) {
        b.idle();
        b.dut->w_en[p] = 1;
        b.dut->w_addr[p] = a;
        b.dut->w_data[p] = make_value(p, a, 0x5000 + round);
        for (int i = 0; i < RP; i++) b.dut->r_addr[i] = a;
        b.step();
      }
      // 逆順でも切り替える
      for (int p = WP - 1; p >= 0; p--) {
        b.idle();
        b.dut->w_en[p] = 1;
        b.dut->w_addr[p] = a;
        b.dut->w_data[p] = make_value(p, a, 0x6000 + round);
        for (int i = 0; i < RP; i++) b.dut->r_addr[i] = a;
        b.step();
      }
    }
  }
  b.idle();
  b.sweep_all();
}

// 5. 全ポートが同時に別々のアドレスへ書く
void test_all_ports_at_once(Bench& b) {
  b.phase = "全ポート同時書き込み";
  for (uint32_t base = 0; base < SIZE; base++) {
    for (int p = 0; p < WP; p++) {
      const uint32_t a = (base + static_cast<uint32_t>(p) * (SIZE / WP)) % SIZE;
      b.dut->w_en[p] = 1;
      b.dut->w_addr[p] = a;
      b.dut->w_data[p] = make_value(p, a, 0x7000 + base);
    }
    // 直前に書いたアドレスと、今書いているアドレスを読む
    for (int i = 0; i < RP; i++) b.dut->r_addr[i] = b.dut->w_addr[i % WP];
    b.step();
  }
  b.idle();
  b.sweep_all();
}

// 6. ランダム（読み出しアドレスは、半分は直近に書いたアドレスから選ぶ）
void test_random(Bench& b, uint64_t cycles, uint32_t seed) {
  b.phase = "ランダム";
  std::mt19937 rng(seed);
  std::vector<uint32_t> recent(8, 0);
  size_t recent_pos = 0;

  for (uint64_t c = 0; c < cycles; c++) {
    for (int p = 0; p < WP; p++) {
      const bool en = (rng() % 4) != 0;  // 75% の確率で書く
      uint32_t a;
      bool dup;
      do {
        a = rng() % SIZE;
        dup = false;
        for (int q = 0; q < p; q++) {
          if (b.dut->w_en[q] && b.dut->w_addr[q] == a) dup = true;
        }
      } while (en && dup);
      b.dut->w_en[p] = en;
      b.dut->w_addr[p] = a;
      b.dut->w_data[p] = static_cast<uint32_t>(rng());
    }
    for (int i = 0; i < RP; i++) {
      b.dut->r_addr[i] = (rng() & 1) ? recent[rng() % recent.size()] : (rng() % SIZE);
    }
    for (int p = 0; p < WP; p++) {
      if (b.dut->w_en[p]) {
        recent[recent_pos] = b.dut->w_addr[p];
        recent_pos = (recent_pos + 1) % recent.size();
      }
    }
    b.step();
  }
  b.idle();
  b.sweep_all();
}

uint64_t plusarg_u64(VerilatedContext* ctx, const char* name, uint64_t def) {
  const std::string key = std::string(name) + "=";
  const char* m = ctx->commandArgsPlusMatch(key.c_str());
  if (!m || !m[0]) return def;
  return std::strtoull(m + 1 + key.size(), nullptr, 0);
}

}  // namespace

int main(int argc, char** argv) {
  Bench b(argc, argv);
  const uint64_t cycles = plusarg_u64(b.ctx.get(), "cycles", 200000);
  const uint32_t seed = static_cast<uint32_t>(plusarg_u64(b.ctx.get(), "seed", 1));

  std::printf("lvt_rf テスト: %dW%dR, %d エントリ, ランダム %" PRIu64 " サイクル, seed=%u\n", WP, RP, SIZE,
              cycles, seed);

  test_initial_zero(b);
  test_each_port(b);
  test_ownership_transfer(b);
  test_all_ports_at_once(b);
  test_random(b, cycles, seed);

  if (b.errors == 0) {
    std::printf("PASS: %" PRIu64 " サイクル, %" PRIu64 " 回の読み出しを確認\n", b.cycle, b.checks);
    return 0;
  }
  std::printf("FAIL: %" PRIu64 " 件の不一致（%" PRIu64 " 回中）\n", b.errors, b.checks);
  return 1;
}
