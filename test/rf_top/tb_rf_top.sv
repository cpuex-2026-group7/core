`timescale 1ns / 1ps
`default_nettype none

// rf_top のテストベンチ（Verilator の --binary --timing で動かす）
//
// 構成はビルド時に -G で決める（Makefile の CONFIGS を参照）
//
// 実行時オプション
//   +cycles=N  ランダムテストのサイクル数（既定 200000）
//   +seed=N    乱数の種（既定 1）
//   +log=PATH  進捗をこのファイルに追記する。1 行ごとに flush
//
// 参照モデルは PRF の中身を I / F の配列で持ち、毎サイクル次を独立に計算して DUT と突き合わせる
//   - complete_idx（組み合わせ出力）
//   - 次のサイクルの ex_ff_int / ex_ff_mem / ex_ff_fpu の全フィールド
//
// テストの前提にしている仕様
//   - PRF の書き込みは立ち上がりで反映。初期値は 0
//   - 書き込みポート：wb_alu→I、wb_mem→I/F、wb_fpu[0]→F、wb_fpu[1]→I/F（ftoi は I）、wb_fpu[2]→F。I は 3W。
//     valid=0、rd.typ が NONE、ポートに無い方の typ は書かない
//   - 読み出し：I は 5R。INT の rs1/rs2 と MEM の rs1 は I。MEM の rs2 と FPU長 の rs1 は typ が F なら F、そうでなければ I
//     （MEM の rs2 は sw なら I、fsw なら F）。それ以外（FPU短 / FPU長 の rs2 / FPU超長）は F
//   - ソースの値：typ が NONE なら 0。同じサイクルの WB に valid で rd（typ と idx）が一致するものがあればその value
//     （バイパス）。複数当たったら wb_alu, wb_mem, wb_fpu[0], wb_fpu[1], wb_fpu[2] の順で先のもの。無ければ PRF
//   - valid = !rst && !flush && rr.valid && mispredict した分岐に依存していない
//   - brmask は当たった分岐（valid && !mispredict）のビットを落とす
//   - rd / rs1 / rs2 / dest_fu / payload / MEM の issue_part はそのまま 1 サイクル遅れで出る
//   - complete_idx[k] は WB の k 番目（alu, mem, fpu0, fpu1, fpu2）の valid と rob_idx をそのまま出す

module tb_rf_top
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import iq_types::*;
  import rr_types::*;
  import ex_types::*;
  import rob_types::*;
