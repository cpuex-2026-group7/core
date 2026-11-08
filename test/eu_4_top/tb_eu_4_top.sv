`timescale 1ns / 1ps
`default_nettype none

// eu_4_top（F超長 の EU）のテストベンチ（Verilator の --binary --timing で動かす）
//
// 実行時オプション
//   +cycles=N  ランダムテストのサイクル数（既定 200000）
//   +seed=N    乱数の種（既定 1）
//
// 演算器（fsqrt / fdiv）は models/ の代わりを使う。値とサイクル数は eu_4_model_pkg のもので、
// float の計算ではない。ここで確かめるのは EU の blocked・kill（abort）・F-W3 の調停・slow wakeup。
//
// negedge で次のサイクルの入力（rr_ex / br_update_ff / flush / rst）を入れ、1ns 待ってから出力を見る。
//
// テストベンチは IQ の代わりもする。FU i への rr_ex は、前のサイクルの blocked[i] が 0 で、
// 前のサイクルに FU i への rr_ex を出していないときだけ出す（IQ の blocked と busy_memo の代わり）。
//
// テストの前提にしている仕様（rr_ex がサイクル t に来たとする）
//   - issued = rr_ex.valid && !flush。演算器は t + lat サイクルに done を出す
//   - サイクル t+1 から FU の meta が生きる（t の rst で消える）。各サイクル k で、k の flush か
//     「その時点の brmask & k の kill_mask」で消える（消えたら演算器に abort が行き、書き込まない）
//   - 生きている命令の done のサイクルに書き込む。fsqrt と fdiv が同じサイクルに終わったら fsqrt が先で、
//     fdiv は次のサイクルに書き込む（待っている間も kill / flush で消える）
//   - 待っている fdiv があるサイクルには、ほかの演算は終わらない（終わったらエラーにする）
//   - slow_wakeup = {to_wb.valid, to_wb.rd, LAT_FAST}
//   - fsqrt_blocked = fsqrt の meta が生きている（そのサイクルの kill は当てない）
//     fdiv_blocked  = fdiv の meta が生きている || 待っている fdiv がある
//   - rr_ex は RR で今の br_update を当てた後のものなので、brmask は今の kill_mask / resolve_mask と重ねない

module tb_eu_4_top
  import types::*;
  import isa::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import iq_types::*;
  import rr_types::*;
  import ex_types::*;
  import eu_4_model_pkg::*;
