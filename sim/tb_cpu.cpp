// Verilator 用テストベンチ（トップは core_top）
//
// RTL を動かし、core_top.sv が DPI 関数で報告する書き込み（レジスタ・メモリ）と halt を core.trace に書く。
// 命令シミュレータとの比較はここではしない（make が sim の実行ファイルも動かし、その出力を sim.trace に書く）。
//
//   ./obj_dir/Vcore_top +imem=sim_repository/test/fib.bin  実行（+imem は必須）
//                                                         .bin（命令シミュレータと同じビッグエンディアン生バイナリ）か
//                                                         .mem（$readmemh 形式）を渡す
//   ./obj_dir/Vcore_top ... +core_trace=core.trace         出力先（既定 core.trace）
//   ./obj_dir/Vcore_top ... +trace_mode=commit             書き込みと halt だけを 1 行ずつ（既定）
//                                                           M[000001ea]=00000001
//                                                           x03=00000002
//                                                           halt
//   ./obj_dir/Vcore_top ... +trace_mode=cycle              毎サイクル 1 行以上。サイクルと pc を付ける
//                                                           # c=2557 pc=0000000e              （書き込みの無いサイクル）
//                                                           M[000001ea]=00000001  # c=2558 pc=0000000f
//                                                           halt  # c=2854 pc=00000004
//                                                         c = core_top.sv の cycle、pc = そのサイクルにフェッチしていた pc
//   ./obj_dir/Vcore_top ... +bp=0x8                        pc=0x8 をフェッチしたサイクルで毎回レジスタ表示
//   ./obj_dir/Vcore_top ... +wave_from=100 +wave_len=50    cycle 100〜149 だけ wave.fst に波形を出す
//   ./obj_dir/Vcore_top ... +max_cycle=1000000             打ち切りサイクル数（既定 1e8）
//
// dpi_halt が呼ばれたら止める。
// 終了コード: 0 = halt した, 2 = max_cycle で打ち切り

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

#include "Vcore_top.h"
#include "Vcore_top__Dpi.h"
#include "verilated.h"
#include "verilated_fst_c.h"

static FILE *g_trace = nullptr;    // core.trace
static bool g_cycle_mode = false;  // +trace_mode=cycle
static bool g_halted = false;      // dpi_halt が呼ばれた
static uint64_t g_nwrite = 0;      // 報告された書き込みの数

// cycle モードで、書き込みの無いサイクルにも 1 行出すための状態
static bool g_have_cycle = false;  // dpi_pc_report を 1 回以上受け取った
static uint32_t g_cycle = 0;       // 今のサイクル（dpi_pc_report で受け取った値）
static uint32_t g_pc = 0;          // 今のサイクルにフェッチしている pc
static bool g_cycle_printed = false;  // 今のサイクルについて 1 行以上書いた

static void trace_suffix() {
  if(g_cycle_mode)
    std::fprintf(g_trace, "  # c=%u pc=%08x", g_cycle, g_pc);
  std::fprintf(g_trace, "\n");
  g_cycle_printed = true;
}

// cycle モードで、今のサイクルに何も書いていなければ "# c=... pc=..." の 1 行を書く
static void flush_cycle() {
  if(g_cycle_mode && g_have_cycle && !g_cycle_printed)
    std::fprintf(g_trace, "# c=%u pc=%08x\n", g_cycle, g_pc);
  g_cycle_printed = true;
}

// ---- core_top.sv から呼ばれる DPI 関数 ----
// core_top.sv は毎サイクル posedge で dpi_pc_report → dpi_reg_commit → dpi_mem_commit → dpi_halt の順に呼ぶ

// 毎サイクル最初に呼ばれる。前のサイクルに書き込みが無ければ、ここでその行を書く
void dpi_pc_report(int cycle, int pc) {
  flush_cycle();
  g_have_cycle = true;
  g_cycle = (uint32_t)cycle;
  g_pc = (uint32_t)pc;
  g_cycle_printed = false;
}

