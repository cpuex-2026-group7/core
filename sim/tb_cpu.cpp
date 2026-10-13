// Verilator 用テストベンチ（トップは core_top）
//
// RTL が命令を 1つ完了するたびに、命令シミュレータ（sim/sim_repository）でも同じ命令を
// 1つ実行して結果を比べる。食い違ったらその場で止まり、直前の命令列と食い違いの内容を表示する。
//
//   ./obj_dir/Vcore_top +imem=../test/fib.mem             実行して比較（+imem
//   は必須）
//   ./obj_dir/Vcore_top ... +trace=rtl.trace               RTL
//   のトレースをファイルにも書く
//   ./obj_dir/Vcore_top ... +bp=0x8                        pc=0x8
//   の命令を実行する直前で毎回レジスタ表示
//   ./obj_dir/Vcore_top ... +wave_from=100 +wave_len=50    cycle 100〜149 だけ
//   wave.fst に波形を出す
//   ./obj_dir/Vcore_top ... +max_cycle=1000000 打ち切りサイクル数（既定 1e8）
//   ./obj_dir/Vcore_top ... +context=20 食い違いの手前に表示する命令数（既定
//   10）
//
// 終了コード: 0 = halt まで一致, 1 = 食い違い, 2 = max_cycle で打ち切り

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <string>

#include "Vcore_top.h"
#include "Vcore_top__Dpi.h"
#include "commit.h"
#include "ref_model.h"
#include "verilated.h"
#include "verilated_fst_c.h"

static FILE *g_trace = nullptr;       // +trace= のときだけ開く
static uint64_t g_cycle = 0;          // リセット解除後のサイクル数
static uint64_t g_ncommit = 0;        // 完了した命令数
static RefModel g_ref;                // 命令シミュレータ
static bool g_failed = false;         // 食い違いが見つかった
static std::deque<Commit> g_history;  // 直近の命令（食い違ったときに表示する）
static size_t g_context = 10;

static void report_mismatch(const Commit &c, const std::string &why,
                            const std::string &sim_line) {
  std::fprintf(stderr, "\nMISMATCH at instruction #%llu (cycle %llu): %s\n",
               (unsigned long long)g_ncommit, (unsigned long long)c.cycle,
               why.c_str());
  for(const Commit &h: g_history) {
    std::fprintf(stderr, "        ");
    print_commit(stderr, h);
  }
  std::fprintf(stderr, "  rtl:  ");
  print_commit(stderr, c);
  std::fprintf(stderr, "  sim:  %s\n", sim_line.c_str());
  const unsigned long long from = c.cycle > 20 ? c.cycle - 20 : 0;
  std::fprintf(
    stderr,
    "\n波形を見るなら: make ARGS=\"+wave_from=%llu +wave_len=40\"\n\n", from);
}

// core_top.sv の always_ff から、命令が 1 つ完了するたびに呼ばれる
void dpi_commit(int pc, int instr, svBit reg_we, svBit rd_is_f, int rd,
                int wdata, svBit mem_we, int mem_addr, int mem_wdata) {
  const Commit c{ g_cycle,
                  (uint32_t)pc,
                  (uint32_t)instr,
                  (bool)reg_we,
                  (bool)rd_is_f,
                  (uint32_t)rd,
                  (uint32_t)wdata,
                  (bool)mem_we,
                  (uint32_t)mem_addr,
                  (uint32_t)mem_wdata };
  if(g_trace)
    print_commit(g_trace, c);
  if(!g_failed) {
    std::string why, sim_line;
    if(!g_ref.step(c, why, sim_line)) {
      report_mismatch(c, why, sim_line);
      g_failed = true;
    }
  }
  g_history.push_back(c);
  if(g_history.size() > g_context)
    g_history.pop_front();
  g_ncommit++;
}

// "+key=値" の値の部分を返す。無ければ def。
// commandArgsPlusMatch の戻り値は次の呼び出しで上書きされるので、必ず
// std::string にコピーする。
static std::string plusarg_str(VerilatedContext *ctx, const char *key,
                               const char *def) {
  const char *s =
    ctx->commandArgsPlusMatch(key);  // "+key=値" がそのまま返る。無ければ ""
  const char *eq = *s ? std::strchr(s, '=') : nullptr;
  return eq ? std::string(eq + 1) : std::string(def);
}

static uint64_t plusarg_u64(VerilatedContext *ctx, const char *key,
                            uint64_t def) {
  const std::string s = plusarg_str(ctx, key, "");
  return s.empty()
         ? def
         : std::strtoull(s.c_str(), nullptr, 0);  // 0x 付きの 16 進も可
}

// 7seg 用のデバッグポート (reg_dbg / reg_dbg_data)
// でレジスタファイルを直接読む。 クロックは動かさないので CPU
// の状態は変わらない。
static uint32_t read_reg(Vcore_top *top, int idx) {  // 0-31: x, 32-63: f
  top->reg_dbg = idx;
  top->eval();
  return top->reg_dbg_data;
}