();

  localparam int MAX_ERRORS = 30;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic         rst;
  logic         flush;
  rr_ex_float_t rr_ex;
  br_update_t   br_update_ff;
  ex_wb_t       to_wb;
  wakeup_t      slow_wakeup;
  logic         fdiv_blocked;
  logic         fsqrt_blocked;

  eu_4_top dut (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .rr_ex(rr_ex),
    .br_update_ff(br_update_ff),
    .to_wb(to_wb),
    .slow_wakeup(slow_wakeup),
    .fdiv_blocked(fdiv_blocked),
    .fsqrt_blocked(fsqrt_blocked)
  );

  // ---------------- 乱数 ----------------

  function automatic int unsigned rnd(int unsigned n);
    return $urandom_range(n - 1, 0);
  endfunction

  function automatic word_t rnd_word();
    case (rnd(6))
      0: return 32'h0000_0000;
      1: return 32'hFFFF_FFFF;
      2: return 32'h8000_0000;
      default: return $urandom();
    endcase
  endfunction

  function automatic string fu_name(int i);
    return (i == FU_FSQRT) ? "FSQRT" : "FDIV";
  endfunction

  // ---------------- 命令の記録 ----------------

  typedef struct {
    logic     valid;
    int       fu;
    preg_t    rd;
    brmask_t  brmask;
    rob_idx_t rob_idx;
    int       done_cyc;
    word_t    value;
  } ent_t;

  // ---------------- 入力を作る ----------------

  typedef struct {
    logic         rst;
    logic         flush;
    rr_ex_float_t rr;
    br_update_t   upd;
  } in_t;

  function automatic br_update_t gen_br_update();
    br_update_t u;
    u = '0;
    if (rnd(12) == 0) u.kill_mask[rnd(MAX_BR)] = 1'b1;
    if (rnd(3) == 0) u.resolve_mask = brmask_t'($urandom() & $urandom());
    u.resolve_mask &= ~u.kill_mask;
    u.mispredict = |u.kill_mask;
    u.tag = br_tag_t'(rnd(MAX_BR));
    u.pc = pc_t'($urandom());
    u.target = pc_t'($urandom());
    u.rob_idx = rob_idx_t'(rnd(ROB_SIZE));
    return u;
  endfunction

  // allowed[i]：IQ が FU i に出してよい
  function automatic in_t gen_input(int cyc, logic allowed[2]);
    in_t x;
    int  fu;
    x.rst = cyc < 3 || rnd(5000) == 0;
    x.flush = rnd(300) == 0;
    x.upd = gen_br_update();
    x.rr = '0;
    fu = rnd(2);
    if (!allowed[fu]) fu = 1 - fu;
    x.rr.common.valid = allowed[fu] && rnd(4) != 0;
    x.rr.common.dest_fu = x.rr.common.valid ? dest_fu_t'(fu) : dest_fu_t'(rnd(4));
    x.rr.common.rs1_val = rnd_word();
    x.rr.common.rs2_val = rnd_word();
    x.rr.common.brmask = brmask_t'($urandom() & $urandom()) & ~x.upd.kill_mask & ~x.upd.resolve_mask;
    x.rr.common.rd = preg_t'{typ: PREG_TYPE_F, idx: preg_idx_t'(rnd(64))};
    x.rr.payload.fu_op = (fu == FU_FSQRT) ? FU_OP_FSQRT : FU_OP_FDIV;
    x.rr.payload.imm_type = (fu == FU_FSQRT) ? IMM_C : IMM_D;
    x.rr.payload.pc = pc_t'($urandom());
    x.rr.payload.rob_idx = rob_idx_t'(rnd(ROB_SIZE));
    return x;
  endfunction

  // ---------------- 実行と照合 ----------------

  int unsigned cycles;
  int unsigned seed;
  int          cyc;
  int          errors;
  in_t         cur;

  // このサイクルの始めの状態（そのサイクルの kill はまだ当てていない）
  ent_t fu_ent[2];
  ent_t hold_ent;

  // IQ の代わり
  logic allowed[2];
  logic blocked_prev[2];
  logic sent_prev[2];

  // 何を確かめたかの数
  int n_wb[2];
  int n_hold;
  int n_hold_killed;
  int n_abort[2];
  int n_issue[2];

  task automatic fail(string msg);
    errors++;
    if (errors <= MAX_ERRORS) $display("[cycle %0d] NG: %s", cyc, msg);
  endtask

  function automatic string ent_str(ent_t e);
    return $sformatf("%s rd=%h rob=%0d done_cyc=%0d", fu_name(e.fu), e.rd, e.rob_idx, e.done_cyc);
  endfunction

  function automatic ent_t apply_now(ent_t e);
    ent_t r;
    r = e;
    r.valid = e.valid && !cur.flush && !(|(e.brmask & cur.upd.kill_mask));
    r.brmask = e.brmask & ~cur.upd.resolve_mask;
    return r;
  endfunction

  ent_t n_fu[2];
  ent_t n_hold;
  logic done_now[2];

  task automatic check();
    ent_t w;
    logic exp_fsqrt_blocked;
    logic exp_fdiv_blocked;

    for (int i = 0; i < 2; i++) begin
      n_fu[i] = apply_now(fu_ent[i]);
      done_now[i] = n_fu[i].valid && n_fu[i].done_cyc == cyc;
      if (fu_ent[i].valid && !n_fu[i].valid) n_abort[i]++;
    end
    n_hold = apply_now(hold_ent);
    if (hold_ent.valid && !n_hold.valid) n_hold_killed++;

    if (n_hold.valid && (done_now[0] || done_now[1]))
      fail("待っている fdiv があるサイクルに演算が終わった（テストの前提が崩れている）");

    // 書き込むもの
    w.valid = 1'b0;
    if (n_hold.valid) w = n_hold;
    else if (done_now[FU_FSQRT]) w = n_fu[FU_FSQRT];
    else if (done_now[FU_FDIV]) w = n_fu[FU_FDIV];

    if (to_wb.valid !== w.valid) fail($sformatf("to_wb.valid=%b 期待 %b（%s）", to_wb.valid, w.valid, ent_str(w)));
    if (w.valid) begin
      n_wb[w.fu]++;
      if (to_wb.rd !== w.rd) fail($sformatf("to_wb.rd=%h 期待 %h（%s）", to_wb.rd, w.rd, ent_str(w)));
      if (to_wb.rob_idx !== w.rob_idx)
        fail($sformatf("to_wb.rob_idx=%0d 期待 %0d（%s）", to_wb.rob_idx, w.rob_idx, ent_str(w)));
      if (to_wb.value !== w.value) fail($sformatf("to_wb.value=%h 期待 %h（%s）", to_wb.value, w.value, ent_str(w)));
    end

    if (slow_wakeup.valid !== w.valid)
      fail($sformatf("slow_wakeup.valid=%b 期待 %b（%s）", slow_wakeup.valid, w.valid, ent_str(w)));
    if (w.valid) begin
      if (slow_wakeup.preg !== w.rd)
        fail($sformatf("slow_wakeup.preg=%h 期待 %h（%s）", slow_wakeup.preg, w.rd, ent_str(w)));
      if (slow_wakeup.latency !== LAT_FAST)
        fail($sformatf("slow_wakeup.latency=%0d 期待 %0d（%s）", slow_wakeup.latency, LAT_FAST, ent_str(w)));
    end

    exp_fsqrt_blocked = fu_ent[FU_FSQRT].valid;
    exp_fdiv_blocked = fu_ent[FU_FDIV].valid || hold_ent.valid;
    if (fsqrt_blocked !== exp_fsqrt_blocked)
      fail($sformatf("fsqrt_blocked=%b 期待 %b", fsqrt_blocked, exp_fsqrt_blocked));
    if (fdiv_blocked !== exp_fdiv_blocked)
      fail($sformatf("fdiv_blocked=%b 期待 %b（待っている fdiv %b）", fdiv_blocked, exp_fdiv_blocked, hold_ent.valid));
  endtask

  // 次のサイクルに進める
  task automatic advance();
    logic issued;
    if (cur.rst) begin
      for (int i = 0; i < 2; i++) fu_ent[i].valid = 1'b0;
      hold_ent.valid = 1'b0;
      return;
    end
    hold_ent.valid = 1'b0;
    if (done_now[FU_FSQRT] && done_now[FU_FDIV]) begin
      hold_ent = n_fu[FU_FDIV];
      n_hold++;
    end
    for (int i = 0; i < 2; i++) begin
      issued = cur.rr.common.valid && !cur.flush && cur.rr.common.dest_fu == dest_fu_t'(i);
      if (issued) begin
        n_issue[i]++;
        fu_ent[i].valid = 1'b1;
        fu_ent[i].fu = i;
        fu_ent[i].rd = cur.rr.common.rd;
        fu_ent[i].brmask = cur.rr.common.brmask;
        fu_ent[i].rob_idx = cur.rr.payload.rob_idx;
        if (i == FU_FSQRT) begin
          fu_ent[i].done_cyc = cyc + lat_fsqrt(cur.rr.common.rs1_val);
          fu_ent[i].value = m_fsqrt(cur.rr.common.rs1_val);
        end else begin
          fu_ent[i].done_cyc = cyc + lat_fdiv(cur.rr.common.rs1_val, cur.rr.common.rs2_val);
          fu_ent[i].value = m_fdiv(cur.rr.common.rs1_val, cur.rr.common.rs2_val);
        end
      end else begin
        fu_ent[i] = n_fu[i];
        if (done_now[i]) fu_ent[i].valid = 1'b0;
      end
    end
  endtask

  initial begin
    if (!$value$plusargs("cycles=%d", cycles)) cycles = 200000;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    $display("eu_4_top: seed=%0d cycles=%0d", seed, cycles);
    rst = 1'b1;
    flush = 1'b0;
    rr_ex = '0;
    br_update_ff = '0;
    cyc = 0;
    errors = 0;
    for (int i = 0; i < 2; i++) begin
      fu_ent[i].valid = 1'b0;
      blocked_prev[i] = 1'b1;
      sent_prev[i] = 1'b0;
    end
    hold_ent.valid = 1'b0;
  end

  // initial から直接 DUT の入力を書くと Verilator 5.020 の --timing で組み合わせ回路が
  // 評価し直されないことがあるので、always の中で入れる
  always @(negedge clk) begin
    for (int i = 0; i < 2; i++) allowed[i] = !blocked_prev[i] && !sent_prev[i];
    cur = gen_input(cyc, allowed);
    rst = cur.rst;
    flush = cur.flush;
    rr_ex = cur.rr;
    br_update_ff = cur.upd;
    #1;
    // 最初の数サイクルは DUT の FF が rst で揃うまで見ない
    if (cyc >= 3) begin
      check();
    end else begin
      for (int i = 0; i < 2; i++) done_now[i] = 1'b0;
    end
    advance();
    blocked_prev[FU_FSQRT] = fsqrt_blocked;
    blocked_prev[FU_FDIV] = fdiv_blocked;
    for (int i = 0; i < 2; i++) sent_prev[i] = cur.rr.common.valid && cur.rr.common.dest_fu == dest_fu_t'(i);
    cyc++;
    if (cyc >= cycles) begin
      if (dut.u_fu_0.u_fsqrt.n_protocol_error != 0)
        fail($sformatf("fsqrt の演算中に issued が来た（%0d 回）", dut.u_fu_0.u_fsqrt.n_protocol_error));
      if (dut.u_fu_1.u_fdiv.n_protocol_error != 0)
        fail($sformatf("fdiv の演算中に issued が来た（%0d 回）", dut.u_fu_1.u_fdiv.n_protocol_error));
      $display("issue  FSQRT %0d / FDIV %0d", n_issue[0], n_issue[1]);
      $display("書き込み FSQRT %0d / FDIV %0d", n_wb[0], n_wb[1]);
      $display("  同時に終わって fdiv を待たせた %0d（待っている間に消えた %0d）", n_hold, n_hold_killed);
      $display("  演算中に kill / flush（abort）FSQRT %0d / FDIV %0d", n_abort[0], n_abort[1]);
      if (errors == 0) $display("PASS");
      else $display("FAIL（%0d 件）", errors);
      $finish;
    end
  end

endmodule

`default_nettype wire
