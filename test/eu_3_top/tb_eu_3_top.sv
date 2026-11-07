`timescale 1ns / 1ps
`default_nettype none

// eu_3_top（F長 の EU）のテストベンチ（Verilator の --binary --timing で動かす）
//
// 実行時オプション
//   +cycles=N  ランダムテストのサイクル数（既定 200000）
//   +seed=N    乱数の種（既定 1）
//
// 演算器（fmul / itof / ftoi / fadd）は models/ の代わりを使う。値は eu_3_model_pkg の m_* で、
// float の計算ではない。ここで確かめるのは EU の段数・mux・バイパス・kill だけ。
//
// negedge で次のサイクルの入力（rr_ex / br_update_ff / flush / rst）を入れ、1ns 待ってから出力を見る。
//
// テストの前提にしている仕様（rr_ex がサイクル t に来たとする）
//   - FU の段数 S（入口の FF から結果が出るまで）は fmul が LAT_FMUL+1、itof / ftoi が LAT_ITOF+1、
//     fadd / fsub が LAT_FADD+1。結果はサイクル t+S に出る
//   - 書き込みは一番遅い fadd に揃えて、どの命令もサイクル t+LAT_FADD+1 に to_wb に出る
//   - サイクル t+1 で生きている条件：rr_ex.valid && !t の rst && !t の flush
//     その後の各サイクル k で、k の flush か「その時点の brmask & k の kill_mask」で消える。
//     k の rst で次のサイクルから全部消える。brmask は各サイクルの resolve_mask でビットを落とす
//   - to_wb は書き込みのサイクルの kill / flush まで当てたもの
//   - バイパスはサイクル t+1+s（s = 1, 2）の段から出す。その段に入るまでの kill は当たっていて、
//     そのサイクルの kill は当てない。その段で結果が出ている（S-1 <= s）命令だけ出す
//       bypass_f[s-1]：rd が F のもの（s=1 は fmul、s=2 は fmul と itof）
//       bypass_i[0]  ：s=2 で rd が I のもの（ftoi）
//   - rr_ex は RR で今の br_update を当てた後のものなので、brmask は今の kill_mask / resolve_mask と重ねない

module tb_eu_3_top
  import types::*;
  import isa::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import iq_types::*;
  import rr_types::*;
  import ex_types::*;
  import eu_3_model_pkg::*;