// WB でレジスタに書き込んだ（rf_idx は 0-31: x, 32-63: f）
void dpi_reg_commit(int cycle, int rf_idx, int wdata) {
  (void)cycle;
  std::fprintf(g_trace, "%c%02u=%08x", rf_idx < 32 ? 'x' : 'f', (unsigned)rf_idx % 32, (uint32_t)wdata);
  trace_suffix();
  g_nwrite++;
}

// MEM でメモリに書き込んだ
void dpi_mem_commit(int cycle, int mem_addr, int mem_wdata) {
  (void)cycle;
  std::fprintf(g_trace, "M[%08x]=%08x", (uint32_t)mem_addr, (uint32_t)mem_wdata);
  trace_suffix();
  g_nwrite++;
}

// halt が WB に来た
void dpi_halt(int cycle, int pc) {
  (void)cycle;
  (void)pc;
  std::fprintf(g_trace, "halt");
  trace_suffix();
  g_halted = true;
}

// ---- コマンドライン ----

// "+key=値" の値の部分を返す。無ければ def。
// commandArgsPlusMatch の戻り値は次の呼び出しで上書きされるので、必ず std::string にコピーする。
static std::string plusarg_str(VerilatedContext *ctx, const char *key, const char *def) {
  const char *s = ctx->commandArgsPlusMatch(key);  // "+key=値" がそのまま返る。無ければ ""
  const char *eq = *s ? std::strchr(s, '=') : nullptr;
  return eq ? std::string(eq + 1) : std::string(def);
}

static uint64_t plusarg_u64(VerilatedContext *ctx, const char *key, uint64_t def) {
  const std::string s = plusarg_str(ctx, key, "");
  return s.empty() ? def : std::strtoull(s.c_str(), nullptr, 0);  // 0x 付きの 16 進も可
}

// .bin（ビッグエンディアン生バイナリ）を、i_mem の $readmemh で読める .mem に書き直す
static bool bin_to_mem(const std::string &bin, const std::string &mem) {
  FILE *in = std::fopen(bin.c_str(), "rb");
  if(!in) {
    std::perror(bin.c_str());
    return false;
  }
  FILE *out = std::fopen(mem.c_str(), "w");
  if(!out) {
    std::perror(mem.c_str());
    std::fclose(in);
    return false;
  }
  unsigned char b[4];
  size_t n;
  while((n = std::fread(b, 1, 4, in)) > 0) {
    uint32_t w = 0;
    for(size_t i = 0; i < 4; i++)
      w |= (uint32_t)(i < n ? b[i] : 0) << (8 * (3 - i));  // 端数のバイトは 0 で埋める
    std::fprintf(out, "%08x\n", w);
  }
  std::fclose(in);
  std::fclose(out);
  return true;
}

