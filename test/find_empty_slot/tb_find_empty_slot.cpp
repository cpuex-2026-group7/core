// find_empty_slot（bitmap から空きスロットを探す組み合わせ回路）のテストベンチ
//
// 構成はビルド時に決める（Makefile が -G と -D の両方で渡す）
//   SIZE : bitmap の幅（1〜64）, FIND_NUM : 探す個数
//
// 実行時オプション
//   +n=N      SIZE が 16 より大きいときのランダムパターン数（既定 200000）
//   +seed=N   乱数の種（既定 1）
//
// 期待値（モジュールの書き方とは独立に、空きを下から並べて決める）
//   found[d] = 空きが d+1 個以上ある
//   FIND_NUM == 2 : slot[0] = 一番下の空き, slot[1] = 一番上の空き
//   それ以外      : slot[d] = 下から d 番目の空き
//   found[d] = 0 のときの slot[d] は見ない
//
// パターン
//   SIZE <= 16 : 全 2^SIZE 通り
//   SIZE >  16 : 全部使用中, 全部空き, 空きが 1 個・2 個（全位置）, 使用中が 1 個（全位置）, 密度を変えたランダム

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <random>
#include <string>
#include <vector>

#include "Vfind_empty_slot.h"
#include "verilated.h"

#ifndef SIZE
#error "SIZE を -D で指定すること"
#endif
#ifndef FIND_NUM
#error "FIND_NUM を -D で指定すること"
#endif

static_assert(SIZE >= 1 && SIZE <= 64, "このテストベンチは SIZE が 1〜64 のときだけ対応");
static_assert(sizeof(Vfind_empty_slot::found) / sizeof(Vfind_empty_slot::found[0]) == FIND_NUM,
              "FIND_NUM と -GFIND_NUM が一致しない");

namespace {

constexpr uint64_t MASK = (SIZE == 64) ? ~0ull : ((1ull << SIZE) - 1ull);

struct Bench {
  std::unique_ptr<VerilatedContext> ctx;
  std::unique_ptr<Vfind_empty_slot> top;
  uint64_t checked = 0;
  uint64_t errors = 0;

  Bench() : ctx(new VerilatedContext), top(new Vfind_empty_slot(ctx.get())) {}

  void check(uint64_t bitmap) {
    bitmap &= MASK;
    top->bitmap = bitmap;
    top->eval();

    std::vector<int> empties;
    for (int i = 0; i < SIZE; i++) {
      if (!((bitmap >> i) & 1ull)) empties.push_back(i);
    }

    for (int d = 0; d < FIND_NUM; d++) {
      const bool exp_found = static_cast<int>(empties.size()) > d;
      const bool got_found = top->found[d];
      if (got_found != exp_found) {
        report(bitmap, d, "found", exp_found, got_found);
        continue;
      }
      if (!exp_found) continue;

      int exp_slot;
      if (FIND_NUM == 2) {
        exp_slot = (d == 0) ? empties.front() : empties.back();
      } else {
        exp_slot = empties[d];
      }
      const int got_slot = top->slot[d];
      if (got_slot != exp_slot) report(bitmap, d, "slot", exp_slot, got_slot);
    }
    checked++;
  }

  void report(uint64_t bitmap, int d, const char* what, int exp, int got) {
    errors++;
    if (errors <= 20) {
      std::printf("NG: bitmap=0x%0*" PRIx64 " %s[%d] 期待値=%d 実際=%d\n", (SIZE + 3) / 4, bitmap, what, d, exp,
                  got);
    }
  }
};

}  // namespace

int main(int argc, char** argv) {
  Bench b;
  b.ctx->commandArgs(argc, argv);

  uint64_t n = 200000;
  uint64_t seed = 1;
  if (const char* s = b.ctx->commandArgsPlusMatch("n=")) {
    if (*s) n = std::strtoull(s + 3, nullptr, 0);
  }
  if (const char* s = b.ctx->commandArgsPlusMatch("seed=")) {
    if (*s) seed = std::strtoull(s + 6, nullptr, 0);
  }

  std::printf("find_empty_slot SIZE=%d FIND_NUM=%d\n", SIZE, FIND_NUM);

  if (SIZE <= 16) {
    for (uint64_t bm = 0; bm <= MASK; bm++) b.check(bm);
  } else {
    b.check(MASK);
    b.check(0);
    for (int i = 0; i < SIZE; i++) {
      b.check(MASK & ~(1ull << i));
      b.check(1ull << i);
      for (int j = i + 1; j < SIZE; j++) b.check(MASK & ~(1ull << i) & ~(1ull << j));
    }
    // 空きが少ない（IQ がほぼ満杯の）場合を多めに出す
    std::mt19937_64 rng(seed);
    for (uint64_t k = 0; k < n; k++) {
      const int density = static_cast<int>(k % 8);  // 0..7 → 空きの割合 1/2 〜 1/256
      uint64_t empty = rng();
      for (int t = 0; t < density; t++) empty &= rng();
      b.check(~empty);
    }
  }

  if (b.errors) {
    std::printf("FAIL: %" PRIu64 " / %" PRIu64 " パターンで不一致\n", b.errors, b.checked);
    return 1;
  }
  std::printf("PASS: %" PRIu64 " パターン\n", b.checked);
  return 0;
}