();

  localparam int MAX_ERRORS = 30;
  localparam int WB_STAGE = LAT_FADD;  // 書き込みの段（入口の FF の次のサイクルを 0 段目とする）

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic         rst;
  logic         flush;
  rr_ex_float_t rr_ex;
  br_update_t   br_update_ff;
  ex_wb_t       to_wb;
  bypass_t      bypass_f[2];
  bypass_t      bypass_i[1];

  eu_3_top dut (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .rr_ex(rr_ex),
    .br_update_ff(br_update_ff),
    .to_wb(to_wb),
    .bypass_f(bypass_f),
    .bypass_i(bypass_i)
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

  localparam int NOPS = 5;
  typedef enum int {OP_FMUL, OP_ITOF, OP_FTOI, OP_FADD, OP_FSUB} op_t;

  function automatic string op_name(int op);
    case (op)
      OP_FMUL: return "FMUL";
      OP_ITOF: return "ITOF";
      OP_FTOI: return "FTOI";
      OP_FADD: return "FADD";
      default: return "FSUB";
    endcase
  endfunction

  // ---------------- 命令の記録と参照モデル ----------------

  typedef struct {
    logic     valid;
    int       op;
    preg_t    rd;
    brmask_t  brmask;
    rob_idx_t rob_idx;
    word_t    rs1;
    word_t    rs2;
  } ent_t;

  function automatic int fu_stages(int op);
    case (op)
      OP_FMUL:          return LAT_FMUL + 1;
      OP_ITOF, OP_FTOI: return LAT_ITOF + 1;
      default:          return LAT_FADD + 1;
    endcase
  endfunction

  function automatic word_t ref_value(ent_t e);
    case (e.op)
      OP_FMUL: return m_fmul(e.rs1, e.rs2);
      OP_ITOF: return m_itof(e.rs1);
      OP_FTOI: return m_ftoi(e.rs1);
      OP_FADD: return m_fadd(e.rs1, e.rs2, 1'b0);
      default: return m_fadd(e.rs1, e.rs2, 1'b1);
    endcase
  endfunction

  // ---------------- 入力を作る ----------------

  typedef struct {
    logic         rst;
    logic         flush;
    rr_ex_float_t rr;
    int           op;
    br_update_t   upd;
  } in_t;

  function automatic br_update_t gen_br_update();
    br_update_t u;
    u = '0;
    if (rnd(6) == 0) u.kill_mask[rnd(MAX_BR)] = 1'b1;
    if (rnd(3) == 0) u.resolve_mask = brmask_t'($urandom() & $urandom());
    u.resolve_mask &= ~u.kill_mask;
    u.mispredict = |u.kill_mask;
    u.tag = br_tag_t'(rnd(MAX_BR));
    u.pc = pc_t'($urandom());
    u.target = pc_t'($urandom());
    u.rob_idx = rob_idx_t'(rnd(ROB_SIZE));
    return u;
  endfunction

  function automatic in_t gen_input(int cyc);
    in_t x;
    x.rst = cyc < 3 || rnd(2000) == 0;
    x.flush = rnd(50) == 0;
    x.upd = gen_br_update();
    x.rr = '0;
    x.op = rnd(NOPS);
    x.rr.common.valid = rnd(8) != 0;
    x.rr.common.rs1_val = rnd_word();
    x.rr.common.rs2_val = rnd_word();
    x.rr.common.brmask = brmask_t'($urandom() & $urandom()) & ~x.upd.kill_mask & ~x.upd.resolve_mask;
    x.rr.common.rd = preg_t'{typ: (x.op == OP_FTOI) ? PREG_TYPE_I : PREG_TYPE_F, idx: preg_idx_t'(rnd(64))};
    case (x.op)
      OP_FMUL: begin
        x.rr.common.dest_fu = FU_FMUL;
        x.rr.payload.fu_op = FU_OP_FMUL;
      end
      OP_ITOF: begin
        x.rr.common.dest_fu = FU_FCVT;
        x.rr.payload.fu_op = FU_OP_ITOF;
      end
      OP_FTOI: begin
        x.rr.common.dest_fu = FU_FCVT;
        x.rr.payload.fu_op = FU_OP_FTOI;
      end
      OP_FADD: begin
        x.rr.common.dest_fu = FU_FADD;
        x.rr.payload.fu_op = FU_OP_FADD;
      end
      default: begin
        x.rr.common.dest_fu = FU_FADD;
        x.rr.payload.fu_op = FU_OP_FSUB;
      end
    endcase
    x.rr.payload.imm_type = (x.op == OP_ITOF || x.op == OP_FTOI) ? IMM_C : IMM_D;
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

  // pipe[s] はこのサイクルに s 段目にいる命令（そのサイクルの kill はまだ当てていない）
  ent_t pipe[WB_STAGE+1];

  // 何を確かめたかの数
  int n_wb;
  int n_op[NOPS];
  int n_bypass_f[2];
  int n_bypass_i;
  int n_inflight_kill;
  int n_inflight_flush;

  task automatic fail(string msg);
    errors++;
    if (errors <= MAX_ERRORS) $display("[cycle %0d] NG: %s", cyc, msg);
  endtask

  function automatic string ent_str(ent_t e);
    return $sformatf("%s rd=%h rob=%0d rs1=%h rs2=%h", op_name(e.op), e.rd, e.rob_idx, e.rs1, e.rs2);
  endfunction

  task automatic check_bypass(string name, bypass_t b, logic exp_valid, ent_t e);
    word_t v;
    if (b.valid !== exp_valid) begin
      fail($sformatf("%s.valid=%b 期待 %b（%s）", name, b.valid, exp_valid, ent_str(e)));
      return;
    end
    if (!exp_valid) return;
    v = ref_value(e);
    if (b.rd !== e.rd) fail($sformatf("%s.rd=%h 期待 %h（%s）", name, b.rd, e.rd, ent_str(e)));
    if (b.value !== v) fail($sformatf("%s.value=%h 期待 %h（%s）", name, b.value, v, ent_str(e)));
  endtask

  // このサイクルの kill / flush を当てたもの
  function automatic ent_t apply_now(ent_t e);
    ent_t r;
    r = e;
    r.valid = e.valid && !cur.flush && !(|(e.brmask & cur.upd.kill_mask));
    r.brmask = e.brmask & ~cur.upd.resolve_mask;
    return r;
  endfunction

  task automatic check();
    ent_t  w;
    ent_t  e;
    word_t v;
    logic  ok;

    // 書き込み
    w = apply_now(pipe[WB_STAGE]);
    if (to_wb.valid !== w.valid) fail($sformatf("to_wb.valid=%b 期待 %b（%s）", to_wb.valid, w.valid, ent_str(w)));
    if (w.valid) begin
      n_wb++;
      n_op[w.op]++;
      v = ref_value(w);
      if (to_wb.rd !== w.rd) fail($sformatf("to_wb.rd=%h 期待 %h（%s）", to_wb.rd, w.rd, ent_str(w)));
      if (to_wb.rob_idx !== w.rob_idx)
        fail($sformatf("to_wb.rob_idx=%0d 期待 %0d（%s）", to_wb.rob_idx, w.rob_idx, ent_str(w)));
      if (to_wb.value !== v) fail($sformatf("to_wb.value=%h 期待 %h（%s）", to_wb.value, v, ent_str(w)));
    end

    // バイパス（このサイクルの kill は当てない）
    for (int s = 1; s <= 2; s++) begin
      e = pipe[s];
      ok = e.valid && fu_stages(e.op) - 1 <= s && e.rd.typ == PREG_TYPE_F;
      if (ok) n_bypass_f[s-1]++;
      check_bypass($sformatf("bypass_f[%0d]", s - 1), bypass_f[s-1], ok, e);
    end
    e = pipe[2];
    ok = e.valid && fu_stages(e.op) - 1 <= 2 && e.rd.typ == PREG_TYPE_I;
    if (ok) n_bypass_i++;
    check_bypass("bypass_i[0]", bypass_i[0], ok, e);

    // 途中で消えた数
    for (int s = 0; s <= WB_STAGE; s++) begin
      if (pipe[s].valid) begin
        if (cur.flush) n_inflight_flush++;
        else if (|(pipe[s].brmask & cur.upd.kill_mask)) n_inflight_kill++;
      end
    end
  endtask

  // 次のサイクルに進める
  task automatic advance();
    if (cur.rst) begin
      for (int s = 0; s <= WB_STAGE; s++) pipe[s].valid = 1'b0;
      return;
    end
    for (int s = WB_STAGE; s >= 1; s--) pipe[s] = apply_now(pipe[s-1]);
    pipe[0].valid = cur.rr.common.valid && !cur.flush;
    pipe[0].op = cur.op;
    pipe[0].rd = cur.rr.common.rd;
    pipe[0].brmask = cur.rr.common.brmask;
    pipe[0].rob_idx = cur.rr.payload.rob_idx;
    pipe[0].rs1 = cur.rr.common.rs1_val;
    pipe[0].rs2 = cur.rr.common.rs2_val;
  endtask

  initial begin
    if (!$value$plusargs("cycles=%d", cycles)) cycles = 200000;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    $display("eu_3_top: seed=%0d cycles=%0d", seed, cycles);
    rst = 1'b1;
    flush = 1'b0;
    rr_ex = '0;
    br_update_ff = '0;
    cyc = 0;
    errors = 0;
    for (int s = 0; s <= WB_STAGE; s++) pipe[s].valid = 1'b0;
  end

  // initial から直接 DUT の入力を書くと Verilator 5.020 の --timing で組み合わせ回路が
  // 評価し直されないことがあるので、always の中で入れる
  always @(negedge clk) begin
    cur = gen_input(cyc);
    rst = cur.rst;
    flush = cur.flush;
    rr_ex = cur.rr;
    br_update_ff = cur.upd;
    #1;
    // 最初の数サイクルは DUT の FF が rst で揃うまで見ない
    if (cyc >= 3) check();
    advance();
    cyc++;
    if (cyc >= cycles) begin
      $display("書き込みを確かめた命令 %0d", n_wb);
      for (int i = 0; i < NOPS; i++) $display("  %-5s %0d", op_name(i), n_op[i]);
      $display("  バイパス bypass_f[0] %0d / bypass_f[1] %0d / bypass_i[0] %0d", n_bypass_f[0], n_bypass_f[1],
               n_bypass_i);
      $display("  途中で kill %0d / flush %0d（段ごとに数えたもの）", n_inflight_kill, n_inflight_flush);
      if (errors == 0) $display("PASS");
      else $display("FAIL（%0d 件）", errors);
      $finish;
    end
  end

endmodule

`default_nettype wire