static bool ends_with(const std::string &s, const std::string &suffix) {
  return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// ---- レジスタ表示 ----

// 7seg 用のデバッグポート (reg_dbg / reg_dbg_data) でレジスタファイルを直接読む。
// クロックは動かさないので CPU の状態は変わらない。
static uint32_t read_reg(Vcore_top *top, int idx) {  // 0-31: x, 32-63: f
  top->reg_dbg = idx;
  top->eval();
  return top->reg_dbg_data;
}

// 命令シミュレータの Reg::dump() と同じ形式（pc はフェッチ中の pc）
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
  // +imem= が .bin なら .mem に書き直し、RTL（i_mem の $value$plusargs）にはその .mem を渡す
  std::string imem;
  std::vector<std::string> args(argv, argv + argc);
  for(std::string &a: args) {
    if(a.rfind("+imem=", 0) != 0)
      continue;
    imem = a.substr(6);
    if(ends_with(imem, ".bin")) {
      const std::string converted = "obj_dir/imem_from_bin.mem";  // obj_dir は .gitignore 済み
      std::filesystem::create_directories("obj_dir");
      if(!bin_to_mem(imem, converted))
        return 1;
      a = "+imem=" + converted;
    }
  }
  std::vector<const char *> cargs;
  for(const std::string &a: args)
    cargs.push_back(a.c_str());

  auto ctx = std::make_unique<VerilatedContext>();
  ctx->commandArgs((int)cargs.size(), cargs.data());  // これで RTL 側の $value$plusargs からも +imem= などが見える
  ctx->traceEverOn(true);

  if(imem.empty()) {
    std::fprintf(stderr,
                 "usage: %s +imem=<prog.bin|prog.mem> [+core_trace=<file>] [+trace_mode=commit|cycle] "
                 "[+bp=<pc>] [+wave_from=<cycle>] ...\n",
                 argv[0]);
    return 1;
  }
  const std::string trace_path = plusarg_str(ctx.get(), "core_trace=", "core.trace");
  const std::string trace_mode = plusarg_str(ctx.get(), "trace_mode=", "commit");
  if(trace_mode == "cycle") {
    g_cycle_mode = true;
  } else if(trace_mode != "commit") {
    std::fprintf(stderr, "+trace_mode は commit か cycle（%s は無い）\n", trace_mode.c_str());
    return 1;
  }
  const uint64_t max_cycle = plusarg_u64(ctx.get(), "max_cycle=", 100'000'000ULL);
  const uint64_t wave_from = plusarg_u64(ctx.get(), "wave_from=", UINT64_MAX);
  const uint64_t wave_len = plusarg_u64(ctx.get(), "wave_len=", 200);
  const uint64_t bp = plusarg_u64(ctx.get(), "bp=", UINT64_MAX);

  if(!(g_trace = std::fopen(trace_path.c_str(), "w"))) {
    std::perror(trace_path.c_str());
    return 1;
  }

  // RTL を作る（ここで i_mem の initial が走り、+imem= のファイルを読む）
  auto top = std::make_unique<Vcore_top>(ctx.get(), "TOP");

  VerilatedFstC *tfp = nullptr;
  uint64_t cycle = 0;  // リセット解除後のサイクル数
  if(wave_from != UINT64_MAX) {
    tfp = new VerilatedFstC;
    top->trace(tfp, 99);
    tfp->open("wave.fst");
  }

  // d_mem と reg_file は negedge で書き込むので、1 サイクル = negedge → posedge の順に回す
  auto half = [&](int clk) {
    top->clk = clk;
    top->eval();
    if(tfp && cycle >= wave_from && cycle < wave_from + wave_len)
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

  while(!ctx->gotFinish() && !g_halted && cycle < max_cycle) {
    if(top->pc_dbg == bp) {
      std::fflush(g_trace);
      std::fprintf(stderr, "[bp] pc=0x%08x  write#%llu  cycle=%llu\n", top->pc_dbg,
                   (unsigned long long)g_nwrite, (unsigned long long)cycle);
      dump_regs(top.get(), stderr);
    }
    tick();
    cycle++;
  }

  int rc;
  if(g_halted) {
    std::fprintf(stderr, "RTL: halt（%llu cycles、書き込み %llu 個）\n", (unsigned long long)cycle,
                 (unsigned long long)g_nwrite);
    rc = 0;
  } else {
    flush_cycle();  // 最後のサイクルに書き込みが無かったときの行
    std::fprintf(stderr, "RTL: TIMEOUT（%llu cycles で打ち切り、書き込み %llu 個）\n",
                 (unsigned long long)cycle, (unsigned long long)g_nwrite);
    rc = 2;
  }
  std::fclose(g_trace);
  std::fprintf(stderr, "出力: %s\n", trace_path.c_str());
  dump_regs(top.get(), stdout);

  top->final();
  if(tfp) {
    tfp->close();
    delete tfp;
  }
  return rc;
}
