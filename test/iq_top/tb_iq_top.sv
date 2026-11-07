`timescale 1ns / 1ps
`default_nettype none

// iq_top のテストベンチ（Verilator の --binary --timing で動かす）
//
// 構成はビルド時に -G で決める（Makefile の CONFIGS を参照）
//
// 実行時オプション
//   +cycles=N  ランダムテストのサイクル数（既定 200000）
//   +seed=N    乱数の種（既定 1）
//   +log=PATH  進捗をこのファイルに追記する（テストの開始・結果、ランダムの進み具合）。1 行ごとに flush
//
// 参照モデルは RTL のカウンタを写さず、busy table も IQ のソースも「何サイクル目から使えるか」を絶対時刻で持つ。
// 毎サイクル次のものを独立に計算して DUT と突き合わせる
//   - disp_full_*（組み合わせ出力）、各 IQ 内部の issued / issued_dest_fu
//   - 内部の wakeup バス dut.all_wakeup（外からの分と、各 IQ の issue 時の分）
//   - 次のサイクルの rr_ff_* / rr_payload_* / rr_issue_part_mem
//
// テストの前提にしている仕様
//   - IQ は INT（FU 1 個、ポート 1）、MEM（FU 1 個、slow wakeup）、FP（SHORT→port0, LONG→port1, DIV/SQRT→port2、
//     DIV と SQRT は slow wakeup かつ blocking、fdiv_blocked は DIV、fsqrt_blocked は SQRT を止める）
//   - FU はテストの中では TF_*（INT / MEM は 0）で持ち、put で uop の dest_eu / dest_fu に直す
//     （ALU=0, MEM=1, F短=2, F長=3, F超長=4。F超長の中は fsqrt=0, fdiv=1）
//   - MEM は rs1 側（STA / LDA）と rs2 側（STD）を別々に出す。put で rd が NONE かつ rs2 がレジスタなら store
//     （op.eff=EFF_MEM、出す側 2'b11）、そうでなければ load（op.eff は MEM 以外、出す側 2'b01）にする
//   - wakeup バスは [0, WAKEUP_W) が外から、WAKEUP_W が INT、+1 が MEM、+2〜+4 が FP の port0〜2
//   - busy table
//       rst / flush で全部 ready（そのサイクルの dispatch の rd も無視）
//       dispatch の valid が立った uop の rd（NONE 以外）は結果待ちになる（同じサイクルの wakeup より優先）
//       結果待ちのレジスタにサイクル t に latency=L の wakeup が来たら t+1+L から使える。結果待ちでなければ無視
//   - dispatch のサイクル d に読んだソースは
//       NONE なら d+1 から使える
//       同じサイクルに dispatch される uop（どの IQ でも）の rd と同じなら結果待ち
//       busy table で結果待ちなら結果待ち（同じサイクルの wakeup は当たる）
//       そうでなければ max(使える時刻, d+1) から使える
//   - IQ の中の振る舞いは iq_core のテスト（test/iq_core）と同じ
//   - テストは disp_full_* が立っている IQ には dispatch しない

module tb_iq_top
  import types::*;
  import ooo_types::*;
  import isa::*;
  import uop_types::*;
  import back_types::*;
  import iq_types::*;