#(
  parameter int I_PREG_NUM = 64,
  parameter int F_PREG_NUM = 64,
  parameter int BR_UPDATE_W = 1
);

  localparam int NL = 5;  // レーン：0 INT, 1 MEM, 2 FPU短, 3 FPU長, 4 FPU超長
  localparam int NW = 5;  // WB：0 alu, 1 mem, 2 fpu0, 3 fpu1, 4 fpu2
  localparam int RI = 0;
  localparam int RF = 1;
  localparam int NPREG = 64;
  localparam int MAX_ERRORS = 30;

  typedef logic [63:0] cyc_t;

  function automatic string l_name(int l);
    case (l)
      0: return "INT";
      1: return "MEM";
      2: return "FPU短";
      3: return "FPU長";
      default: return "FPU超長";
    endcase
  endfunction

  function automatic string w_name(int w);
    case (w)
      0: return "wb_alu";
      1: return "wb_mem";
      2: return "wb_fpu[0]";
      3: return "wb_fpu[1]";
      default: return "wb_fpu[2]";
    endcase
  endfunction

  function automatic int p_size(int f);
    return (f == RI) ? I_PREG_NUM : F_PREG_NUM;
  endfunction

  logic clk = 1'b0;
  always #5 clk = ~clk;

  // テストが書く入力
  logic rst;
  logic flush;
  iq_rr_t rr[NL];
  int_payload_t pl_int;
  mem_payload_t pl_mem;
  logic [1:0] part_mem;
  float_payload_t pl_fpu[3];
  ex_wb_t wb[NW];
  br_update_t br[BR_UPDATE_W];

  // DUT につなぐ側。initial から直接書くと組み合わせ回路が評価し直されないことがあるので、立ち下がりで写す
  logic d_rst;
  logic d_flush;
  iq_rr_t d_rr_int[1];
  iq_rr_t d_rr_mem[1];
  iq_rr_t d_rr_fpu[3];
  int_payload_t d_pl_int[1];
  mem_payload_t d_pl_mem[1];
  logic [1:0] d_part_mem[1];
  float_payload_t d_pl_fpu[3];
  ex_wb_t d_wb_alu[1];
  ex_wb_t d_wb_mem[1];
  ex_wb_t d_wb_fpu[3];
  br_update_t d_br[BR_UPDATE_W];

  always @(negedge clk) begin
    d_rst <= rst;
    d_flush <= flush;
    d_rr_int[0] <= rr[0];
    d_rr_mem[0] <= rr[1];
    d_rr_fpu[0] <= rr[2];
    d_rr_fpu[1] <= rr[3];
    d_rr_fpu[2] <= rr[4];
    d_pl_int[0] <= pl_int;
    d_pl_mem[0] <= pl_mem;
    d_part_mem[0] <= part_mem;
    d_pl_fpu <= pl_fpu;
    d_wb_alu[0] <= wb[0];
    d_wb_mem[0] <= wb[1];
    d_wb_fpu[0] <= wb[2];
    d_wb_fpu[1] <= wb[3];
    d_wb_fpu[2] <= wb[4];
    d_br <= br;
  end

  rr_ex_int_t ex_int[1];
  rr_ex_mem_t ex_mem[1];
  rr_ex_float_t ex_fpu[3];
  complete_t cmp[5];

  rf_top #(
    .I_PREG_NUM(I_PREG_NUM),
    .F_PREG_NUM(F_PREG_NUM),
    .BR_UPDATE_W(BR_UPDATE_W)
  ) dut (
    .clk(clk),
    .rst(d_rst),
    .flush(d_flush),
    .rr_ff_int(d_rr_int),
    .rr_payload_int(d_pl_int),
    .rr_ff_mem(d_rr_mem),
    .rr_payload_mem(d_pl_mem),
    .rr_issue_part_mem(d_part_mem),
    .rr_ff_fpu(d_rr_fpu),
    .rr_payload_fpu(d_pl_fpu),
    .ex_ff_int(ex_int),
    .ex_ff_mem(ex_mem),
    .ex_ff_fpu(ex_fpu),
    .wb_alu(d_wb_alu),
    .wb_mem(d_wb_mem),
    .wb_fpu(d_wb_fpu),
    .complete_idx(cmp),
    .br_update(d_br)
  );

  function automatic rr_ex_t o_common(int l);
    case (l)
      0: return ex_int[0].common;
      1: return ex_mem[0].common;
      default: return ex_fpu[l-2].common;
    endcase
  endfunction

  // ---------------- 乱数（xorshift64） ----------------

  logic [63:0] rng_state;

  function automatic int rnd(int n);
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return int'(rng_state % 64'(n));
  endfunction

  function automatic word_t rword();
    return {16'(rnd(65536)), 16'(rnd(65536))};
  endfunction

  // ---------------- 値を作る補助 ----------------

  function automatic preg_t mk_preg(preg_type_t t, int i);
    preg_t p;
    p.typ = t;
    p.idx = preg_idx_t'(i);
    return p;
  endfunction

  function automatic preg_t pi(int i);
    return mk_preg(PREG_TYPE_I, i % I_PREG_NUM);
  endfunction

  function automatic preg_t pf(int i);
    return mk_preg(PREG_TYPE_F, i % F_PREG_NUM);
  endfunction

  // NONE の idx はわざとでたらめにする
  function automatic preg_t pn();
    return mk_preg(PREG_TYPE_NONE, rnd(NPREG));
  endfunction

  function automatic brmask_t bit_of(int t);
    brmask_t b;
    b = '0;
    b[t] = 1'b1;
    return b;
  endfunction

  // ---------------- 仕様（参照モデル） ----------------

  // WB ポート w が typ t をどちらの PRF に書くか（書かないなら -1）
  function automatic int wb_file(int w, preg_type_t t);
    case (w)
      0: return (t == PREG_TYPE_I) ? RI : -1;
      1, 3: return (t == PREG_TYPE_I) ? RI : (t == PREG_TYPE_F) ? RF : -1;
      default: return (t == PREG_TYPE_F) ? RF : -1;
    endcase
  endfunction

  // レーン l のソース s（0: rs1, 1: rs2）をどちらの PRF から読むか
  function automatic int src_file(int l, int s, preg_type_t t);
    case (l)
      0: return RI;
      1: return (s == 0) ? RI : ((t == PREG_TYPE_F) ? RF : RI);
      3: return (s == 0) ? ((t == PREG_TYPE_F) ? RF : RI) : RF;
      default: return RF;
    endcase
  endfunction

  word_t prf[2][NPREG];

  // バイパスで当たる WB（無ければ -1）
  function automatic int byp_hit(preg_t p);
    for (int w = 0; w < NW; w++) if (wb[w].valid && wb[w].rd == p) return w;
    return -1;
  endfunction

  function automatic word_t src_value(int l, int s, preg_t p);
    int w;
    if (p.typ == PREG_TYPE_NONE) return '0;
    w = byp_hit(p);
    if (w >= 0) return wb[w].value;
    return prf[src_file(l, s, p.typ)][p.idx];
  endfunction

  function automatic logic killed(brmask_t bm);
    for (int u = 0; u < BR_UPDATE_W; u++) if (br[u].valid && br[u].mispredict && bm[br[u].tag]) return 1'b1;
    return 1'b0;
  endfunction

  function automatic brmask_t resolved(brmask_t bm);
    brmask_t r;
    r = bm;
    for (int u = 0; u < BR_UPDATE_W; u++) if (br[u].valid && !br[u].mispredict) r[br[u].tag] = 1'b0;
    return r;
  endfunction

  // ---------------- 期待値と照合 ----------------

  rr_ex_t exp_c[NL];
  int_payload_t exp_pl_int;
  mem_payload_t exp_pl_mem;
  logic [1:0] exp_part_mem;
  float_payload_t exp_pl_fpu[3];
  complete_t exp_cmp[NW];

  cyc_t cyc;
  cyc_t cyc_limit;
  int errors;
  longint checks;
  int n_tests;
  int n_fail;
  string test_name;
  int logf;

  // 網羅できているかの数え上げ
  longint st_byp_hit;
  longint st_byp_over_write;  // 同じサイクルに PRF に書く preg をバイパスで取った
  longint st_byp_no_write;  // バイパスで当たったが PRF には書かない WB（ポートに無い typ）
  longint st_none;
  longint st_kill;
  longint st_clear;
  longint st_fsel;  // FPU長 rs1 で F を読んだ
  longint st_isel;  // FPU長 rs1 で I を読んだ
  longint st_ignored_wr;  // valid だが書かない WB（NONE / ポートに無い typ）
  longint st_rst;
  longint st_flush;

  task automatic say(string s);
    $display("%s", s);
    $fflush();
    if (logf != 0) begin
      $fdisplay(logf, "%s", s);
      $fflush(logf);
    end
  endtask

  task automatic fail(string msg);
    errors++;
    if (errors <= MAX_ERRORS) say($sformatf("[NG] %s: cycle %0d: %s", test_name, cyc, msg));
    if (errors == MAX_ERRORS) begin
      say($sformatf("エラーが %0d 個になったので打ち切る", MAX_ERRORS));
      $fatal(1, "FAIL");
    end
  endtask

  function automatic logic written_now(int f, preg_idx_t idx);
    for (int w = 0; w < NW; w++) if (wb[w].valid && wb_file(w, wb[w].rd.typ) == f && wb[w].rd.idx == idx) return 1'b1;
    return 1'b0;
  endfunction

  task automatic compute_expect();
    preg_t s;
    for (int l = 0; l < NL; l++) begin
      exp_c[l].valid = !rst && !flush && rr[l].valid && !killed(rr[l].brmask);
      exp_c[l].rd = rr[l].rd;
      exp_c[l].rs1 = rr[l].rs1;
      exp_c[l].rs2 = rr[l].rs2;
      exp_c[l].rs1_val = src_value(l, 0, rr[l].rs1);
      exp_c[l].rs2_val = src_value(l, 1, rr[l].rs2);
      exp_c[l].dest_fu = rr[l].dest_fu;
      exp_c[l].brmask = resolved(rr[l].brmask);

      if (rr[l].valid && killed(rr[l].brmask)) st_kill++;
      if (resolved(rr[l].brmask) != rr[l].brmask) st_clear++;
      for (int k = 0; k < 2; k++) begin
        s = (k == 0) ? rr[l].rs1 : rr[l].rs2;
        if (s.typ == PREG_TYPE_NONE) begin
          st_none++;
        end else begin
          if (byp_hit(s) >= 0) begin
            st_byp_hit++;
            if (written_now(src_file(l, k, s.typ), s.idx)) st_byp_over_write++;
            else st_byp_no_write++;
          end
          if (l == 3 && k == 0) begin
            if (src_file(l, k, s.typ) == RF) st_fsel++;
            else st_isel++;
          end
        end
      end
    end
    exp_pl_int = pl_int;
    exp_pl_mem = pl_mem;
    exp_part_mem = part_mem;
    exp_pl_fpu = pl_fpu;
    for (int w = 0; w < NW; w++) begin
      exp_cmp[w].valid = wb[w].valid;
      exp_cmp[w].rob_idx = wb[w].rob_idx;
      if (wb[w].valid && wb_file(w, wb[w].rd.typ) < 0) st_ignored_wr++;
    end
    if (rst) st_rst++;
    if (flush) st_flush++;
  endtask

  task automatic check_comb();
    for (int w = 0; w < NW; w++) begin
      checks++;
      if (cmp[w] !== exp_cmp[w])
        fail($sformatf("complete_idx[%0d]（%s）= valid %b rob %h、期待 valid %b rob %h", w, w_name(w), cmp[w].valid,
                       cmp[w].rob_idx, exp_cmp[w].valid, exp_cmp[w].rob_idx));
    end
  endtask

  task automatic check_ex();
    rr_ex_t o;
    rr_ex_t e;
    for (int l = 0; l < NL; l++) begin
      o = o_common(l);
      e = exp_c[l];
      checks++;
      if (o !== e)
        fail($sformatf("%s: 実際/期待 valid %b/%b rd %h/%h rs1 %h/%h rs2 %h/%h rs1_val %h/%h rs2_val %h/%h %s",
                       l_name(l), o.valid, e.valid, o.rd, e.rd, o.rs1, e.rs1, o.rs2, e.rs2, o.rs1_val, e.rs1_val,
                       o.rs2_val, e.rs2_val, $sformatf("dest_fu %h/%h brmask %h/%h", o.dest_fu, e.dest_fu, o.brmask,
                                                       e.brmask)));
    end
    checks += 5;
    if (ex_int[0].payload !== exp_pl_int)
      fail($sformatf("INT payload %h、期待 %h", ex_int[0].payload, exp_pl_int));
    if (ex_mem[0].payload !== exp_pl_mem)
      fail($sformatf("MEM payload %h、期待 %h", ex_mem[0].payload, exp_pl_mem));
    if (ex_mem[0].issue_part !== exp_part_mem)
      fail($sformatf("MEM issue_part %b、期待 %b", ex_mem[0].issue_part, exp_part_mem));
    for (int p = 0; p < 3; p++)
      if (ex_fpu[p].payload !== exp_pl_fpu[p])
        fail($sformatf("%s payload %h、期待 %h", l_name(2 + p), ex_fpu[p].payload, exp_pl_fpu[p]));
  endtask

  task automatic model_advance();
    int f;
    for (int w = 0; w < NW; w++) begin
      f = wb_file(w, wb[w].rd.typ);
      if (wb[w].valid && f >= 0) prf[f][wb[w].rd.idx] = wb[w].value;
    end
  endtask

  // 入力はここまでに書いておく。戻ったときには、その入力に対する ex_ff が出ている
  task automatic cycle();
    @(negedge clk);
    #2;
    compute_expect();
    check_comb();
    @(posedge clk);
    #1;
    model_advance();
    check_ex();
    cyc++;
    if (cyc > cyc_limit) begin
      say($sformatf("[NG] %s: cycle %0d を超えても終わらない（ハング）", test_name, cyc_limit));
      $fatal(1, "FAIL");
    end
  endtask

  // ---------------- 入力を作る補助 ----------------

  task automatic clear_inputs();
    rst = 1'b0;
    flush = 1'b0;
    for (int l = 0; l < NL; l++) begin
      rr[l] = '0;
      rr[l].rd = mk_preg(PREG_TYPE_NONE, 0);
      rr[l].rs1 = mk_preg(PREG_TYPE_NONE, 0);
      rr[l].rs2 = mk_preg(PREG_TYPE_NONE, 0);
    end
    pl_int = '0;
    pl_mem = '0;
    part_mem = 2'b11;
    for (int p = 0; p < 3; p++) pl_fpu[p] = '0;
    for (int w = 0; w < NW; w++) begin
      wb[w] = '0;
      wb[w].rd = mk_preg(PREG_TYPE_NONE, 0);
    end
    for (int u = 0; u < BR_UPDATE_W; u++) br[u] = '0;
  endtask

  task automatic set_src(int l, preg_t a, preg_t b);
    rr[l].rs1 = a;
    rr[l].rs2 = b;
  endtask

  task automatic set_wb(int w, preg_t p, word_t v);
    wb[w].valid = 1'b1;
    wb[w].rd = p;
    wb[w].value = v;
    wb[w].rob_idx = rob_idx_t'(rnd(ROB_SIZE));
  endtask

  task automatic expect_val(int l, int s, word_t v, string what);
    rr_ex_t o;
    o = o_common(l);
    checks++;
    if (((s == 0) ? o.rs1_val : o.rs2_val) !== v)
      fail($sformatf("%s: %s の rs%0d_val = %h、期待 %h", what, l_name(l), s + 1, (s == 0) ? o.rs1_val : o.rs2_val, v));
  endtask

  task automatic expect_valid(int l, logic v, string what);
    rr_ex_t o;
    o = o_common(l);
    checks++;
    if (o.valid !== v) fail($sformatf("%s: %s の valid = %b、期待 %b", what, l_name(l), o.valid, v));
  endtask

  task automatic expect_brmask(int l, brmask_t b, string what);
    rr_ex_t o;
    o = o_common(l);
    checks++;
    if (o.brmask !== b) fail($sformatf("%s: %s の brmask = %b、期待 %b", what, l_name(l), o.brmask, b));
  endtask

  function automatic word_t ival(int k);
    return 32'h1000_0000 + 32'(k);
  endfunction

  function automatic word_t fval(int k);
    return 32'h2000_0000 + 32'(k);
  endfunction

  // I[k] = ival(k)、F[k] = fval(k) にしておく（alu と fpu0 で書く）
  task automatic fill_known();
    int n;
    n = (I_PREG_NUM > F_PREG_NUM) ? I_PREG_NUM : F_PREG_NUM;
    for (int k = 0; k < n; k++) begin
      clear_inputs();
      if (k < I_PREG_NUM) set_wb(0, mk_preg(PREG_TYPE_I, k), ival(k));
      if (k < F_PREG_NUM) set_wb(2, mk_preg(PREG_TYPE_F, k), fval(k));
      cycle();
    end
    clear_inputs();
  endtask

  task automatic begin_test(string name);
    test_name = name;
    n_tests++;
    clear_inputs();
  endtask

  task automatic end_test(int err0);
    if (errors == err0) begin
      say($sformatf("[OK] %s", test_name));
    end else begin
      n_fail++;
      say($sformatf("[NG] %s（エラー %0d 個）", test_name, errors - err0));
    end
  endtask

  // ---------------- 決め打ちのテスト ----------------

  task automatic t_reset();
    int e0;
    e0 = errors;
    begin_test("rst 中は valid が立たない");
    rst = 1'b1;
    for (int l = 0; l < NL; l++) rr[l].valid = 1'b1;
    cycle();
    for (int l = 0; l < NL; l++) expect_valid(l, 1'b0, "rst=1");
    rst = 1'b0;
    cycle();
    for (int l = 0; l < NL; l++) expect_valid(l, 1'b1, "rst 解除");
    for (int l = 0; l < NL; l++) rr[l].valid = 1'b0;
    cycle();
    for (int l = 0; l < NL; l++) expect_valid(l, 1'b0, "rr.valid=0");
    end_test(e0);
  endtask

  task automatic t_initial_zero();
    int e0;
    e0 = errors;
    begin_test("書く前の PRF は 0");
    set_src(0, pi(I_PREG_NUM - 1), pi(0));
    set_src(2, pf(F_PREG_NUM - 1), pf(0));
    cycle();
    expect_val(0, 0, '0, "初期値");
    expect_val(0, 1, '0, "初期値");
    expect_val(2, 0, '0, "初期値");
    expect_val(2, 1, '0, "初期値");
    end_test(e0);
  endtask

  // 各 WB ポートが I / F / NONE のどれを、どちらの PRF に書くか
  task automatic t_write_ports();
    int e0;
    preg_type_t t;
    word_t v;
    logic wi, wf;
    e0 = errors;
    begin_test("WB ポートごとの書き込み先");
    for (int w = 0; w < NW; w++) begin
      for (int ti = 0; ti < 4; ti++) begin
        // 毎回 I[1] と F[1] を既知の値に戻してから書く
        clear_inputs();
        set_wb(0, pi(1), 32'haaaa_0000 + 32'(w * 16 + ti));
        set_wb(2, pf(1), 32'hbbbb_0000 + 32'(w * 16 + ti));
        cycle();
        clear_inputs();
        t = (ti == 0) ? PREG_TYPE_I : (ti == 1) ? PREG_TYPE_F : PREG_TYPE_NONE;
        v = 32'hcccc_0000 + 32'(w * 16 + ti);
        set_wb(w, mk_preg(t, 1), v);
        if (ti == 3) wb[w].valid = 1'b0;  // valid=0 で I を書こうとする
        if (ti == 3) wb[w].rd.typ = PREG_TYPE_I;
        cycle();
        clear_inputs();
        set_src(0, pi(1), pi(1));
        set_src(2, pf(1), pf(1));
        cycle();
        // ポートが持つ PRF（仕様どおりに手で書いた表）
        wi = (ti == 0) && (w == 0 || w == 1 || w == 3);
        wf = (ti == 1) && (w == 1 || w == 2 || w == 3 || w == 4);
        expect_val(0, 0, wi ? v : 32'haaaa_0000 + 32'(w * 16 + ti),
                   $sformatf("%s が typ=%0d valid=%b で書いた後の I[1]", w_name(w), ti == 3 ? 0 : t, ti != 3));
        expect_val(2, 0, wf ? v : 32'hbbbb_0000 + 32'(w * 16 + ti),
                   $sformatf("%s が typ=%0d valid=%b で書いた後の F[1]", w_name(w), ti == 3 ? 0 : t, ti != 3));
      end
    end
    end_test(e0);
  endtask

  // 全レーン・全ソースの読み出し先（I と F で同じ idx に違う値を入れておく）
  task automatic t_read_ports();
    int e0;
    int n;
    e0 = errors;
    begin_test("レーン・ソースごとの読み出し先");
    fill_known();
    n = (I_PREG_NUM < F_PREG_NUM) ? I_PREG_NUM : F_PREG_NUM;
    if (n > 8) n = 8;
    for (int k = 0; k < n; k++) begin
      clear_inputs();
      set_src(0, pi(k), pi(n - 1 - k));
      set_src(1, pi(k), pf(n - 1 - k));
      set_src(2, pf(k), pf(n - 1 - k));
      set_src(3, pi(k), pf(n - 1 - k));
      set_src(4, pf(k), pf(n - 1 - k));
      cycle();
      expect_val(0, 0, ival(k), "INT rs1 は I");
      expect_val(0, 1, ival(n - 1 - k), "INT rs2 は I");
      expect_val(1, 0, ival(k), "MEM rs1 は I");
      expect_val(1, 1, fval(n - 1 - k), "MEM rs2 は F");
      expect_val(2, 0, fval(k), "FPU短 rs1 は F");
      expect_val(2, 1, fval(n - 1 - k), "FPU短 rs2 は F");
      expect_val(3, 0, ival(k), "FPU長 rs1 が I のとき I");
      expect_val(3, 1, fval(n - 1 - k), "FPU長 rs2 は F");
      expect_val(4, 0, fval(k), "FPU超長 rs1 は F");
      expect_val(4, 1, fval(n - 1 - k), "FPU超長 rs2 は F");
      clear_inputs();
      set_src(3, pf(k), pf(k));
      cycle();
      expect_val(3, 0, fval(k), "FPU長 rs1 が F のとき F");
    end
    end_test(e0);
  endtask

  // 書き込みと同じサイクルの読み出しはバイパスで新しい値、次のサイクルは PRF から新しい値
  task automatic t_same_cycle();
    int e0;
    e0 = errors;
    begin_test("書き込みと同じサイクルの読み出し");
    fill_known();
    clear_inputs();
    set_wb(0, pi(2), 32'h1111_1111);
    set_wb(1, pi(3), 32'h2222_2222);
    set_wb(3, pi(4), 32'h3333_3333);
    set_wb(2, pf(2), 32'h4444_4444);
    set_wb(4, pf(3), 32'h5555_5555);
    set_src(0, pi(2), pi(3));
    set_src(1, pi(4), pf(2));
    set_src(2, pf(2), pf(3));
    set_src(3, pi(2), pf(3));
    set_src(4, pf(3), pf(2));
    cycle();
    expect_val(0, 0, 32'h1111_1111, "同じサイクル（wb_alu）");
    expect_val(0, 1, 32'h2222_2222, "同じサイクル（wb_mem）");
    expect_val(1, 0, 32'h3333_3333, "同じサイクル（wb_fpu[1]）");
    expect_val(1, 1, 32'h4444_4444, "同じサイクル（wb_fpu[0]）");
    expect_val(2, 1, 32'h5555_5555, "同じサイクル（wb_fpu[2]）");
    for (int w = 0; w < NW; w++) wb[w].valid = 1'b0;
    cycle();
    expect_val(0, 0, 32'h1111_1111, "次のサイクル");
    expect_val(0, 1, (3 % I_PREG_NUM == 4 % I_PREG_NUM) ? 32'h3333_3333 : 32'h2222_2222, "次のサイクル");
    expect_val(2, 0, (2 % F_PREG_NUM == 3 % F_PREG_NUM) ? 32'h5555_5555 : 32'h4444_4444, "次のサイクル");
    end_test(e0);
  endtask

  task automatic t_none();
    int e0;
    e0 = errors;
    begin_test("NONE のソースは 0");
    fill_known();
    clear_inputs();
    // idx 0 にも値が入っている。NONE で idx 0 / でたらめな idx を読む
    set_src(0, mk_preg(PREG_TYPE_NONE, 0), mk_preg(PREG_TYPE_NONE, 5));
    set_src(1, mk_preg(PREG_TYPE_NONE, 0), mk_preg(PREG_TYPE_NONE, 63));
    set_src(2, mk_preg(PREG_TYPE_NONE, 0), mk_preg(PREG_TYPE_NONE, 1));
    set_src(3, mk_preg(PREG_TYPE_NONE, 0), mk_preg(PREG_TYPE_NONE, 2));
    set_src(4, mk_preg(PREG_TYPE_NONE, 0), mk_preg(PREG_TYPE_NONE, 3));
    // rd が NONE の WB と、同じ idx の I に書く WB があっても 0
    set_wb(1, mk_preg(PREG_TYPE_NONE, 0), 32'hdead_beef);
    set_wb(0, pi(0), 32'hfeed_f00d);
    cycle();
    for (int l = 0; l < NL; l++) begin
      expect_val(l, 0, '0, "NONE");
      expect_val(l, 1, '0, "NONE");
    end
    end_test(e0);
  endtask

  task automatic t_bypass();
    int e0;
    preg_t p;
    word_t v;
    int lane;
    word_t other;
    e0 = errors;
    begin_test("バイパス");
    fill_known();
    // 各 WB ポートが、書く typ ごとに当たる
    for (int w = 0; w < NW; w++) begin
      for (int ti = 0; ti < 2; ti++) begin
        if (wb_file(w, (ti == 0) ? PREG_TYPE_I : PREG_TYPE_F) < 0) continue;
        clear_inputs();
        p = (ti == 0) ? pi(1) : pf(1);
        lane = (ti == 0) ? 0 : 2;
        v = 32'h7000_0000 + 32'(w * 4 + ti);
        other = (ti == 0) ? prf[RF][1 % F_PREG_NUM] : prf[RI][1 % I_PREG_NUM];
        set_wb(w, p, v);
        set_src(lane, p, (ti == 0) ? pi(2) : pf(2));
        set_src((ti == 0) ? 2 : 0, (ti == 0) ? pf(1) : pi(1), pn());  // 同じ idx で typ が違うものは当たらない
        cycle();
        expect_val(lane, 0, v, $sformatf("%s の typ=%0d が当たる", w_name(w), ti));
        expect_val(lane, 1, (ti == 0) ? ival(2 % I_PREG_NUM) : fval(2 % F_PREG_NUM),
                   $sformatf("%s と違う idx", w_name(w)));
        // 前の繰り返しで書いた値が入っているのでモデルの PRF と比べる
        expect_val((ti == 0) ? 2 : 0, 0, other, $sformatf("%s と typ が違う", w_name(w)));
        // valid=0 なら当たらず、書かれてもいない
        wb[w].value = v ^ 32'hffff_ffff;
        wb[w].valid = 1'b0;
        cycle();
        expect_val(lane, 0, v, $sformatf("%s が valid=0（前のサイクルに書いた値）", w_name(w)));
      end
    end
    // 全レーン・全ソース（FPU長 rs1 は I と F の両方）。I は wb_alu、F は wb_fpu[2] から
    for (int l = 0; l < NL; l++) begin
      for (int s = 0; s < 2; s++) begin
        for (int ft = 0; ft < 2; ft++) begin
          if (ft == 1 && !(l == 3 && s == 0)) continue;
          clear_inputs();
          if ((l == 0) || (l == 1 && s == 0)) p = pi(3);
          else if (l == 3 && s == 0) p = (ft == 0) ? pi(3) : pf(3);
          else p = pf(3);
          v = 32'h6000_0000 + 32'(l * 16 + s * 4 + ft);
          set_wb((p.typ == PREG_TYPE_I) ? 0 : 4, p, v);
          if (s == 0) set_src(l, p, pn());
          else set_src(l, pn(), p);
          cycle();
          expect_val(l, s, v, "全ソースのバイパス");
        end
      end
    end
    // ポートに無い typ の WB は PRF に書かないが、バイパスでは当たる
    clear_inputs();
    set_wb(0, pf(5), 32'h0bad_cafe);
    set_src(2, pf(5), pf(5));
    cycle();
    expect_val(2, 0, 32'h0bad_cafe, "wb_alu が F を書こうとしたときのバイパス");
    clear_inputs();
    set_src(2, pf(5), pf(5));
    cycle();
    expect_val(2, 0, prf[RF][5 % F_PREG_NUM], "wb_alu の F は PRF に書かない");
    end_test(e0);
  endtask

  // 全 WB ポートと全読み出しポートを同時に使う
  task automatic t_all_ports();
    int e0;
    e0 = errors;
    begin_test("全ポート同時");
    fill_known();
    for (int r = 0; r < 20; r++) begin
      clear_inputs();
      // I は alu / mem / fpu1、F は fpu0 / fpu2 に分ける（idx は重ならない）
      set_wb(0, pi(r), rword());
      set_wb(1, pi(r + 1), rword());
      set_wb(3, pi(r + 2), rword());
      set_wb(2, pf(r), rword());
      set_wb(4, pf(r + 1), rword());
      if (I_PREG_NUM < 3) wb[3].valid = 1'b0;
      if (F_PREG_NUM < 2) wb[4].valid = 1'b0;
      for (int l = 0; l < NL; l++) rr[l].valid = 1'b1;
      set_src(0, pi(r), pi(r + 3));
      set_src(1, pi(r + 1), pf(r + 2));
      set_src(2, pf(r), pf(r + 1));
      set_src(3, pi(r + 2), pf(r + 3));
      set_src(4, pf(r + 2), pf(r));
      cycle();
      for (int l = 0; l < NL; l++) expect_valid(l, 1'b1, "全ポート");
    end
    // mem と fpu1 が F、alu が I のパターン
    for (int r = 0; r < 20; r++) begin
      clear_inputs();
      set_wb(0, pi(r), rword());
      set_wb(1, pf(r), rword());
      set_wb(3, pf(r + 1), rword());
      set_wb(2, pf(r + 2), rword());
      set_wb(4, pf(r + 3), rword());
      if (F_PREG_NUM < 4) begin
        wb[2].valid = 1'b0;
        wb[4].valid = 1'b0;
      end
      set_src(0, pi(r), pi(r + 1));
      set_src(1, pi(r), pf(r));
      set_src(2, pf(r + 1), pf(r + 2));
      set_src(3, pf(r + 3), pf(r));
      set_src(4, pf(r + 1), pf(r + 3));
      cycle();
    end
    // I の 4 ポート（alu / mem / fpu0 / fpu1）が全部同時に書く
    for (int r = 0; r < 20; r++) begin
      clear_inputs();
      set_wb(0, pi(r), rword());
      set_wb(1, pi(r + 1), rword());
      set_wb(2, pi(r + 2), rword());
      set_wb(3, pi(r + 3), rword());
      set_wb(4, pf(r), rword());
      if (I_PREG_NUM < 4) wb[3].valid = 1'b0;
      set_src(0, pi(r), pi(r + 2));
      set_src(1, pi(r + 1), pf(r));
      set_src(3, pi(r + 3), pf(r));
      cycle();
    end
    clear_inputs();
    cycle();
    end_test(e0);
  endtask

  task automatic t_branch();
    int e0;
    e0 = errors;
    begin_test("分岐の kill とビット落とし");
    for (int u = 0; u < BR_UPDATE_W; u++) begin
      for (int t = 0; t < MAX_BR; t++) begin
        // mispredict：ビットが立っているレーンだけ消える
        clear_inputs();
        for (int l = 0; l < NL; l++) begin
          rr[l].valid = 1'b1;
          rr[l].brmask = (l % 2 == 0) ? (bit_of(t) | bit_of((t + 1) % MAX_BR)) : bit_of((t + 1) % MAX_BR);
        end
        br[u].valid = 1'b1;
        br[u].mispredict = 1'b1;
        br[u].tag = br_tag_t'(t);
        cycle();
        for (int l = 0; l < NL; l++) expect_valid(l, l % 2 != 0, $sformatf("update[%0d] tag %0d mispredict", u, t));
        // 当たった：ビットが落ちて valid はそのまま
        br[u].mispredict = 1'b0;
        cycle();
        for (int l = 0; l < NL; l++) begin
          expect_valid(l, 1'b1, $sformatf("update[%0d] tag %0d resolve", u, t));
          expect_brmask(l, (l % 2 == 0) ? bit_of((t + 1) % MAX_BR) : bit_of((t + 1) % MAX_BR),
                        $sformatf("update[%0d] tag %0d resolve", u, t));
        end
        // valid=0 の update は何もしない
        br[u].valid = 1'b0;
        br[u].mispredict = 1'b1;
        cycle();
        for (int l = 0; l < NL; l++) begin
          expect_valid(l, 1'b1, $sformatf("update[%0d] valid=0", u));
          expect_brmask(l, rr[l].brmask, $sformatf("update[%0d] valid=0", u));
        end
        // rr.valid=0 なら kill されなくても valid=0
        for (int l = 0; l < NL; l++) rr[l].valid = 1'b0;
        br[u].valid = 1'b1;
        br[u].mispredict = 1'b0;
        cycle();
        for (int l = 0; l < NL; l++) expect_valid(l, 1'b0, "rr.valid=0");
      end
    end
    // 複数の update が同時に来る（片方 mispredict、片方 resolve）
    if (BR_UPDATE_W >= 2) begin
      clear_inputs();
      for (int l = 0; l < NL; l++) rr[l].valid = 1'b1;
      rr[0].brmask = bit_of(1) | bit_of(2);
      rr[1].brmask = bit_of(2);
      rr[2].brmask = bit_of(1);
      rr[3].brmask = '0;
      rr[4].brmask = bit_of(2) | bit_of(3);
      br[0].valid = 1'b1;
      br[0].mispredict = 1'b1;
      br[0].tag = br_tag_t'(1);
      br[BR_UPDATE_W-1].valid = 1'b1;
      br[BR_UPDATE_W-1].mispredict = 1'b0;
      br[BR_UPDATE_W-1].tag = br_tag_t'(2);
      cycle();
      expect_valid(0, 1'b0, "2 本同時");
      expect_valid(1, 1'b1, "2 本同時");
      expect_valid(2, 1'b0, "2 本同時");
      expect_valid(3, 1'b1, "2 本同時");
      expect_valid(4, 1'b1, "2 本同時");
      expect_brmask(1, '0, "2 本同時");
      expect_brmask(4, bit_of(3), "2 本同時");
      // 2 本とも resolve
      br[0].mispredict = 1'b0;
      cycle();
      expect_brmask(0, '0, "2 本とも resolve");
      expect_brmask(4, bit_of(3), "2 本とも resolve");
      for (int l = 0; l < NL; l++) expect_valid(l, 1'b1, "2 本とも resolve");
    end
    end_test(e0);
  endtask

  task automatic t_flush();
    int e0;
    e0 = errors;
    begin_test("flush");
    for (int l = 0; l < NL; l++) rr[l].valid = 1'b1;
    flush = 1'b1;
    cycle();
    for (int l = 0; l < NL; l++) expect_valid(l, 1'b0, "flush=1");
    flush = 1'b0;
    cycle();
    for (int l = 0; l < NL; l++) expect_valid(l, 1'b1, "flush 解除");
    // rst と flush が同時
    rst = 1'b1;
    flush = 1'b1;
    cycle();
    for (int l = 0; l < NL; l++) expect_valid(l, 1'b0, "rst と flush");
    end_test(e0);
  endtask

  task automatic t_complete();
    int e0;
    e0 = errors;
    begin_test("complete_idx");
    for (int r = 0; r < 64; r++) begin
      clear_inputs();
      for (int w = 0; w < NW; w++) begin
        // rd が NONE（sw や分岐）でも valid なら完了を出す
        wb[w].valid = 1'((r >> w) & 1);
        wb[w].rd = (r % 3 == 0) ? pn() : (wb_file(w, PREG_TYPE_F) >= 0 ? pf(r * 5 + w) : pi(r * 5 + w));
        wb[w].rob_idx = rob_idx_t'(rnd(ROB_SIZE));
        wb[w].value = rword();
      end
      // 同じ PRF の同じ idx に 2 ポートから書かないようにする
      if (wb[1].rd.typ == PREG_TYPE_F) wb[1].rd = pi(r * 5 + 1);
      if (wb[3].rd.typ == PREG_TYPE_F) wb[3].rd = pi(r * 5 + 3);
      if (wb[1].rd.typ != PREG_TYPE_NONE && wb[1].rd.idx == wb[0].rd.idx) wb[1].valid = 1'b0;
      if (wb[3].rd.typ != PREG_TYPE_NONE && (wb[3].rd.idx == wb[0].rd.idx || wb[3].rd.idx == wb[1].rd.idx))
        wb[3].valid = 1'b0;
      if (wb[4].rd.typ != PREG_TYPE_NONE && wb[4].rd.idx == wb[2].rd.idx) wb[4].valid = 1'b0;
      cycle();
    end
    end_test(e0);
  endtask

  // ---------------- ランダム ----------------

  function automatic int hot_idx(int f);
    if (rnd(2) == 0) return rnd(4) % p_size(f);
    return rnd(p_size(f));
  endfunction

  function automatic preg_t rnd_src(int l, int s);
    int r;
    r = rnd(100);
    case (l)
      0: return (r < 85) ? mk_preg(PREG_TYPE_I, hot_idx(RI)) : pn();
      1:
      if (s == 0) return (r < 85) ? mk_preg(PREG_TYPE_I, hot_idx(RI)) : pn();
      else return (r < 40) ? mk_preg(PREG_TYPE_I, hot_idx(RI)) : (r < 80) ? mk_preg(PREG_TYPE_F, hot_idx(RF)) : pn();
      3:
      if (s == 0) return (r < 35) ? mk_preg(PREG_TYPE_I, hot_idx(RI)) : (r < 85) ? mk_preg(PREG_TYPE_F, hot_idx(RF)) : pn();
      else return (r < 85) ? mk_preg(PREG_TYPE_F, hot_idx(RF)) : pn();
      default: return (r < 85) ? mk_preg(PREG_TYPE_F, hot_idx(RF)) : pn();
    endcase
  endfunction

  function automatic preg_t rnd_rd();
    int r;
    r = rnd(3);
    return (r == 0) ? mk_preg(PREG_TYPE_I, rnd(NPREG)) : (r == 1) ? mk_preg(PREG_TYPE_F, rnd(NPREG)) : pn();
  endfunction

  logic used[2][NPREG];

  task automatic gen_random();
    int f;
    int r;
    preg_type_t t;
    preg_t p;

    for (int a = 0; a < 2; a++) for (int i = 0; i < NPREG; i++) used[a][i] = 1'b0;
    rst = rnd(400) == 0;
    flush = rnd(40) == 0;

    for (int w = 0; w < NW; w++) begin
      for (int b = 0; b < $bits(ex_wb_t); b++) wb[w][b] = 1'(rnd(2));
      wb[w].valid = rst ? 1'b0 : (rnd(100) < 60);
      r = rnd(100);
      // 1 割はポートに無い typ か NONE
      if (r < 90) begin
        case (w)
          0: t = PREG_TYPE_I;
          1, 3: t = (rnd(2) == 0) ? PREG_TYPE_I : PREG_TYPE_F;
          default: t = PREG_TYPE_F;
        endcase
      end else begin
        case (w)
          0: t = (rnd(2) == 0) ? PREG_TYPE_F : PREG_TYPE_NONE;
          1, 3: t = PREG_TYPE_NONE;
          default: t = (rnd(2) == 0) ? PREG_TYPE_I : PREG_TYPE_NONE;
        endcase
      end
      f = wb_file(w, t);
      if (f >= 0) begin
        p = mk_preg(t, hot_idx(f));
        if (wb[w].valid) begin
          if (used[f][p.idx]) wb[w].valid = 1'b0;
          else used[f][p.idx] = 1'b1;
        end
      end else begin
        p = mk_preg(t, (t == PREG_TYPE_I) ? rnd(I_PREG_NUM) : (t == PREG_TYPE_F) ? rnd(F_PREG_NUM) : rnd(NPREG));
      end
      wb[w].rd = p;
    end

    for (int l = 0; l < NL; l++) begin
      for (int b = 0; b < $bits(iq_rr_t); b++) rr[l][b] = 1'(rnd(2));
      rr[l].valid = rnd(100) < 80;
      rr[l].rd = rnd_rd();
      rr[l].rs1 = rnd_src(l, 0);
      rr[l].rs2 = rnd_src(l, 1);
      rr[l].brmask = '0;
      for (int b = 0; b < MAX_BR; b++) if (rnd(4) == 0) rr[l].brmask[b] = 1'b1;
    end
    for (int b = 0; b < $bits(int_payload_t); b++) pl_int[b] = 1'(rnd(2));
    for (int b = 0; b < $bits(mem_payload_t); b++) pl_mem[b] = 1'(rnd(2));
    part_mem = 2'(rnd(4));
    for (int p2 = 0; p2 < 3; p2++) for (int b = 0; b < $bits(float_payload_t); b++) pl_fpu[p2][b] = 1'(rnd(2));

    for (int u = 0; u < BR_UPDATE_W; u++) begin
      for (int b = 0; b < $bits(br_update_t); b++) br[u][b] = 1'(rnd(2));
      br[u].valid = rnd(100) < 30;
      br[u].mispredict = rnd(100) < 40;
    end
  endtask

  task automatic random_test(int n);
    int e0;
    int step;
    e0 = errors;
    begin_test("ランダム");
    step = (n >= 20) ? n / 20 : 1;
    for (int i = 0; i < n; i++) begin
      gen_random();
      cycle();
      if ((i + 1) % step == 0)
        say($sformatf("  ランダム %0d / %0d（%0d%%）エラー %0d", i + 1, n, (i + 1) * 100 / n, errors));
    end
    clear_inputs();
    cycle();
    say($sformatf("  内訳: バイパス %0d（うち PRF にも書く %0d、PRF には書かない %0d）", st_byp_hit, st_byp_over_write,
                  st_byp_no_write));
    say($sformatf("        NONE %0d、kill %0d、ビット落とし %0d、F/I 切り替え F %0d I %0d、書かない WB %0d、rst %0d、flush %0d",
                  st_none, st_kill, st_clear, st_fsel, st_isel, st_ignored_wr, st_rst, st_flush));
    if (n >= 10000) begin
      if (st_byp_hit == 0 || st_byp_over_write == 0 || st_byp_no_write == 0 || st_none == 0 || st_kill == 0 ||
          st_clear == 0 || st_fsel == 0 || st_isel == 0 || st_ignored_wr == 0 || st_rst == 0 || st_flush == 0)
        fail("ランダムで一度も起きなかった場合がある（上の内訳を見る）");
    end
    end_test(e0);
  endtask

  initial begin
    int ncycles;
    int seed;
    string logpath;
    ncycles = 200000;
    seed = 1;
    void'($value$plusargs("cycles=%d", ncycles));
    void'($value$plusargs("seed=%d", seed));
    logf = 0;
    if ($value$plusargs("log=%s", logpath)) logf = $fopen(logpath, "a");
    rng_state = 64'h9e3779b97f4a7c15 ^ (64'(seed) << 1);

    errors = 0;
    checks = 0;
    n_tests = 0;
    n_fail = 0;
    cyc = 0;
    cyc_limit = cyc_t'(ncycles) + 100000;
    test_name = "リセット";
    for (int a = 0; a < 2; a++) for (int i = 0; i < NPREG; i++) prf[a][i] = '0;

    say($sformatf("rf_top: I_PREG_NUM=%0d F_PREG_NUM=%0d BR_UPDATE_W=%0d seed=%0d cycles=%0d", I_PREG_NUM, F_PREG_NUM,
                  BR_UPDATE_W, seed, ncycles));

    clear_inputs();
    t_reset();
    t_initial_zero();
    t_write_ports();
    t_read_ports();
    t_same_cycle();
    t_none();
    t_bypass();
    t_all_ports();
    t_branch();
    t_flush();
    t_complete();
    random_test(ncycles);

    say($sformatf("テスト %0d 個中 %0d 個 NG、チェック %0d 回、エラー %0d 個", n_tests, n_fail, checks, errors));
    if (errors != 0) begin
      say("FAIL");
      $fatal(1, "FAIL");
    end
    say("PASS");
    $finish;
  end

endmodule

`default_nettype wire