// 命令シミュレータの Reg::dump() と同じ形式
static void dump_regs(Vcore_top *top, FILE *fp) {
  std::fprintf(fp, "=== Reg Dump ===\n");
  std::fprintf(fp, "pc = %u\n", top->pc_dbg);
  std::fprintf(fp, "=== x regs ===\n");
  for(int i = 0; i < 32; i++) {
    uint32_t v = read_reg(top, i);
    std::fprintf(fp, "x[%02d] = 0x%08x %12d | ", i, v, (int32_t)v);
    if(i % 4 == 3)
      std::fprintf(fp, "\n");
  }
  std::fprintf(fp, "=== f regs ===\n");
  for(int i = 0; i < 32; i++) {
    uint32_t v = read_reg(top, 32 + i);
    float f;
    std::memcpy(&f, &v, sizeof f);
    std::fprintf(fp, "f[%02d] = 0x%08x %12g | ", i, v, f);
    if(i % 4 == 3)
      std::fprintf(fp, "\n");
  }
}

int main(int argc, char **argv) {
  auto ctx = std::make_unique<VerilatedContext>();
  ctx->commandArgs(
    argc, argv);  // これで RTL 側の $value$plusargs からも +imem= などが見える
  ctx->traceEverOn(true);

  const std::string imem = plusarg_str(ctx.get(), "imem=", "");
  if(imem.empty()) {
    std::fprintf(stderr,
                 "usage: %s +imem=<prog.mem> [+trace=<file>] [+bp=<pc>] "
                 "[+wave_from=<cycle>] ...\n",
                 argv[0]);
    return 1;
  }
  const std::string trace_path = plusarg_str(ctx.get(), "trace=", "");
  const uint64_t max_cycle =
    plusarg_u64(ctx.get(), "max_cycle=", 100'000'000ULL);
  const uint64_t wave_from = plusarg_u64(ctx.get(), "wave_from=", UINT64_MAX);
  const uint64_t wave_len = plusarg_u64(ctx.get(), "wave_len=", 200);
  const uint64_t bp = plusarg_u64(ctx.get(), "bp=", UINT64_MAX);
  g_context = plusarg_u64(ctx.get(), "context=", 10);

  if(!g_ref.load(imem))
    return 1;
  if(!trace_path.empty() && !(g_trace = std::fopen(trace_path.c_str(), "w"))) {
    std::perror(trace_path.c_str());
    return 1;
  }

  // RTL を作る（ここで i_mem の initial が走り、同じ +imem= のファイルを読む）
  auto top = std::make_unique<Vcore_top>(ctx.get(), "TOP");

  VerilatedFstC *tfp = nullptr;
  if(wave_from != UINT64_MAX) {
    tfp = new VerilatedFstC;
    top->trace(tfp, 99);
    tfp->open("wave.fst");
  }

  // d_mem は negedge で読み書きするので、1 サイクル = negedge → posedge
  // の順に回す。 （posedge で pc が進む → 次の negedge で d_mem
  // がその命令のアドレスを読む → 次の posedge で書き戻し）
  auto half = [&](int clk) {
    top->clk = clk;
    top->eval();
    if(tfp && g_cycle >= wave_from && g_cycle < wave_from + wave_len)
      tfp->dump(ctx->time());
    ctx->timeInc(1);
  };
  auto tick = [&] {
    half(0);
    half(1);
  };

  top->clk = 1;
  top->en = 1;
  top->uart_rx = 1;
  top->reg_dbg = 0;
  top->rst = 1;
  top->eval();
  for(int i = 0; i < 4; i++)
    tick();
  top->rst = 0;

  while(!ctx->gotFinish() && !g_failed && !top->cpu_halted && g_cycle < max_cycle) {
    if(top->pc_dbg == bp) {
      if(g_trace)
        std::fflush(g_trace);
      std::fprintf(stderr, "[bp] pc=0x%08x  instruction#%llu  cycle=%llu\n",
                   top->pc_dbg, (unsigned long long)g_ncommit,
                   (unsigned long long)g_cycle);
      dump_regs(top.get(), stderr);
    }
    tick();
    g_cycle++;
  }

  int rc;
  if(g_failed) {
    rc = 1;
  } else if(top->cpu_halted) {
    std::string why;
    if(g_ref.check_halt(top->pc_dbg, why)) {
      std::fprintf(stderr,
                   "OK: halt まで %llu 命令すべて sim と一致（%llu cycles）\n",
                   (unsigned long long)g_ncommit, (unsigned long long)g_cycle);
      rc = 0;
    } else {
      std::fprintf(stderr, "\nMISMATCH at halt: %s\n", why.c_str());
      rc = 1;
    }
  } else {
    std::fprintf(stderr,
                 "TIMEOUT: %llu cycles で打ち切り（%llu 命令までは一致）\n",
                 (unsigned long long)g_cycle, (unsigned long long)g_ncommit);
    rc = 2;
  }
  if(g_trace) {
    std::fprintf(g_trace, "halt pc=%08x\n", top->pc_dbg);
    std::fclose(g_trace);
  }
  dump_regs(top.get(), stdout);

  top->final();
  if(tfp) {
    tfp->close();
    delete tfp;
  }
  return rc;
}