#(
  parameter int SIZE_INT = 16,
  parameter int SIZE_MEM = 16,
  parameter int SIZE_FPU = 16,
  parameter int DW_INT = 1,
  parameter int DW_MEM = 1,
  parameter int DW_FPU = 1,
  parameter int WAKEUP_W = 2,
  parameter int BR_UPDATE_W = 1
);

  localparam int NQ = 3;
  localparam int QI = 0;
  localparam int QM = 1;
  localparam int QF = 2;
  localparam int MAXS = (SIZE_INT > SIZE_MEM) ? ((SIZE_INT > SIZE_FPU) ? SIZE_INT : SIZE_FPU)
                                              : ((SIZE_MEM > SIZE_FPU) ? SIZE_MEM : SIZE_FPU);
  localparam int MAXDW = (DW_INT > DW_MEM) ? ((DW_INT > DW_FPU) ? DW_INT : DW_FPU) : ((DW_MEM > DW_FPU) ? DW_MEM : DW_FPU);
  localparam int MAXP = 3;
  localparam int MAXF = 4;
  localparam int NPREG = NUM_PREG_I;
  localparam int BUS_W = WAKEUP_W + 5;
  localparam int ISSUE_TO_FU = 2;
  localparam int MAX_ERRORS = 30;

  typedef logic [63:0] cyc_t;

  // テストの中の FP の FU 番号
  localparam int TF_SHORT = 0;
  localparam int TF_LONG = 1;
  localparam int TF_DIV = 2;
  localparam int TF_SQRT = 3;

  function automatic dest_eu_t eu_of(int q, int f);
    if (q == QI) return EU_ALU;
    if (q == QM) return EU_MEM;
    return (f == TF_SHORT) ? EU_F_SHORT : (f == TF_LONG) ? EU_F_LONG : EU_F_VERY_LONG;
  endfunction

  function automatic dest_fu_t lfu_of(int q, int f);
    if (q == QF && f == TF_DIV) return FU_FDIV;
    if (q == QF && f == TF_SQRT) return FU_FSQRT;
    return '0;
  endfunction

  // uop の dest_eu / dest_fu からテストの中の FU 番号に戻す
  function automatic int gfu(int q, disp_uop_t u);
    if (q != QF) return 0;
    if (u.dest_eu == EU_F_SHORT) return TF_SHORT;
    if (u.dest_eu == EU_F_LONG) return TF_LONG;
    return (u.dest_fu == FU_FDIV) ? TF_DIV : TF_SQRT;
  endfunction

  function automatic int q_size(int q);
    return (q == QI) ? SIZE_INT : (q == QM) ? SIZE_MEM : SIZE_FPU;
  endfunction

  function automatic int q_dw(int q);
    return (q == QI) ? DW_INT : (q == QM) ? DW_MEM : DW_FPU;
  endfunction

  function automatic int q_ports(int q);
    return (q == QF) ? 3 : 1;
  endfunction

  function automatic int fu_port(int q, int f);
    if (q != QF) return 0;
    return (f < 2) ? f : 2;
  endfunction

  function automatic logic fu_slow(int q, int f);
    return q == QM || (q == QF && f >= 2);
  endfunction

  function automatic logic fu_blk(int q, int f);
    return q == QF && f >= 2;
  endfunction

  function automatic int bus_idx(int q, int p);
    return WAKEUP_W + ((q == QI) ? 0 : (q == QM) ? 1 : 2 + p);
  endfunction

  function automatic string q_name(int q);
    return (q == QI) ? "INT" : (q == QM) ? "MEM" : "FP";
  endfunction

  logic clk = 1'b0;
  always #5 clk = ~clk;

  // テストが書く入力
  logic rst;
  logic flush;
  logic tvalid[NQ][MAXDW];
  disp_uop_t tuop[NQ][MAXDW];
  wakeup_t ext_w[WAKEUP_W];
  // テストでは分岐の結果を1本ずつ持ち、DUTにはmaskにして渡す
  typedef struct packed {
    logic    valid;
    logic    mispredict;
    br_tag_t tag;
  } tb_br_t;

  function automatic br_update_t to_br_update(input tb_br_t b[BR_UPDATE_W]);
    br_update_t u = '0;
    for (int k = 0; k < BR_UPDATE_W; k++) begin
      if (b[k].valid && b[k].mispredict) u.kill_mask[b[k].tag] = 1'b1;
      if (b[k].valid && !b[k].mispredict) u.resolve_mask[b[k].tag] = 1'b1;
    end
    return u;
  endfunction

  tb_br_t br[BR_UPDATE_W];
  logic fdiv_b;
  logic fsqrt_b;

  // DUT につなぐ側。initial の中から直接書くと Verilator 5.020 の --timing で
  // DUT の組み合わせ回路が評価し直されないことがあるので、立ち下がりで写す
  logic d_rst;
  logic d_flush;
  logic d_tvalid[NQ][MAXDW];
  disp_uop_t d_tuop[NQ][MAXDW];
  wakeup_t d_ext_w[WAKEUP_W];
  br_update_t d_br;
  logic d_fdiv_b;
  logic d_fsqrt_b;

  always @(negedge clk) begin
    d_rst <= rst;
    d_flush <= flush;
    d_tvalid <= tvalid;
    d_tuop <= tuop;
    d_ext_w <= ext_w;
    d_br <= to_br_update(br);
    d_fdiv_b <= fdiv_b;
    d_fsqrt_b <= fsqrt_b;
  end

  logic dv_int[DW_INT];
  disp_uop_t du_int[DW_INT];
  logic dv_mem[DW_MEM];
  disp_uop_t du_mem[DW_MEM];
  logic dv_fpu[DW_FPU];
  disp_uop_t du_fpu[DW_FPU];

  always_comb begin
    for (int i = 0; i < DW_INT; i++) begin
      dv_int[i] = d_tvalid[QI][i];
      du_int[i] = d_tuop[QI][i];
    end
    for (int i = 0; i < DW_MEM; i++) begin
      dv_mem[i] = d_tvalid[QM][i];
      du_mem[i] = d_tuop[QM][i];
    end
    for (int i = 0; i < DW_FPU; i++) begin
      dv_fpu[i] = d_tvalid[QF][i];
      du_fpu[i] = d_tuop[QF][i];
    end
  end

  logic full_int, full_mem, full_fpu;
  iq_rr_t rr_int[1];
  iq_rr_t rr_mem[1];
  iq_rr_t rr_fpu[3];
  int_payload_t pl_int[1];
  mem_payload_t pl_mem[1];
  logic [1:0] part_mem[1];
  float_payload_t pl_fpu[3];

  iq_top #(
    .I_PREG_NUM(NUM_PREG_I),
    .F_PREG_NUM(NUM_PREG_F),
    .SIZE_INT(SIZE_INT),
    .SIZE_MEM(SIZE_MEM),
    .SIZE_FPU(SIZE_FPU),
    .DISPATCH_W_INT(DW_INT),
    .DISPATCH_W_MEM(DW_MEM),
    .DISPATCH_W_FPU(DW_FPU),
    .WAKEUP_W(WAKEUP_W)
  ) dut (
    .clk(clk),
    .rst(d_rst),
    .flush(d_flush),
    .disp_valid_int(dv_int),
    .disp_uop_int(du_int),
    .disp_full_int(full_int),
    .disp_valid_mem(dv_mem),
    .disp_uop_mem(du_mem),
    .disp_full_mem(full_mem),
    .disp_valid_fpu(dv_fpu),
    .disp_uop_fpu(du_fpu),
    .disp_full_fpu(full_fpu),
    .coming_wakeup(d_ext_w),
    .br_update(d_br),
    .fdiv_blocked(d_fdiv_b),
    .fsqrt_blocked(d_fsqrt_b),
    .rr_ff_int(rr_int),
    .rr_payload_int(pl_int),
    .rr_ff_mem(rr_mem),
    .rr_payload_mem(pl_mem),
    .rr_issue_part_mem(part_mem),
    .rr_ff_fpu(rr_fpu),
    .rr_payload_fpu(pl_fpu)
  );

  function automatic logic o_full(int q);
    return (q == QI) ? full_int : (q == QM) ? full_mem : full_fpu;
  endfunction

  function automatic logic o_issued(int q, int p);
    return (q == QI) ? dut.u_iq_int.u_iq_core_int.issued[0] :
           (q == QM) ? dut.u_iq_mem.u_iq_core_mem.issued[0] : dut.u_iq_float.u_iq_core_float.issued[p];
  endfunction

  function automatic dest_fu_t o_fu(int q, int p);
    return (q == QI) ? dut.u_iq_int.u_iq_core_int.issued_dest_fu[0] :
           (q == QM) ? dut.u_iq_mem.u_iq_core_mem.issued_dest_fu[0] : dut.u_iq_float.u_iq_core_float.issued_dest_fu[p];
  endfunction

  function automatic iq_rr_t o_rr(int q, int p);
    return (q == QI) ? rr_int[0] : (q == QM) ? rr_mem[0] : rr_fpu[p];
  endfunction

  // ---------------- 乱数（xorshift64） ----------------

  logic [63:0] rng_state;

  function automatic int rnd(int n);
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return int'(rng_state % 64'(n));
  endfunction

  // ---------------- 値を作る補助 ----------------

  function automatic preg_t mk_preg(preg_type_t t, int i);
    preg_t p;
    p.typ = t;
    p.idx = preg_idx_t'(i);
    return p;
  endfunction

  function automatic preg_t pi(int i);
    return mk_preg(PREG_TYPE_I, i);
  endfunction

  function automatic preg_t pf(int i);
    return mk_preg(PREG_TYPE_F, i);
  endfunction

  function automatic preg_t pn();
    return mk_preg(PREG_TYPE_NONE, 0);
  endfunction

  function automatic logic is_reg(preg_t p);
    return p.typ == PREG_TYPE_I || p.typ == PREG_TYPE_F;
  endfunction

  function automatic int ti(preg_t p);
    return (p.typ == PREG_TYPE_I) ? 0 : 1;
  endfunction

  function automatic brmask_t bit_of(int b);
    brmask_t m = '0;
    m[b] = 1'b1;
    return m;
  endfunction

  // 使わないフィールドは乱数で埋める。imm に id を入れて見分ける
  function automatic disp_uop_t mk_uop(int fu, preg_t rd, preg_t rs1, preg_t rs2, int lat, brmask_t bm, int id);
    disp_uop_t u;
    for (int b = 0; b < $bits(disp_uop_t); b++) u[b] = 1'(rnd(2));
    u.rd = rd;
    u.rs1 = rs1;
    u.rs2 = rs2;
    u.lat = latency_t'(lat);
    u.dest_fu = dest_fu_t'(fu);
    u.brmask = bm;
    u.imm = imm_raw_t'(id);
    return u;
  endfunction

  // ---------------- 参照モデル ----------------

  typedef struct packed {
    logic valid;
    logic [31:0] id;
    cyc_t seq;  // 小さいほど古い
    disp_uop_t u;
    logic w1;  // wakeup 済みか
    logic w2;
    cyc_t r1;  // このサイクルから使える
    cyc_t r2;
    brmask_t bm;
    logic [1:0] pend;  // MEM でまだ出していない側（[0]: rs1 側、[1]: rs2 側）。他の IQ は 2'b11 のまま
  } ment_t;

  ment_t m[NQ][MAXS];
  // 詰まったときの調査用：uop ごとの行き先と、レジスタを最後に結果待ちにした uop
  string fate[int];
  int mark_id[2][NPREG];
  cyc_t mark_cyc[2][NPREG];
  cyc_t next_seq;
  logic memo_v[NQ][MAXF];
  cyc_t memo_at[NQ][MAXF];

  // busy table（[0] が I、[1] が F）
  logic tbl_pend[2][NPREG];
  cyc_t tbl_rat[2][NPREG];

  cyc_t cyc;
  cyc_t cyc_limit;
  logic checking;
  int exp_idx[NQ][MAXP];
  logic [1:0] exp_part[NQ][MAXP];
  logic exp_rr_v[NQ][MAXP];
  ment_t exp_rr[NQ][MAXP];
  logic [1:0] exp_rr_part[NQ][MAXP];
  cyc_t issued_at[int];

  // このサイクルの wakeup バス
  logic cwv[BUS_W];
  preg_t cwp[BUS_W];
  latency_t cwl[BUS_W];

  int errors;
  longint checks;
  string test_name;
  int n_tests;
  int n_fail;

  // カバレッジ用の数
  localparam int K_NONE = 0;
  localparam int K_BYP_SAME = 1;  // 同じ IQ の別レーンの rd
  localparam int K_BYP_CROSS = 2;  // 別の IQ の rd
  localparam int K_PEND = 3;
  localparam int K_CNT1 = 4;  // busy table が数えている途中（あと 1〜3）
  localparam int K_CNT2 = 5;
  localparam int K_CNT3 = 6;
  localparam int K_READY = 7;
  localparam int NK = 8;

  longint st_kind[NK];
  longint st_issue[NQ][MAXP];
  longint st_kill[NQ];
  longint st_drop_kill[NQ];
  longint st_drop_full;
  longint st_full[NQ];
  longint st_disp_wake;
  longint st_rewake;
  longint st_tbl_wake;
  longint st_tbl_ignore;
  longint st_mark_counting;
  longint st_mark_wake;
  longint st_in_block[NQ];
  longint st_memo_block[NQ];
  longint st_flush;
  longint st_rst;
  longint st_resolve;
  longint st_pend_kill;
  longint st_mem_partial;  // MEM で片側だけ出した
  longint st_mem_both;  // MEM の store を 1 回で出した

  int logf;

  // 画面と進捗ログの両方に出す
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

  function automatic logic killed_by(brmask_t bm);
    for (int k = 0; k < BR_UPDATE_W; k++) if (br[k].valid && br[k].mispredict && bm[br[k].tag]) return 1'b1;
    return 1'b0;
  endfunction

  function automatic brmask_t resolve_mask(brmask_t bm);
    brmask_t r = bm;
    for (int k = 0; k < BR_UPDATE_W; k++) if (br[k].valid && !br[k].mispredict) r[br[k].tag] = 1'b0;
    return r;
  endfunction

  function automatic logic memo_blocked(int q, int f);
    return memo_v[q][f] && (cyc - memo_at[q][f] <= cyc_t'(ISSUE_TO_FU));
  endfunction

  function automatic logic in_blocked(int q, int f);
    return q == QF && ((f == 2 && fdiv_b) || (f == 3 && fsqrt_b));
  endfunction

  function automatic int occ(int q);
    int n = 0;
    for (int k = 0; k < q_size(q); k++) if (m[q][k].valid) n++;
    return n;
  endfunction

  function automatic logic model_full(int q);
    return (q_size(q) - occ(q)) < q_dw(q);
  endfunction

  // このサイクルに出せる側。MEM は出していない側ごと、他は両方 ready なら 2'b11
  function automatic logic [1:0] ready_part(int q, ment_t e);
    logic r1, r2;
    r1 = e.w1 && cyc >= e.r1;
    r2 = e.w2 && cyc >= e.r2;
    if (q == QM) return {e.pend[1] && r2, e.pend[0] && r1};
    return (r1 && r2) ? 2'b11 : 2'b00;
  endfunction

  // サイクル頭の状態と入力から、このサイクルに各ポートが出すエントリを決める
  task automatic compute_expect();
    ment_t e;
    int f;
    for (int q = 0; q < NQ; q++) begin
      for (int p = 0; p < MAXP; p++) begin
        exp_idx[q][p] = -1;
        exp_part[q][p] = 2'b00;
        if (p >= q_ports(q) || rst || flush) continue;
        for (int k = 0; k < q_size(q); k++) begin
          e = m[q][k];
          if (!e.valid || killed_by(e.bm)) continue;
          f = gfu(q, e.u);
          if (fu_port(q, f) != p) continue;
          if (ready_part(q, e) == 2'b00) continue;
          if (in_blocked(q, f)) begin
            st_in_block[q]++;
            continue;
          end
          if (memo_blocked(q, f)) begin
            st_memo_block[q]++;
            continue;
          end
          if (exp_idx[q][p] < 0 || e.seq < m[q][exp_idx[q][p]].seq) exp_idx[q][p] = k;
        end
        if (exp_idx[q][p] >= 0) exp_part[q][p] = ready_part(q, m[q][exp_idx[q][p]]);
      end
    end
  endtask

  task automatic check_comb();
    ment_t e;
    logic xv;
    logic xf;
    wakeup_t bw;
    if (!checking) return;
    for (int q = 0; q < NQ; q++) begin
      xf = model_full(q);
      if (xf) st_full[q]++;
      checks++;
      if (o_full(q) !== xf)
        fail($sformatf("disp_full_%s=%0b 期待=%0b（中身 %0d/%0d）", q_name(q), o_full(q), xf, occ(q), q_size(q)));
      for (int p = 0; p < q_ports(q); p++) begin
        checks++;
        bw = dut.all_wakeup[bus_idx(q, p)];
        if (exp_idx[q][p] < 0) begin
          if (o_issued(q, p) !== 1'b0) fail($sformatf("%s port%0d が issue した（期待は issue なし）", q_name(q), p));
          else if (bw.valid !== 1'b0) fail($sformatf("%s port%0d が issue していないのに wakeup を出した", q_name(q), p));
          continue;
        end
        e = m[q][exp_idx[q][p]];
        if (o_issued(q, p) !== 1'b1) begin
          fail($sformatf("%s port%0d が issue しない（期待は id %0d）", q_name(q), p, e.id));
          continue;
        end
        if (o_fu(q, p) !== e.u.dest_fu)
          fail($sformatf("%s port%0d issued_dest_fu=%0d 期待=%0d", q_name(q), p, o_fu(q, p), e.u.dest_fu));
        xv = !fu_slow(q, gfu(q, e.u)) && e.u.rd.typ != PREG_TYPE_NONE;
        if (bw.valid !== xv)
          fail($sformatf("%s port%0d の wakeup（バス %0d）valid=%0b 期待=%0b（id %0d）", q_name(q), p, bus_idx(q, p),
                         bw.valid, xv, e.id));
        else if (xv && (bw.preg !== e.u.rd || bw.latency !== e.u.lat))
          fail($sformatf("%s port%0d の wakeup preg=%h lat=%0d 期待 preg=%h lat=%0d", q_name(q), p, bw.preg, bw.latency,
                         e.u.rd, e.u.lat));
      end
    end
    for (int k = 0; k < WAKEUP_W; k++) begin
      checks++;
      if (dut.all_wakeup[k] !== d_ext_w[k]) fail($sformatf("wakeup バス %0d が coming_wakeup[%0d] と違う", k, k));
    end
  endtask

  // エントリ m[q][e] のソースに wakeup を当てる（まだ起きていないものだけ、複数当たったら後のもの）。当たった数を返す
  // 2 次元配列の要素のメンバを inout で渡すと 5.020 では正しく書き戻されないので、番号で受け取る
  function automatic int wake(int q, int e);
    logic w1;
    logic w2;
    int hits;
    w1   = m[q][e].w1;
    w2   = m[q][e].w2;
    hits = 0;
    for (int k = 0; k < BUS_W; k++) begin
      if (!cwv[k]) continue;
      if (cwp[k] == m[q][e].u.rs1) begin
        if (w1) begin
          st_rewake++;
        end else begin
          m[q][e].w1 = 1'b1;
          m[q][e].r1 = cyc + 1 + cyc_t'(cwl[k]);
          hits++;
        end
      end
      if (cwp[k] == m[q][e].u.rs2) begin
        if (w2) begin
          st_rewake++;
        end else begin
          m[q][e].w2 = 1'b1;
          m[q][e].r2 = cyc + 1 + cyc_t'(cwl[k]);
          hits++;
        end
      end
    end
    return hits;
  endfunction

  // dispatch するソースの最初の状態（busy table はこのサイクルの更新前）
  // output 引数のある関数を途中で return すると、5.020 では書き戻されないことがあるので task にしてモジュールの変数に返す
  int si_kind;
  logic si_w;
  cyc_t si_r;

  task automatic src_init(input int q, input preg_t s);
    int byp;
    si_w = 1'b1;
    si_r = cyc + 1;
    si_kind = K_NONE;
    byp = -1;
    if (is_reg(s)) begin
      for (int q2 = 0; q2 < NQ; q2++)
        for (int l = 0; l < q_dw(q2); l++) if (byp < 0 && tvalid[q2][l] && tuop[q2][l].rd == s) byp = q2;
      if (byp >= 0) begin
        si_w = 1'b0;
        si_kind = (byp == q) ? K_BYP_SAME : K_BYP_CROSS;
      end else if (tbl_pend[ti(s)][s.idx]) begin
        si_w = 1'b0;
        si_kind = K_PEND;
      end else if (tbl_rat[ti(s)][s.idx] > cyc) begin
        si_r = tbl_rat[ti(s)][s.idx];
        si_kind = K_CNT1 + int'(si_r - cyc) - 1;
        if (si_kind > K_CNT3) si_kind = K_CNT3;
      end else begin
        si_kind = K_READY;
      end
    end
  endtask

  // クロックの後でモデルを 1 サイクル進める
  task automatic model_advance();
    int free_slots[NQ];
    int idx;
    int j;
    int f;
    int hit;
    logic pend_pre[2][NPREG];
    cyc_t rat_pre[2][NPREG];
    disp_uop_t u;
    preg_t p;

    for (int k = 0; k < BUS_W; k++) begin
      cwv[k] = 1'b0;
      cwp[k] = '0;
      cwl[k] = '0;
    end
    for (int k = 0; k < WAKEUP_W; k++) begin
      cwv[k] = ext_w[k].valid;
      cwp[k] = ext_w[k].preg;
      cwl[k] = ext_w[k].latency;
    end
    for (int q = 0; q < NQ; q++) begin
      for (int pp = 0; pp < MAXP; pp++) begin
        idx = exp_idx[q][pp];
        exp_rr_v[q][pp] = idx >= 0;
        exp_rr[q][pp] = '0;
        exp_rr_part[q][pp] = exp_part[q][pp];
        if (idx < 0) continue;
        exp_rr[q][pp] = m[q][idx];
        exp_rr[q][pp].bm = resolve_mask(m[q][idx].bm);
        f = gfu(q, m[q][idx].u);
        if (!fu_slow(q, f) && m[q][idx].u.rd.typ != PREG_TYPE_NONE) begin
          cwv[bus_idx(q, pp)] = 1'b1;
          cwp[bus_idx(q, pp)] = m[q][idx].u.rd;
          cwl[bus_idx(q, pp)] = m[q][idx].u.lat;
        end
      end
    end

    if (rst || flush) begin
      for (int q = 0; q < NQ; q++) begin
        for (int k = 0; k < MAXS; k++) m[q][k].valid = 1'b0;
        for (int ff = 0; ff < MAXF; ff++) memo_v[q][ff] = 1'b0;
        for (int pp = 0; pp < MAXP; pp++) exp_rr_v[q][pp] = 1'b0;
      end
      for (int t = 0; t < 2; t++) begin
        for (int i = 0; i < NPREG; i++) begin
          tbl_pend[t][i] = 1'b0;
          tbl_rat[t][i] = '0;
        end
      end
      if (rst) st_rst++;
      else st_flush++;
      return;
    end
    for (int k = 0; k < BR_UPDATE_W; k++) if (br[k].valid && !br[k].mispredict) st_resolve++;

    for (int q = 0; q < NQ; q++) free_slots[q] = q_size(q) - occ(q);

    // issue したものが抜ける
    for (int q = 0; q < NQ; q++) begin
      for (int pp = 0; pp < q_ports(q); pp++) begin
        idx = exp_idx[q][pp];
        if (idx < 0) continue;
        issued_at[int'(m[q][idx].id)] = cyc;
        fate[int'(m[q][idx].id)] = $sformatf("issue %0d", cyc);
        st_issue[q][pp]++;
        f = gfu(q, m[q][idx].u);
        if (fu_blk(q, f)) begin
          memo_v[q][f]  = 1'b1;
          memo_at[q][f] = cyc;
        end
        if (q == QM) begin
          if (exp_part[q][pp] == 2'b11) st_mem_both++;
          else if (m[q][idx].pend == 2'b11) st_mem_partial++;
          m[q][idx].pend &= ~exp_part[q][pp];
          if (m[q][idx].pend == 2'b00) m[q][idx].valid = 1'b0;
        end else begin
          m[q][idx].valid = 1'b0;
        end
      end
    end

    // mispredict で消える
    for (int q = 0; q < NQ; q++) begin
      for (int k = 0; k < q_size(q); k++) begin
        if (m[q][k].valid && killed_by(m[q][k].bm)) begin
          m[q][k].valid = 1'b0;
          fate[int'(m[q][k].id)] = $sformatf("IQ で kill %0d", cyc);
          st_kill[q]++;
        end
      end
    end

    // 残ったものに分岐の解決と wakeup を当てる
    for (int q = 0; q < NQ; q++) begin
      for (int k = 0; k < q_size(q); k++) begin
        if (!m[q][k].valid) continue;
        m[q][k].bm = resolve_mask(m[q][k].bm);
        hit = wake(q, k);
      end
    end

    // dispatch
    for (int q = 0; q < NQ; q++) begin
      for (int l = 0; l < q_dw(q); l++) begin
        if (!tvalid[q][l]) continue;
        u = tuop[q][l];
        if (l >= free_slots[q]) begin
          fate[int'(u.imm)] = "満杯で落ちた";
          st_drop_full++;
          continue;
        end
        if (killed_by(u.brmask)) begin
          fate[int'(u.imm)] = $sformatf("dispatch で kill %0d", cyc);
          st_drop_kill[q]++;
          continue;
        end
        j = -1;
        for (int k = 0; k < q_size(q); k++) begin
          if (!m[q][k].valid) begin
            j = k;
            break;
          end
        end
        if (j < 0) begin
          fail("モデルの空きが無い（テストの誤り）");
          continue;
        end
        m[q][j].valid = 1'b1;
        m[q][j].id = 32'(u.imm);
        fate[int'(u.imm)] = $sformatf("IQ に入った %0d", cyc);
        m[q][j].seq = next_seq++;
        m[q][j].u = u;
        m[q][j].bm = resolve_mask(u.brmask);
        m[q][j].pend = (q != QM) ? 2'b11 : (u.op.eff == EFF_MEM) ? 2'b11 : 2'b01;
        src_init(q, u.rs1);
        m[q][j].w1 = si_w;
        m[q][j].r1 = si_r;
        st_kind[si_kind]++;
        src_init(q, u.rs2);
        m[q][j].w2 = si_w;
        m[q][j].r2 = si_r;
        st_kind[si_kind]++;
        st_disp_wake += wake(q, j);
      end
    end

    // busy table。wakeup は結果待ちのものだけに当たり、その後 dispatch の rd で上書きする
    pend_pre = tbl_pend;
    rat_pre  = tbl_rat;
    for (int k = 0; k < BUS_W; k++) begin
      if (!cwv[k] || !is_reg(cwp[k])) continue;
      p = cwp[k];
      if (pend_pre[ti(p)][p.idx]) begin
        tbl_pend[ti(p)][p.idx] = 1'b0;
        tbl_rat[ti(p)][p.idx]  = cyc + 1 + cyc_t'(cwl[k]);
        st_tbl_wake++;
      end else begin
        st_tbl_ignore++;
      end
    end
    for (int q = 0; q < NQ; q++) begin
      for (int l = 0; l < q_dw(q); l++) begin
        if (!tvalid[q][l] || !is_reg(tuop[q][l].rd)) continue;
        p = tuop[q][l].rd;
        if (!pend_pre[ti(p)][p.idx] && rat_pre[ti(p)][p.idx] > cyc + 1) st_mark_counting++;
        if (pend_pre[ti(p)][p.idx] && !tbl_pend[ti(p)][p.idx]) st_mark_wake++;
        tbl_pend[ti(p)][p.idx] = 1'b1;
        mark_id[ti(p)][p.idx] = int'(tuop[q][l].imm);
        mark_cyc[ti(p)][p.idx] = cyc;
      end
    end
  endtask

  task automatic check_payload(int q, int p, ment_t e);
    disp_uop_t u = e.u;
    case (q)
      QI:
      if (pl_int[0] !== int_payload_t'{op: u.op, imm: u.imm, pc: u.pc, predict_pc: u.predict_pc, ftq_idx: u.ftq_idx,
                                       rob_idx: u.rob_idx, br_tag: u.br_tag})
        fail($sformatf("INT rr_payload=%h 期待 op=%h imm=%h pc=%h predict_pc=%h ftq=%h rob=%h br_tag=%h（id %0d）",
                       pl_int[0], u.op, u.imm, u.pc, u.predict_pc, u.ftq_idx, u.rob_idx, u.br_tag, e.id));
      QM:
      if (pl_mem[0] !== mem_payload_t'{op: u.op, imm: u.imm, rob_idx: u.rob_idx, ldq_idx: u.ldq_idx, stq_idx: u.stq_idx})
        fail($sformatf("MEM rr_payload=%h 期待 op=%h imm=%h rob=%h ldq=%h stq=%h（id %0d）", pl_mem[0], u.op, u.imm,
                       u.rob_idx, u.ldq_idx, u.stq_idx, e.id));
      default:
      if (pl_fpu[p] !== float_payload_t'{op: u.op, imm: u.imm, pc: u.pc, predict_pc: u.predict_pc, ftq_idx: u.ftq_idx,
                                         rob_idx: u.rob_idx, br_tag: u.br_tag})
        fail($sformatf("FP port%0d rr_payload=%h 期待 op=%h imm=%h pc=%h predict_pc=%h ftq=%h rob=%h br_tag=%h（id %0d）",
                       p, pl_fpu[p], u.op, u.imm, u.pc, u.predict_pc, u.ftq_idx, u.rob_idx, u.br_tag, e.id));
    endcase
  endtask

  task automatic check_rr();
    iq_rr_t r;
    ment_t e;
    if (!checking) return;
    for (int q = 0; q < NQ; q++) begin
      for (int p = 0; p < q_ports(q); p++) begin
        checks++;
        r = o_rr(q, p);
        if (r.valid !== exp_rr_v[q][p]) begin
          fail($sformatf("%s port%0d rr_ff.valid=%0b 期待=%0b", q_name(q), p, r.valid, exp_rr_v[q][p]));
          continue;
        end
        if (!exp_rr_v[q][p]) continue;
        e = exp_rr[q][p];
        if (r.rd !== e.u.rd || r.rs1 !== e.u.rs1 || r.rs2 !== e.u.rs2)
          fail($sformatf("%s port%0d rr_ff rd=%h rs1=%h rs2=%h 期待 rd=%h rs1=%h rs2=%h（id %0d）", q_name(q), p, r.rd,
                         r.rs1, r.rs2, e.u.rd, e.u.rs1, e.u.rs2, e.id));
        if (r.dest_fu !== e.u.dest_fu)
          fail($sformatf("%s port%0d rr_ff.dest_fu=%0d 期待=%0d（id %0d）", q_name(q), p, r.dest_fu, e.u.dest_fu, e.id));
        if (r.brmask !== e.bm)
          fail($sformatf("%s port%0d rr_ff.brmask=%b 期待=%b（id %0d）", q_name(q), p, r.brmask, e.bm, e.id));
        if (q == QM && part_mem[0] !== exp_rr_part[q][p])
          fail($sformatf("MEM rr_issue_part=%b 期待=%b（id %0d）", part_mem[0], exp_rr_part[q][p], e.id));
        check_payload(q, p, e);
      end
    end
  endtask

  // 入力をセットしてから呼ぶ。1 サイクル進めて全部チェックする
  task automatic cycle();
    @(negedge clk);
    #2;
    compute_expect();
    check_comb();
    @(posedge clk);
    #1;
    model_advance();
    check_rr();
    cyc++;
    if (cyc > cyc_limit) begin
      say($sformatf("[NG] %s: cycle %0d を超えても終わらない（ハング）", test_name, cyc_limit));
      $fatal(1, "FAIL");
    end
  endtask

  // ---------------- 入力を作る補助 ----------------

  int next_id;

  function automatic int nid();
    return next_id++;
  endfunction

  task automatic clear_inputs();
    rst = 1'b0;
    flush = 1'b0;
    for (int q = 0; q < NQ; q++) begin
      for (int l = 0; l < MAXDW; l++) begin
        tvalid[q][l] = 1'b0;
        tuop[q][l] = '0;
      end
    end
    for (int k = 0; k < WAKEUP_W; k++) ext_w[k] = '0;
    for (int k = 0; k < BR_UPDATE_W; k++) br[k] = '0;
    fdiv_b  = 1'b0;
    fsqrt_b = 1'b0;
  endtask

  task automatic put(int q, int lane, disp_uop_t u);
    int f;
    if (lane >= q_dw(q)) begin
      fail($sformatf("%s のレーン %0d は無い（テストの誤り）", q_name(q), lane));
      return;
    end
    // mk_uop はテストの中の FU 番号を dest_fu に入れているので直す
    f = int'(u.dest_fu);
    u.dest_eu = eu_of(q, f);
    u.dest_fu = lfu_of(q, f);
    if (q == QM) begin
      if (u.rd.typ == PREG_TYPE_NONE && is_reg(u.rs2)) u.op.eff = EFF_MEM;
      else if (u.op.eff == EFF_MEM) u.op.eff = EFF_WI;
    end
    tvalid[q][lane] = 1'b1;
    tuop[q][lane] = u;
  endtask

  task automatic ext(int lane, preg_t p, int lat);
    ext_w[lane].valid = 1'b1;
    ext_w[lane].preg = p;
    ext_w[lane].latency = latency_t'(lat);
  endtask

  task automatic mispredict(int lane, int tag);
    br[lane].valid = 1'b1;
    br[lane].mispredict = 1'b1;
    br[lane].tag = br_tag_t'(tag);
  endtask

  task automatic resolve(int lane, int tag);
    br[lane].valid = 1'b1;
    br[lane].mispredict = 1'b0;
    br[lane].tag = br_tag_t'(tag);
  endtask

  task automatic run_idle(int n);
    repeat (n) begin
      clear_inputs();
      cycle();
    end
  endtask

  // flush して busy table と IQ を空にする
  task automatic quiet();
    clear_inputs();
    flush = 1'b1;
    cycle();
    run_idle(1);
  endtask

  task automatic expect_at(int id, cyc_t c);
    checks++;
    if (!issued_at.exists(id)) fail($sformatf("id %0d が issue されていない（期待 cycle %0d）", id, c));
    else if (issued_at[id] != c) fail($sformatf("id %0d の issue が cycle %0d（期待 %0d）", id, issued_at[id], c));
  endtask

  task automatic expect_never(int id);
    checks++;
    if (issued_at.exists(id))
      fail($sformatf("id %0d は issue されないはずが cycle %0d に issue された", id, issued_at[id]));
  endtask

  task automatic expect_true(logic c, string msg);
    checks++;
    if (!c) fail(msg);
  endtask

  // ---------------- 決め打ちのテスト ----------------

  int err_base;

  task automatic begin_test(string name);
    test_name = "（前処理）";
    quiet();
    run_idle(2);
    test_name = name;
    err_base  = errors;
    if (logf != 0) begin
      $fdisplay(logf, "開始 (cycle %0d): %s", cyc, name);
      $fflush(logf);
    end
  endtask

  task automatic end_test();
    n_tests++;
    if (errors == err_base) begin
      say($sformatf("[OK] %s", test_name));
    end else begin
      say($sformatf("[NG] %s", test_name));
      n_fail++;
    end
  endtask

  task automatic t_reset();
    int a, b, c;
    cyc_t t0;
    // rst の直後（flush を挟まない）
    test_name = "rst の直後は全部の物理レジスタが ready";
    err_base = errors;
    a = nid();
    b = nid();
    c = nid();
    t0 = cyc;
    clear_inputs();
    put(QI, 0, mk_uop(0, pi(1), pi(63), pi(0), 0, '0, a));
    put(QM, 0, mk_uop(0, pn(), pi(17), pf(63), 0, '0, b));
    put(QF, 0, mk_uop(TF_SHORT, pf(2), pf(0), pi(40), 0, '0, c));
    cycle();
    run_idle(3);
    expect_at(a, t0 + 1);
    expect_at(b, t0 + 1);
    expect_at(c, t0 + 1);
    end_test();
  endtask

  task automatic t_basic();
    int a, b, c, d, e, g;
    cyc_t t0, t1, t2, t3;
    begin_test("各 IQ・各 FU に ready なものを入れると次のサイクルに issue（payload と rr_ff の中身）");
    a = nid();
    b = nid();
    c = nid();
    d = nid();
    e = nid();
    g = nid();
    t0 = cyc;
    clear_inputs();
    put(QI, 0, mk_uop(0, pi(10), pi(20), pi(21), 0, bit_of(2), a));
    put(QM, 0, mk_uop(0, pf(11), pi(22), pn(), 0, bit_of(7), b));
    put(QF, 0, mk_uop(TF_SHORT, pf(12), pf(23), pn(), 0, '0, c));
    cycle();
    t1 = cyc;
    clear_inputs();
    put(QF, 0, mk_uop(TF_LONG, pi(13), pf(24), pf(25), 3, bit_of(0), d));
    cycle();
    t2 = cyc;
    clear_inputs();
    put(QF, 0, mk_uop(TF_DIV, pf(14), pf(26), pf(27), 2, '0, e));
    cycle();
    t3 = cyc;
    clear_inputs();
    put(QF, 0, mk_uop(TF_SQRT, pf(15), pf(28), pn(), 1, '0, g));
    cycle();
    run_idle(6);
    expect_at(a, t0 + 1);
    expect_at(b, t0 + 1);
    expect_at(c, t0 + 1);
    expect_at(d, t1 + 1);
    expect_at(e, t2 + 1);
    expect_at(g, t3 + 1);
    end_test();
  endtask

  // 消費側の uop
  function automatic disp_uop_t cons(int cq, int cf, preg_t p, int which, int id);
    return mk_uop(cf, (cq == QM) ? pn() : pi(60), (which == 1) ? p : pn(), (which == 2) ? p : pn(), 0, '0, id);
  endfunction

  // 生産側を dispatch してから o サイクル目（-1 は生産側と同じサイクル）に消費側を dispatch する
  task automatic lat_case(int pq, int pfu, preg_t p, int cq, int cf, int which, int lat, int o);
    int a, c;
    cyc_t t0, tw, d, x;
    if (o == -1 && cq == pq && q_dw(pq) < 2) return;
    quiet();
    a  = nid();
    c  = nid();
    t0 = cyc;
    tw = t0 + 1;  // 生産側の issue（wakeup）のサイクル
    clear_inputs();
    put(pq, 0, mk_uop(pfu, p, pn(), pn(), lat, '0, a));
    if (o == -1) put(cq, (cq == pq) ? 1 : 0, cons(cq, cf, p, which, c));
    cycle();
    for (int k = 0; k <= o; k++) begin
      clear_inputs();
      if (k == o) put(cq, 0, cons(cq, cf, p, which, c));
      cycle();
    end
    run_idle(lat + 3);
    d = (o == -1) ? t0 : tw + cyc_t'(o);
    x = tw + 1 + cyc_t'(lat);
    if (x < d + 1) x = d + 1;
    expect_at(a, tw);
    expect_at(c, x);
  endtask

  task automatic t_latency_matrix();
    int pq[3];
    int pfu[3];
    preg_t pp[3];
    int cq[4];
    int cf[4];
    begin_test("busy table: 生産側の lat と消費側を dispatch するタイミングの全組み合わせ（IQ をまたぐもの含む）");
    pq[0] = QI;
    pfu[0] = 0;
    pp[0] = pi(30);
    pq[1] = QF;
    pfu[1] = TF_LONG;
    pp[1] = pf(30);
    pq[2] = QF;
    pfu[2] = TF_LONG;
    pp[2] = pi(31);  // ftoi など
    cq[0] = QI;
    cf[0] = 0;
    cq[1] = QM;
    cf[1] = 0;
    cq[2] = QF;
    cf[2] = TF_SHORT;
    cq[3] = QF;
    cf[3] = TF_LONG;
    for (int i = 0; i < 3; i++)
      for (int k = 0; k < 4; k++)
        for (int lat = 0; lat < 4; lat++)
          for (int o = -1; o <= 5; o++) lat_case(pq[i], pfu[i], pp[i], cq[k], cf[k], 1 + (lat + o + 1) % 2, lat, o);
    end_test();
  endtask

  task automatic t_bypass();
    int a, b, c, d, e, g, h, x, y, z;
    cyc_t t0, t1, t2, t3, t4;
    begin_test("同じサイクルに dispatch する uop の rd を読むと結果待ちになる（IQ をまたぐもの、同じ IQ の別レーン）");
    // INT の rd を MEM と FP が同じサイクルに読む
    quiet();
    a  = nid();
    b  = nid();
    c  = nid();
    t0 = cyc;
    clear_inputs();
    put(QI, 0, mk_uop(0, pi(5), pn(), pn(), 2, '0, a));
    put(QM, 0, mk_uop(0, pn(), pi(5), pi(6), 0, '0, b));
    put(QF, 0, mk_uop(TF_LONG, pf(7), pi(5), pn(), 1, '0, c));
    cycle();
    run_idle(6);
    expect_at(a, t0 + 1);
    expect_at(b, t0 + 4);
    expect_at(c, t0 + 4);

    // 番号が同じでも種類が違えばバイパスしない
    quiet();
    d  = nid();
    e  = nid();
    t1 = cyc;
    clear_inputs();
    put(QI, 0, mk_uop(0, pi(8), pn(), pn(), 3, '0, d));
    put(QF, 0, mk_uop(TF_SHORT, pf(9), pf(8), pn(), 0, '0, e));
    cycle();
    run_idle(3);
    expect_at(d, t1 + 1);
    expect_at(e, t1 + 1);

    // 2 つのソースが別の IQ の 2 つの rd
    quiet();
    g  = nid();
    h  = nid();
    x  = nid();
    t2 = cyc;
    clear_inputs();
    put(QI, 0, mk_uop(0, pi(10), pn(), pn(), 0, '0, g));
    put(QF, 0, mk_uop(TF_LONG, pf(11), pn(), pn(), 1, '0, h));
    put(QM, 0, mk_uop(0, pn(), pi(10), pf(11), 0, '0, x));
    cycle();
    run_idle(5);
    expect_at(g, t2 + 1);
    expect_at(h, t2 + 1);
    expect_at(x, t2 + 3);

    // 同じ IQ の別レーン
    if (DW_INT >= 2) begin
      quiet();
      y  = nid();
      z  = nid();
      t3 = cyc;
      clear_inputs();
      put(QI, 0, mk_uop(0, pi(12), pn(), pn(), 0, '0, y));
      put(QI, 1, mk_uop(0, pi(13), pn(), pi(12), 0, '0, z));
      cycle();
      run_idle(3);
      expect_at(y, t3 + 1);
      expect_at(z, t3 + 2);
    end
    if (DW_FPU >= 2) begin
      quiet();
      y  = nid();
      z  = nid();
      t4 = cyc;
      clear_inputs();
      put(QF, 0, mk_uop(TF_LONG, pf(14), pn(), pn(), 3, '0, y));
      put(QF, 1, mk_uop(TF_SHORT, pf(15), pf(14), pf(14), 0, '0, z));
      cycle();
      run_idle(6);
      expect_at(y, t4 + 1);
      expect_at(z, t4 + 5);
    end
    if (DW_MEM >= 2) begin
      // load の rd を同じサイクルの store が読む（slow なので STD は外からの wakeup まで待つ。STA は先に出る）
      quiet();
      y = nid();
      z = nid();
      t3 = cyc;
      clear_inputs();
      put(QM, 0, mk_uop(0, pf(16), pi(3), pn(), 0, '0, y));
      put(QM, 1, mk_uop(0, pn(), pi(3), pf(16), 0, '0, z));
      cycle();
      run_idle(4);
      expect_at(y, t3 + 1);
      expect_at(z, t3 + 2);
      t4 = cyc;
      clear_inputs();
      ext(0, pf(16), 0);
      cycle();
      run_idle(2);
      expect_at(z, t4 + 1);
    end
    end_test();
  endtask

  task automatic t_redispatch();
    int a, b, c;
    cyc_t t0, tw, tx;
    begin_test("rd を割り当て直すと busy table は結果待ちに戻る（数えている途中、wakeup と同じサイクル）");
    for (int v = 0; v < 2; v++) begin
      quiet();
      a  = nid();
      b  = nid();
      c  = nid();
      t0 = cyc;
      tw = t0 + 1;
      clear_inputs();
      put(QI, 0, mk_uop(0, pi(30), pn(), pn(), 3, '0, a));
      cycle();
      // v=0: a の wakeup の次のサイクル（busy table は数えている途中）、v=1: wakeup と同じサイクル
      clear_inputs();
      if (v == 1) put(QM, 0, mk_uop(0, pi(30), pn(), pn(), 0, '0, b));
      cycle();
      clear_inputs();
      if (v == 0) put(QM, 0, mk_uop(0, pi(30), pn(), pn(), 0, '0, b));
      cycle();
      clear_inputs();
      put(QI, 0, mk_uop(0, pi(31), pi(30), pn(), 0, '0, c));
      cycle();
      run_idle(6);
      expect_never(c);
      tx = cyc;
      clear_inputs();
      ext(WAKEUP_W - 1, pi(30), 0);
      cycle();
      run_idle(2);
      expect_at(a, tw);
      expect_at(b, (v == 1) ? tw + 1 : tw + 2);
      expect_at(c, tx + 1);
    end
    end_test();
  endtask

  task automatic t_ignore_wakeup();
    int a, c, c2, c3, l;
    cyc_t t0, t1, tw, tx;
    begin_test("結果待ちでないレジスタへの wakeup は busy table が無視する");
    // ready なレジスタへの wakeup
    quiet();
    c = nid();
    clear_inputs();
    ext(0, pi(31), 3);
    cycle();
    t1 = cyc;
    clear_inputs();
    put(QI, 0, mk_uop(0, pn(), pi(31), pn(), 0, '0, c));
    cycle();
    run_idle(2);
    expect_at(c, t1 + 1);

    // もう起きたレジスタへの 2 回目の wakeup
    quiet();
    a  = nid();
    c2 = nid();
    c3 = nid();
    t0 = cyc;
    tw = t0 + 1;
    clear_inputs();
    put(QI, 0, mk_uop(0, pi(32), pn(), pn(), 0, '0, a));
    cycle();
    run_idle(1);
    clear_inputs();
    ext(0, pi(32), 3);
    put(QF, 0, mk_uop(TF_SHORT, pf(1), pi(32), pn(), 0, '0, c2));
    cycle();
    clear_inputs();
    put(QM, 0, mk_uop(0, pn(), pi(32), pn(), 0, '0, c3));
    cycle();
    run_idle(3);
    expect_at(a, tw);
    expect_at(c2, tw + 2);
    expect_at(c3, tw + 3);

    // 数えている途中の 2 回目の wakeup は latency を上書きしない
    quiet();
    l = nid();
    c = nid();
    clear_inputs();
    put(QM, 0, mk_uop(0, pf(33), pi(2), pn(), 0, '0, l));
    cycle();
    run_idle(2);
    tx = cyc;
    clear_inputs();
    ext(0, pf(33), 2);
    cycle();
    clear_inputs();
    ext(WAKEUP_W - 1, pf(33), 0);
    put(QF, 0, mk_uop(TF_SHORT, pf(34), pf(33), pn(), 0, '0, c));
    cycle();
    run_idle(4);
    expect_at(c, tx + 3);
    end_test();
  endtask

  task automatic t_ext_lanes();
    int l, c;
    cyc_t tx;
    begin_test("外からの wakeup はどのレーンでも busy table と全部の IQ に当たる（MEM は issue 時に wakeup を出さない）");
    for (int k = 0; k < WAKEUP_W; k++) begin
      for (int q = 0; q < NQ; q++) begin
        quiet();
        l = nid();
        c = nid();
        clear_inputs();
        put(QM, 0, mk_uop(0, (k % 2) ? pf(40) : pi(40), pi(1), pn(), 0, '0, l));
        cycle();
        clear_inputs();
        put(q, 0, mk_uop((q == QF) ? TF_SHORT : 0, pn(), (k % 2) ? pf(40) : pi(40), pn(), 0, '0, c));
        cycle();
        run_idle(4);
        expect_never(c);
        tx = cyc;
        clear_inputs();
        ext(k, (k % 2) ? pf(40) : pi(40), k % 4);
        cycle();
        run_idle(5);
        expect_at(c, tx + 1 + cyc_t'(k % 4));

        // busy table 側にも当たっている
        c = nid();
        clear_inputs();
        put(q, 0, mk_uop((q == QF) ? TF_LONG : 0, pn(), pn(), (k % 2) ? pf(40) : pi(40), 0, '0, c));
        tx = cyc;
        cycle();
        run_idle(2);
        expect_at(c, tx + 1);
      end
    end
    end_test();
  endtask

  task automatic t_fp_block();
    int l, a, b, c, d, e, f, g;
    cyc_t tw;
    begin_test("fdiv_blocked は DIV、fsqrt_blocked は SQRT だけを止める。DIV/SQRT は issue 後 ISSUE_TO_FU サイクル止まる");
    if (SIZE_FPU >= 3) begin
      // 古い方が DIV。fdiv_blocked の間は新しい SQRT が先に出る
      quiet();
      l = nid();
      a = nid();
      b = nid();
      clear_inputs();
      put(QM, 0, mk_uop(0, pf(35), pi(1), pn(), 0, '0, l));
      cycle();
      clear_inputs();
      put(QF, 0, mk_uop(TF_DIV, pf(50), pf(35), pf(1), 0, '0, a));
      cycle();
      clear_inputs();
      put(QF, 0, mk_uop(TF_SQRT, pf(51), pf(35), pn(), 0, '0, b));
      cycle();
      run_idle(1);
      tw = cyc;
      clear_inputs();
      ext(0, pf(35), 0);
      cycle();
      clear_inputs();
      fdiv_b = 1'b1;
      cycle();
      clear_inputs();
      fdiv_b = 1'b1;
      cycle();
      run_idle(3);
      expect_at(b, tw + 1);
      expect_at(a, tw + 3);

      // 古い方が SQRT。fsqrt_blocked の間は新しい DIV が先に出る
      quiet();
      l = nid();
      c = nid();
      d = nid();
      clear_inputs();
      put(QM, 0, mk_uop(0, pf(36), pi(1), pn(), 0, '0, l));
      cycle();
      clear_inputs();
      put(QF, 0, mk_uop(TF_SQRT, pf(52), pf(36), pn(), 0, '0, d));
      cycle();
      clear_inputs();
      put(QF, 0, mk_uop(TF_DIV, pf(53), pf(36), pf(2), 0, '0, c));
      cycle();
      run_idle(1);
      tw = cyc;
      clear_inputs();
      ext(0, pf(36), 0);
      cycle();
      clear_inputs();
      fsqrt_b = 1'b1;
      cycle();
      clear_inputs();
      fsqrt_b = 1'b1;
      cycle();
      run_idle(3);
      expect_at(c, tw + 1);
      expect_at(d, tw + 3);
    end

    if (SIZE_FPU >= 3) begin
      // DIV, DIV, SQRT が同時に ready
      quiet();
      l = nid();
      e = nid();
      f = nid();
      g = nid();
      clear_inputs();
      put(QM, 0, mk_uop(0, pf(37), pi(1), pn(), 0, '0, l));
      cycle();
      clear_inputs();
      put(QF, 0, mk_uop(TF_DIV, pf(54), pf(37), pf(3), 0, '0, e));
      cycle();
      clear_inputs();
      put(QF, 0, mk_uop(TF_DIV, pf(55), pf(37), pf(4), 0, '0, f));
      cycle();
      clear_inputs();
      put(QF, 0, mk_uop(TF_SQRT, pf(56), pf(37), pn(), 0, '0, g));
      cycle();
      run_idle(1);
      tw = cyc;
      clear_inputs();
      ext(0, pf(37), 0);
      cycle();
      run_idle(6);
      expect_at(e, tw + 1);
      expect_at(g, tw + 2);
      expect_at(f, tw + 4);
    end

    // blocked は SHORT / LONG には効かない
    quiet();
    a  = nid();
    b  = nid();
    tw = cyc;
    clear_inputs();
    put(QF, 0, mk_uop(TF_SHORT, pf(57), pn(), pn(), 0, '0, a));
    cycle();
    clear_inputs();
    fdiv_b  = 1'b1;
    fsqrt_b = 1'b1;
    put(QF, 0, mk_uop(TF_LONG, pf(58), pn(), pn(), 0, '0, b));
    cycle();
    clear_inputs();
    fdiv_b  = 1'b1;
    fsqrt_b = 1'b1;
    cycle();
    run_idle(2);
    expect_at(a, tw + 1);
    expect_at(b, tw + 2);
    end_test();
  endtask

  task automatic t_all_ports();
    int l, s, g, v, mm, x, c1, c2, c3;
    cyc_t tw, tx;
    if (SIZE_FPU < 4 || SIZE_INT < 2) return;
    begin_test("5 ポートが同じサイクルに issue し、その結果が別の IQ を起こす");
    quiet();
    l  = nid();
    s  = nid();
    g  = nid();
    v  = nid();
    mm = nid();
    x  = nid();
    c1 = nid();
    c2 = nid();
    c3 = nid();
    clear_inputs();
    put(QM, 0, mk_uop(0, pf(40), pi(1), pn(), 0, '0, l));
    cycle();
    clear_inputs();
    put(QF, 0, mk_uop(TF_SHORT, pf(41), pf(40), pn(), 0, '0, s));
    put(QM, 0, mk_uop(0, pn(), pi(2), pf(40), 0, '0, mm));
    put(QI, 0, mk_uop(0, pi(46), pn(), pf(40), 0, '0, x));
    cycle();
    clear_inputs();
    put(QF, 0, mk_uop(TF_LONG, pi(42), pf(40), pn(), 3, '0, g));
    put(QM, 0, mk_uop(0, pn(), pi(3), pf(41), 0, '0, c1));
    put(QI, 0, mk_uop(0, pi(47), pi(42), pi(46), 0, '0, c2));
    cycle();
    clear_inputs();
    put(QF, 0, mk_uop(TF_DIV, pf(43), pf(40), pf(40), 0, '0, v));
    cycle();
    clear_inputs();
    put(QF, 0, mk_uop(TF_SHORT, pf(44), pf(43), pn(), 0, '0, c3));
    cycle();
    run_idle(1);
    tw = cyc;
    clear_inputs();
    ext(0, pf(40), 0);
    cycle();
    run_idle(8);
    expect_at(s, tw + 1);
    expect_at(g, tw + 1);
    expect_at(v, tw + 1);
    expect_at(mm, tw + 1);
    expect_at(x, tw + 1);
    expect_at(c1, tw + 2);
    expect_at(c2, tw + 5);
    expect_never(c3);
    tx = cyc;
    clear_inputs();
    ext(0, pf(43), 0);
    cycle();
    run_idle(2);
    expect_at(c3, tx + 1);
    end_test();
  endtask

  task automatic t_branch();
    int l, a, b, c, d, e, f, g, h, y, z;
    cyc_t tw, tk;
    begin_test("mispredict は 3 つの IQ を同時に消し、resolve は全部の IQ と rr_ff のビットを落とす");
    quiet();
    l = nid();
    a = nid();
    b = nid();
    c = nid();
    d = nid();
    e = nid();
    clear_inputs();
    put(QM, 0, mk_uop(0, pi(50), pi(1), pn(), 0, '0, l));
    cycle();
    clear_inputs();
    put(QI, 0, mk_uop(0, pi(51), pi(50), pn(), 0, bit_of(3), a));
    put(QM, 0, mk_uop(0, pn(), pi(50), pn(), 0, bit_of(3) | bit_of(5), b));
    put(QF, 0, mk_uop(TF_SHORT, pf(52), pi(50), pn(), 0, bit_of(3), c));
    cycle();
    clear_inputs();
    put(QI, 0, mk_uop(0, pi(53), pi(50), pn(), 0, bit_of(5), d));
    put(QF, 0, mk_uop(TF_LONG, pf(54), pi(50), pn(), 1, bit_of(1) | bit_of(5), e));
    // dispatch と同じサイクルの kill（MEM と FP）
    put(QM, 0, mk_uop(0, pn(), pi(50), pn(), 0, bit_of(4), y));
    mispredict(0, 4);
    cycle();
    clear_inputs();
    mispredict(0, 3);
    cycle();
    clear_inputs();
    resolve(0, 5);
    cycle();
    // タグ 5 が使い回されて外れても d, e は消えない
    clear_inputs();
    mispredict(0, 5);
    cycle();
    run_idle(1);
    tw = cyc;
    clear_inputs();
    ext(0, pi(50), 0);
    cycle();
    run_idle(4);
    expect_never(a);
    expect_never(b);
    expect_never(c);
    expect_never(y);
    expect_at(d, tw + 1);
    expect_at(e, tw + 1);

    if (BR_UPDATE_W >= 2) begin
      // 同じサイクルに resolve と mispredict が別のレーンで来る
      quiet();
      l = nid();
      f = nid();
      g = nid();
      h = nid();
      z = nid();
      clear_inputs();
      put(QM, 0, mk_uop(0, pi(55), pi(1), pn(), 0, '0, l));
      cycle();
      clear_inputs();
      put(QI, 0, mk_uop(0, pi(56), pi(55), pn(), 0, bit_of(1) | bit_of(7), f));
      put(QF, 0, mk_uop(TF_SHORT, pf(57), pi(55), pn(), 0, bit_of(1), g));
      put(QM, 0, mk_uop(0, pn(), pi(55), pn(), 0, bit_of(1) | bit_of(2), h));
      cycle();
      tk = cyc;
      clear_inputs();
      resolve(0, 1);
      mispredict(1, 7);
      put(QF, 0, mk_uop(TF_LONG, pf(58), pi(55), pn(), 0, bit_of(7), z));
      cycle();
      clear_inputs();
      resolve(1, 2);
      mispredict(0, 1);
      cycle();
      run_idle(1);
      tw = cyc;
      clear_inputs();
      ext(0, pi(55), 0);
      cycle();
      run_idle(3);
      expect_never(f);
      expect_never(z);
      expect_at(g, tw + 1);
      expect_at(h, tw + 1);
    end
    end_test();
  endtask

  task automatic t_flush_rst();
    int l, a, c;
    cyc_t t1;
    begin_test("flush / rst で busy table が全部 ready に戻る（同じサイクルの dispatch の rd も無視）");
    for (int v = 0; v < 3; v++) begin
      quiet();
      l = nid();
      a = nid();
      c = nid();
      if (v < 2) begin
        clear_inputs();
        put(QM, 0, mk_uop(0, pi(51), pi(1), pn(), 0, '0, l));
        cycle();
        clear_inputs();
        put(QI, 0, mk_uop(0, pi(52), pi(51), pn(), 0, '0, a));
        put(QF, 0, mk_uop(TF_LONG, pf(52), pf(1), pi(51), 3, '0, nid()));
        cycle();
        run_idle(3);
        clear_inputs();
        if (v == 0) flush = 1'b1;
        else rst = 1'b1;
        cycle();
      end else begin
        clear_inputs();
        flush = 1'b1;
        put(QI, 0, mk_uop(0, pi(52), pn(), pn(), 0, '0, a));
        put(QM, 0, mk_uop(0, pi(51), pn(), pn(), 0, '0, l));
        cycle();
      end
      t1 = cyc;
      clear_inputs();
      put(QI, 0, mk_uop(0, pn(), pi(52), pi(51), 0, '0, c));
      cycle();
      run_idle(2);
      expect_never(a);
      expect_at(c, t1 + 1);
    end
    end_test();
  endtask

  task automatic t_full();
    int l;
    int fill[$];
    cyc_t tw;
    begin_test("disp_full は IQ ごとに独立に立つ");
    for (int q = 0; q < NQ; q++) begin
      quiet();
      fill.delete();
      l = nid();
      clear_inputs();
      put(QM, 0, mk_uop(0, pi(54), pi(1), pn(), 0, '0, l));
      cycle();
      run_idle(1);
      // 条件に関数を入れたループの中で cycle() を呼ぶと Verilator 5.020 で戻ってこないので、break で抜ける
      repeat (2 * MAXS) begin
        if (model_full(q)) break;
        clear_inputs();
        for (int k = 0; k < q_dw(q); k++) begin
          fill.push_back(nid());
          put(q, k, mk_uop((q == QF) ? TF_SHORT : 0, pn(), pi(54), pn(), 0, '0, fill[fill.size()-1]));
        end
        cycle();
      end
      expect_true(model_full(q), $sformatf("%s が満杯にならない（中身 %0d/%0d）", q_name(q), occ(q), q_size(q)));
      clear_inputs();
      cycle();
      expect_true(o_full(q) === 1'b1, $sformatf("%s が満杯なのに disp_full が立たない", q_name(q)));
      for (int q2 = 0; q2 < NQ; q2++)
        if (q2 != q) expect_true(o_full(q2) === 1'b0, $sformatf("%s が満杯なだけで %s の disp_full が立った", q_name(q), q_name(q2)));
      tw = cyc;
      clear_inputs();
      ext(0, pi(54), 0);
      cycle();
      run_idle(MAXS + 3);
      foreach (fill[k]) expect_true(issued_at.exists(fill[k]), $sformatf("%s の id %0d が出ていない", q_name(q), fill[k]));
      expect_true(occ(q) == 0, $sformatf("%s が空にならない", q_name(q)));
    end
    end_test();
  endtask

  task automatic t_none();
    int a, b, c;
    cyc_t t0, t1;
    begin_test("rd が NONE の uop は busy table を変えず wakeup も出さない");
    quiet();
    a  = nid();
    b  = nid();
    c  = nid();
    t0 = cyc;
    clear_inputs();
    put(QI, 0, mk_uop(0, pn(), pn(), pn(), 0, '0, a));
    put(QM, 0, mk_uop(0, pn(), pi(1), pf(1), 0, '0, b));
    cycle();
    t1 = cyc;
    clear_inputs();
    put(QF, 0, mk_uop(TF_SHORT, pf(3), pn(), pf(0), 0, '0, c));
    cycle();
    run_idle(3);
    expect_at(a, t0 + 1);
    expect_at(b, t0 + 1);
    expect_at(c, t1 + 1);
    end_test();
  endtask

  // ---------------- ランダムテスト ----------------

  typedef struct packed {
    cyc_t at;
    preg_t preg;
    brmask_t bm;
    logic [31:0] id;
  } pend_t;

  pend_t pend[$];  // これから流す書き込み時の wakeup（MEM と DIV/SQRT の分）
  logic blk_v[2];  // [0] DIV, [1] SQRT
  cyc_t blk_from[2];
  cyc_t blk_to[2];

  // このサイクルに作った uop の rd とソース
  preg_t g_rd[$];
  brmask_t g_rd_bm[$];
  preg_t g_src[$];
  preg_t g_ext[$];

  function automatic preg_t rand_reg(preg_type_t t);
    return mk_preg(t, 1 + rnd(NPREG - 1));
  endfunction

  // 結果がまだ来ていない生産者がいるか（いればその brmask を if_bm に入れる）
  brmask_t if_bm;

  function automatic logic inflight(preg_t s);
    logic found = 1'b0;
    if_bm = '0;
    for (int q = 0; q < NQ; q++)
      for (int k = 0; k < q_size(q); k++)
        if (!found && m[q][k].valid && m[q][k].u.rd == s) begin
          found = 1'b1;
          if_bm = m[q][k].bm;
        end
    foreach (pend[k])
      if (!found && pend[k].preg == s) begin
        found = 1'b1;
        if_bm = pend[k].bm;
      end
    return found;
  endfunction

  // 結果待ちのまま生産者が消えたもの
  function automatic logic dead(preg_t s);
    return tbl_pend[ti(s)][s.idx] && !inflight(s);
  endfunction

  function automatic logic in_list(preg_t s, preg_t l[$]);
    foreach (l[k]) if (l[k] == s) return 1'b1;
    return 1'b0;
  endfunction

  // 生産者の brmask を gen_bm に足しながらソースを選ぶ
  brmask_t gen_bm;
  string pick_how;
  string how1[int];
  string how2[int];
  typedef struct packed {
    logic [31:0] id;
    cyc_t c;
    int q;
    preg_t rd;
  } glog_t;
  glog_t glog[$];

  // どの選び方でも、同じサイクルに dispatch する uop の rd なら、その生産者の brmask を引き継ぐ
  function automatic preg_t pick_src(preg_type_t t);
    preg_t s;
    s = pick_src_raw(t);
    for (int i = 0; i < g_rd.size(); i++) if (g_rd[i] == s) gen_bm |= g_rd_bm[i];
    return s;
  endfunction

  function automatic preg_t pick_src_raw(preg_type_t t);
    int r;
    int k;
    int q;
    preg_t s;
    preg_t cand[$];
    // ローカルなキューが呼び出しごとに空にならない（Verilator 5.020）
    cand.delete();
    pick_how = "NONE";
    if (t == PREG_TYPE_NONE) return pn();
    r = rnd(100);
    if (r < 25) begin
      // 同じサイクルの rd（バイパス）
      for (int i = 0; i < g_rd.size(); i++) begin
        if (g_rd[i].typ == t) begin
          cand.push_back(g_rd[i]);
        end
      end
      if (cand.size() > 0) begin
        s = cand[rnd(cand.size())];
        for (int i = 0; i < g_rd.size(); i++) if (g_rd[i] == s) gen_bm |= g_rd_bm[i];
        pick_how = "バイパス";
        return s;
      end
    end else if (r < 55) begin
      // まだ結果が来ていない生産者
      for (int tries = 0; tries < 8; tries++) begin
        q = rnd(NQ);
        k = rnd(q_size(q));
        if (m[q][k].valid && m[q][k].u.rd.typ == t) begin
          gen_bm |= m[q][k].bm;
          pick_how = $sformatf("IQ の id %0d", m[q][k].id);
          return m[q][k].u.rd;
        end
      end
      foreach (pend[i])
        if (pend[i].preg.typ == t && rnd(2) == 0) begin
          gen_bm |= pend[i].bm;
          pick_how = $sformatf("書き込み待ちの id %0d", pend[i].id);
          return pend[i].preg;
        end
    end else if (r < 80) begin
      // busy table が数えている途中のもの
      for (int i = 0; i < NPREG; i++) begin
        s = mk_preg(t, i);
        if (!tbl_pend[ti(s)][i] && tbl_rat[ti(s)][i] > cyc) cand.push_back(s);
      end
      pick_how = "数えている途中";
      if (cand.size() > 0) return cand[rnd(cand.size())];
    end
    for (int tries = 0; tries < 16; tries++) begin
      s = rand_reg(t);
      if (!dead(s)) begin
        if (inflight(s)) gen_bm |= if_bm;
        pick_how = $sformatf("ランダム（inflight=%0b）", inflight(s));
        return s;
      end
    end
    pick_how = "NONE";
    return pn();
  endfunction

  function automatic preg_t pick_rd(preg_type_t t);
    preg_t s;
    if (t == PREG_TYPE_NONE) return pn();
    for (int tries = 0; tries < 16; tries++) begin
      s = rand_reg(t);
      if (inflight(s) || in_list(s, g_rd) || in_list(s, g_src) || in_list(s, g_ext)) continue;
      return s;
    end
    return pn();
  endfunction

  task automatic gen_uop(int q, output disp_uop_t u);
    int f;
    int r;
    int lat;
    preg_type_t rdt, s1t, s2t;
    brmask_t bm;
    preg_t s1, s2, rd;
    glog_t ge;
    f   = 0;
    lat = 0;
    r   = rnd(100);
    case (q)
      QI: begin
        rdt = (r < 80) ? PREG_TYPE_I : PREG_TYPE_NONE;
        s1t = (rnd(100) < 85) ? PREG_TYPE_I : PREG_TYPE_NONE;
        s2t = (rnd(100) < 60) ? PREG_TYPE_I : PREG_TYPE_NONE;
        lat = (rnd(100) < 80) ? 0 : rnd(4);
      end
      QM: begin
        // lw / flw / sw / fsw / flhi
        r = rnd(5);
        case (r)
          0: begin rdt = PREG_TYPE_I; s1t = PREG_TYPE_I; s2t = PREG_TYPE_NONE; end
          1: begin rdt = PREG_TYPE_F; s1t = PREG_TYPE_I; s2t = PREG_TYPE_NONE; end
          2: begin rdt = PREG_TYPE_NONE; s1t = PREG_TYPE_I; s2t = PREG_TYPE_I; end
          3: begin rdt = PREG_TYPE_NONE; s1t = PREG_TYPE_I; s2t = PREG_TYPE_F; end
          default: begin rdt = PREG_TYPE_F; s1t = PREG_TYPE_NONE; s2t = PREG_TYPE_NONE; end
        endcase
        lat = rnd(4);
      end
      default: begin
        f = (r < 35) ? 0 : (r < 70) ? 1 : (r < 85) ? 2 : 3;
        case (f)
          0: begin
            rdt = PREG_TYPE_F;
            s1t = (rnd(100) < 80) ? PREG_TYPE_F : PREG_TYPE_NONE;
            s2t = PREG_TYPE_NONE;
            lat = 0;
          end
          1: begin
            rdt = (rnd(100) < 75) ? PREG_TYPE_F : PREG_TYPE_I;
            s1t = (rnd(100) < 85) ? PREG_TYPE_F : PREG_TYPE_I;
            s2t = (rnd(100) < 70) ? PREG_TYPE_F : PREG_TYPE_NONE;
            lat = (rnd(2) == 0) ? 1 : 3;
          end
          2: begin
            rdt = PREG_TYPE_F;
            s1t = PREG_TYPE_F;
            s2t = PREG_TYPE_F;
            lat = rnd(4);
          end
          default: begin
            rdt = PREG_TYPE_F;
            s1t = PREG_TYPE_F;
            s2t = PREG_TYPE_NONE;
            lat = rnd(4);
          end
        endcase
      end
    endcase
    gen_bm = '0;
    for (int b = 0; b < MAX_BR; b++) if (rnd(16) == 0) gen_bm[b] = 1'b1;
    s1 = pick_src(s1t);
    how1[next_id] = pick_how;
    s2 = pick_src(s2t);
    how2[next_id] = pick_how;
    g_src.push_back(s1);
    g_src.push_back(s2);
    rd = pick_rd(rdt);
    u  = mk_uop(f, rd, s1, s2, lat, gen_bm, nid());
    ge.id = u.imm;
    ge.c = cyc;
    ge.q = q;
    ge.rd = rd;
    glog.push_back(ge);
    if (glog.size() > 4000) void'(glog.pop_front());
    if (is_reg(rd)) begin
      g_rd.push_back(rd);
      g_rd_bm.push_back(gen_bm);
    end
  endtask

  task automatic gen_random(logic dispatch_on, logic events_on);
    logic stall;
    int used;
    int i;
    preg_t s;
    disp_uop_t u;

    clear_inputs();
    g_rd.delete();
    g_rd_bm.delete();
    g_src.delete();
    g_ext.delete();
    if (events_on) begin
      rst   = rnd(10000) < 3;
      flush = !rst && rnd(1000) < 3;
      for (int k = 0; k < BR_UPDATE_W; k++) begin
        if (rnd(100) < 6) begin
          if (rnd(100) < 35) mispredict(k, rnd(MAX_BR));
          else resolve(k, rnd(MAX_BR));
        end
      end
    end

    // 書き込み時の wakeup（最後のレーン以外）。ときどき止めて（長いキャッシュミスのつもり）IQ を満杯にする
    stall = events_on && (cyc % 3000) < 150;
    used = 0;
    i = 0;
    while (!stall && i < pend.size()) begin
      if (pend[i].at <= cyc && used < WAKEUP_W - 1) begin
        ext(used, pend[i].preg, 0);
        fate[int'(pend[i].id)] = $sformatf("書き込み wakeup %0d", cyc);
        g_ext.push_back(pend[i].preg);
        used++;
        pend.delete(i);
      end else begin
        i++;
      end
    end
    // 生産者のいないレジスタへの余計な wakeup（busy table は結果待ちのものだけ拾う）
    if (events_on && rnd(100) < 30) begin
      s = rand_reg(rnd(2) ? PREG_TYPE_I : PREG_TYPE_F);
      if (!inflight(s) && !in_list(s, g_ext)) begin
        ext(WAKEUP_W - 1, s, rnd(4));
        g_ext.push_back(s);
      end
    end

    fdiv_b  = (blk_v[0] && cyc >= blk_from[0] && cyc <= blk_to[0]) || (rnd(100) < 3);
    fsqrt_b = (blk_v[1] && cyc >= blk_from[1] && cyc <= blk_to[1]) || (rnd(100) < 3);

    if (!dispatch_on) return;
    for (int q = 0; q < NQ; q++) begin
      if (model_full(q)) continue;
      for (int l = 0; l < q_dw(q); l++) begin
        if (rnd(100) >= (stall ? 90 : 55)) continue;
        gen_uop(q, u);
        put(q, l, u);
      end
    end
  endtask

  // issue されたものに合わせて、FU の busy と書き込み時の wakeup を用意する
  task automatic after_random_cycle(cyc_t t, logic was_reset);
    int f;
    int d;
    pend_t pe;
    if (was_reset) begin
      pend.delete();
      blk_v[0] = 1'b0;
      blk_v[1] = 1'b0;
      return;
    end
    for (int q = 0; q < NQ; q++) begin
      for (int p = 0; p < q_ports(q); p++) begin
        if (!exp_rr_v[q][p]) continue;
        f = gfu(q, exp_rr[q][p].u);
        pe.preg = exp_rr[q][p].u.rd;
        pe.bm = exp_rr[q][p].bm;
        pe.id = exp_rr[q][p].id;
        if (q == QM && is_reg(pe.preg)) begin
          pe.at = t + 2 + cyc_t'(rnd(10));
          pend.push_back(pe);
        end
        if (q == QF && f >= 2) begin
          // FU は t+2 に受け取り、t+3 から d サイクル blocked を出す
          d = 1 + rnd(8);
          blk_v[f-2] = 1'b1;
          blk_from[f-2] = t + 3;
          blk_to[f-2] = t + 2 + cyc_t'(d);
          if (is_reg(pe.preg)) begin
            pe.at = t + 3 + cyc_t'(d);
            pend.push_back(pe);
          end
        end
      end
    end
    // 外れた分岐の後ろの命令は書き込まない
    for (int k = pend.size() - 1; k >= 0; k--) begin
      if (killed_by(pend[k].bm)) begin
        fate[int'(pend[k].id)] = $sformatf("書き込み前に kill %0d", cyc);
        pend.delete(k);
        st_pend_kill++;
      end else begin
        pend[k].bm = resolve_mask(pend[k].bm);
      end
    end
  endtask

  function automatic string src_info(preg_t s, logic w, cyc_t r);
    int t;
    int mid;
    if (!is_reg(s)) return "NONE";
    t = ti(s);
    mid = mark_id[t][s.idx];
    return $sformatf("%s%0d w=%0b r=%0d [表 pend=%0b rat=%0d、最後に結果待ちにしたのは id %0d (cycle %0d): %s]",
                     (t == 0) ? "i" : "f", s.idx, w, r, tbl_pend[t][s.idx], tbl_rat[t][s.idx], mid,
                     mark_cyc[t][s.idx], fate.exists(mid) ? fate[mid] : "?");
  endfunction

  task automatic dump_stuck();
    say($sformatf("詰まったものの中身（cycle %0d、書き込み待ち %0d 個）", cyc, pend.size()));
    for (int q = 0; q < NQ; q++)
      for (int k = 0; k < q_size(q); k++)
        if (m[q][k].valid) begin
          say($sformatf("  %s id %0d fu %0d rd %s bm %b（%s）", q_name(q), m[q][k].id, m[q][k].u.dest_fu,
                        src_info(m[q][k].u.rd, 1'b1, '0), m[q][k].bm, fate[int'(m[q][k].id)]));
          say($sformatf("    rs1 %s 選び方: %s", src_info(m[q][k].u.rs1, m[q][k].w1, m[q][k].r1), how1[int'(m[q][k].id)]));
          say($sformatf("    rs2 %s 選び方: %s", src_info(m[q][k].u.rs2, m[q][k].w2, m[q][k].r2), how2[int'(m[q][k].id)]));
          if (!m[q][k].w1) show_gen(m[q][k].u.rs1);
          if (!m[q][k].w2) show_gen(m[q][k].u.rs2);
        end
  endtask

  task automatic show_gen(preg_t s);
    foreach (glog[i])
      if (glog[i].rd == s)
        say($sformatf("      %s%0d を rd にした uop: id %0d cycle %0d %s（%s）", (s.typ == PREG_TYPE_I) ? "i" : "f", s.idx,
                      glog[i].id, glog[i].c, q_name(glog[i].q), fate.exists(int'(glog[i].id)) ? fate[int'(glog[i].id)] : "dispatch されていない"));
  endtask

  task automatic random_test(int n);
    cyc_t t;
    logic rs;
    int drain;
    begin_test("ランダム");
    blk_v[0] = 1'b0;
    blk_v[1] = 1'b0;
    pend.delete();
    for (int k = 0; k < NK; k++) st_kind[k] = 0;
    for (int q = 0; q < NQ; q++) begin
      st_kill[q] = 0;
      st_drop_kill[q] = 0;
      st_full[q] = 0;
      st_in_block[q] = 0;
      st_memo_block[q] = 0;
      for (int p = 0; p < MAXP; p++) st_issue[q][p] = 0;
    end
    st_drop_full = 0;
    st_disp_wake = 0;
    st_rewake = 0;
    st_tbl_wake = 0;
    st_tbl_ignore = 0;
    st_mark_counting = 0;
    st_mark_wake = 0;
    st_flush = 0;
    st_rst = 0;
    st_resolve = 0;
    st_pend_kill = 0;
    st_mem_partial = 0;
    st_mem_both = 0;

    for (int k = 0; k < n; k++) begin
      gen_random(1'b1, 1'b1);
      t  = cyc;
      rs = rst || flush;
      cycle();
      after_random_cycle(t, rs);
      if (logf != 0 && n >= 20 && (k + 1) % (n / 20) == 0) begin
        $fdisplay(logf, "  ランダム %0d / %0d サイクル（%0d%%）、エラー %0d 個", k + 1, n, (k + 1) * 100 / n, errors);
        $fflush(logf);
      end
    end

    // 入れるのをやめたら全部出ていく（どこかで詰まっていない）
    // 書き込み時の wakeup は外のレーン 1 本ずつしか流せず溜まっていることがあるので、それが捌けるまで回す
    drain = 0;
    repeat (80 + 4 * pend.size()) begin
      if (drain >= 80 && pend.size() == 0 && occ(QI) == 0 && occ(QM) == 0 && occ(QF) == 0) break;
      gen_random(1'b0, 1'b0);
      t = cyc;
      cycle();
      after_random_cycle(t, 1'b0);
      drain++;
    end
    if (occ(QI) + occ(QM) + occ(QF) > 0) dump_stuck();
    for (int q = 0; q < NQ; q++)
      expect_true(occ(q) == 0, $sformatf("ランダムの後 %s に %0d 個残っている（詰まった、%0d サイクル流した、書き込み待ち %0d 個）",
                                         q_name(q), occ(q), drain, pend.size()));

    $display("  ランダム %0d サイクル: flush %0d, rst %0d, resolve %0d, 書き込み前に kill %0d", n, st_flush, st_rst,
             st_resolve, st_pend_kill);
    $display("  ソース: NONE %0d, 同じ IQ のバイパス %0d, IQ をまたぐバイパス %0d, 結果待ち %0d, 数えている途中 1/2/3 = %0d/%0d/%0d, ready %0d",
             st_kind[K_NONE], st_kind[K_BYP_SAME], st_kind[K_BYP_CROSS], st_kind[K_PEND], st_kind[K_CNT1],
             st_kind[K_CNT2], st_kind[K_CNT3], st_kind[K_READY]);
    $display("  dispatch と同じサイクルの wakeup %0d, 二重 wakeup %0d, busy table が拾った wakeup %0d / 無視 %0d",
             st_disp_wake, st_rewake, st_tbl_wake, st_tbl_ignore);
    $display("  数えている途中の rd の割り当て直し %0d, wakeup と同じサイクルの割り当て直し %0d", st_mark_counting, st_mark_wake);
    $display("  MEM の store: 片側だけ先に出した %0d, 1 回で出した %0d", st_mem_partial, st_mem_both);
    for (int q = 0; q < NQ; q++) begin
      $display("  %s: kill %0d, dispatch で kill %0d, 満杯 %0d サイクル, blocked で止めた %0d, ISSUE_TO_FU で止めた %0d", q_name(q),
               st_kill[q], st_drop_kill[q], st_full[q], st_in_block[q], st_memo_block[q]);
      for (int p = 0; p < q_ports(q); p++) $display("    port%0d issue %0d", p, st_issue[q][p]);
    end

    // 狙った状況が起きていなければテストとして意味が無いので落とす
    for (int q = 0; q < NQ; q++) begin
      for (int p = 0; p < q_ports(q); p++)
        expect_true(st_issue[q][p] > 0, $sformatf("%s port%0d が一度も issue していない", q_name(q), p));
      expect_true(st_kill[q] > 0, $sformatf("%s で IQ 内の kill が起きていない", q_name(q)));
      expect_true(st_drop_kill[q] > 0, $sformatf("%s で dispatch 中の kill が起きていない", q_name(q)));
      expect_true(st_full[q] > 0, $sformatf("%s が満杯になっていない", q_name(q)));
    end
    expect_true(st_drop_full == 0, "満杯の IQ に入れようとした（テストの誤り）");
    expect_true(st_kind[K_BYP_CROSS] > 0, "IQ をまたぐバイパスが起きていない");
    if (DW_INT >= 2 || DW_MEM >= 2 || DW_FPU >= 2) expect_true(st_kind[K_BYP_SAME] > 0, "同じ IQ のバイパスが起きていない");
    expect_true(st_kind[K_PEND] > 0, "結果待ちのソースの dispatch が起きていない");
    expect_true(st_kind[K_CNT1] > 0 && st_kind[K_CNT2] > 0 && st_kind[K_CNT3] > 0,
                "busy table が数えている途中（1/2/3）の dispatch が全部起きていない");
    expect_true(st_kind[K_READY] > 0, "ready なソースの dispatch が起きていない");
    expect_true(st_disp_wake > 0, "dispatch と同じサイクルの wakeup が起きていない");
    expect_true(st_tbl_ignore > 0, "busy table が wakeup を無視する状況が起きていない");
    expect_true(st_mark_counting > 0, "数えている途中の rd の割り当て直しが起きていない");
    expect_true(st_in_block[QF] > 0, "fdiv/fsqrt_blocked で止める状況が起きていない");
    expect_true(st_memo_block[QF] > 0, "ISSUE_TO_FU で止める状況が起きていない");
    expect_true(st_flush > 0, "flush が起きていない");
    expect_true(st_rst > 0, "rst が起きていない");
    expect_true(st_resolve > 0, "resolve が起きていない");
    expect_true(st_pend_kill > 0, "書き込み前の kill が起きていない");
    expect_true(st_mem_partial > 0, "MEM の store を片側だけ先に出す状況が起きていない");
    expect_true(st_mem_both > 0, "MEM の store を 1 回で出す状況が起きていない");
    end_test();
  endtask

  // ---------------- 本体 ----------------

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
    next_seq = 0;
    next_id = 1;
    checking = 1'b0;
    test_name = "リセット";
    for (int q = 0; q < NQ; q++) begin
      for (int k = 0; k < MAXS; k++) m[q][k] = '0;
      for (int f = 0; f < MAXF; f++) begin
        memo_v[q][f]  = 1'b0;
        memo_at[q][f] = '0;
      end
    end
    for (int t = 0; t < 2; t++) begin
      for (int i = 0; i < NPREG; i++) begin
        tbl_pend[t][i] = 1'b0;
        tbl_rat[t][i]  = '0;
      end
    end

    say($sformatf("iq_top: SIZE=%0d/%0d/%0d DISPATCH_W=%0d/%0d/%0d WAKEUP_W=%0d BR_UPDATE_W=%0d seed=%0d cycles=%0d",
                  SIZE_INT, SIZE_MEM, SIZE_FPU, DW_INT, DW_MEM, DW_FPU, WAKEUP_W, BR_UPDATE_W, seed, ncycles));

    clear_inputs();
    rst = 1'b1;
    cycle();
    rst = 1'b1;
    cycle();
    checking = 1'b1;

    t_reset();
    t_basic();
    t_latency_matrix();
    t_bypass();
    t_redispatch();
    t_ignore_wakeup();
    t_ext_lanes();
    t_fp_block();
    t_all_ports();
    t_branch();
    t_flush_rst();
    t_full();
    t_none();
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
