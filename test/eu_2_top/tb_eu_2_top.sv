`timescale 1ns / 1ps
`default_nettype none

// eu_2_top（F短 の EU）のテストベンチ（Verilator の --binary --timing で動かす）
//
// 実行時オプション
//   +cycles=N  ランダムテストのサイクル数（既定 200000）
//   +seed=N    乱数の種（既定 1）
//
// negedge で次のサイクルの入力（rr_ex / imm / br_update_ff / flush / rst）を入れ、1ns 待ってから出力を見る。
// このとき出力は「1 サイクル前の入力」の結果に「今の br_update_ff / flush」を当てたものになっているはず。
//
// テストの前提にしている仕様
//   - レイテンシは 1。入力の次のサイクルに to_wb / br_result が組み合わせで出る
//   - valid = 前のサイクルの rr_ex.valid && !前の rst && !前の flush && !今の flush
//             && 前の brmask が今の kill_mask に当たらない
//   - rr_ex は RR で今の br_update を当てた後のものなので、brmask は今の kill_mask / resolve_mask と重ねない
//   - to_wb.rd / rob_idx は前の rr_ex のもの。value は uop ごと（分岐は rd が NONE なので見ない）
//       FLI：imm（A 形式で拡張済みの {instr[19:0], 12'b0}）
//       FCSIGN：imm の下位 2bit で 00 そのまま / 01 符号反転 / 10 符号を 0 / 11 符号を 1
//       FLHI：imm の下位 5bit を index にした定数表（.claude/isa.md の表）。14〜31 は 0
//   - br_result.valid = valid && 分岐（fu_op[3:2] == 00）
//       taken：IEEE の比較。+0 と -0 は等しい。NaN は入れない（扱いが決まっていないので）
//         FBEQ: a == b、FBNE: !(a == b)、FBLT: a < b、FBGE: !(a < b)
//       target：飛ぶなら pc+imm（下位 16bit）、飛ばないなら pc+1
//       mispredict = target != 前の predict_pc
//       brmask = 前の brmask から今の resolve_mask のビットを落としたもの
//       tag / pc / rob_idx は前の rr_ex のもの

module tb_eu_2_top
  import types::*;
  import isa::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import iq_types::*;
  import rr_types::*;
  import ex_types::*;
();

  localparam int MAX_ERRORS = 30;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic         rst;
  logic         flush;
  rr_ex_float_t rr_ex;
  word_t        imm;
  br_update_t   br_update_ff;
  ex_wb_t       to_wb;
  br_result_t   br_result;

  eu_2_top dut (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .rr_ex(rr_ex),
    .imm(imm),
    .br_update_ff(br_update_ff),
    .to_wb(to_wb),
    .br_result(br_result)
  );

  // ---------------- 乱数 ----------------

  function automatic int unsigned rnd(int unsigned n);
    return $urandom_range(n - 1, 0);
  endfunction

  // NaN 以外の float。±0、±inf、±1、非正規化数を多めに出す
  function automatic word_t rnd_float();
    word_t f;
    case (rnd(10))
      0: return 32'h0000_0000;
      1: return 32'h8000_0000;
      2: return 32'h7F80_0000;
      3: return 32'hFF80_0000;
      4: return 32'h3F80_0000;
      5: return 32'hBF80_0000;
      6: return {1'(rnd(2)), 8'h00, 23'($urandom())};
      default: begin
        f = $urandom();
        if (f[30:23] == 8'hFF) f[30:23] = 8'hFE;
        return f;
      end
    endcase
  endfunction

  // rs1 と関係のある値を多めに出す（同じ値、符号だけ違う値、1 ulp 違う値）
  function automatic word_t rnd_float_near(word_t a);
    word_t f;
    case (rnd(8))
      0, 1: return a;
      2: return {~a[31], a[30:0]};
      3: begin
        f = a + 32'd1;
        return (f[30:23] == 8'hFF && f[22:0] != 0) ? a : f;
      end
      4: return (a[30:0] == 0) ? a : a - 32'd1;
      default: return rnd_float();
    endcase
  endfunction

  function automatic pc_t rnd_pc();
    case (rnd(6))
      0: return 16'h0000;
      1: return 16'hFFFF;
      2: return 16'h7FFF;
      default: return pc_t'($urandom());
    endcase
  endfunction

  localparam int NOPS = 7;
  fu_op_t ops[NOPS] = '{FU_OP_FBEQ, FU_OP_FBNE, FU_OP_FBLT, FU_OP_FBGE, FU_OP_FLI, FU_OP_FLHI, FU_OP_FCSIGN};

  function automatic string op_name(fu_op_t op);
    case (op)
      FU_OP_FBEQ:   return "FBEQ";
      FU_OP_FBNE:   return "FBNE";
      FU_OP_FBLT:   return "FBLT";
      FU_OP_FBGE:   return "FBGE";
      FU_OP_FLI:    return "FLI";
      FU_OP_FLHI:   return "FLHI";
      FU_OP_FCSIGN: return "FCSIGN";
      default:      return "?";
    endcase
  endfunction

  function automatic logic is_br(fu_op_t op);
    return op == FU_OP_FBEQ || op == FU_OP_FBNE || op == FU_OP_FBLT || op == FU_OP_FBGE;
  endfunction

  // ---------------- 参照モデル（DUT とは別の書き方で計算する） ----------------

  function automatic logic is_zero(word_t a);
    return a[30:0] == 31'd0;
  endfunction

  function automatic logic ref_feq(word_t a, word_t b);
    if (is_zero(a) && is_zero(b)) return 1'b1;
    return a == b;
  endfunction

  // 符号と絶対値に分けて比べる
  function automatic logic ref_flt(word_t a, word_t b);
    if (is_zero(a) && is_zero(b)) return 1'b0;
    if (a[31] != b[31]) return a[31];
    if (!a[31]) return a[30:0] < b[30:0];
    return a[30:0] > b[30:0];
  endfunction

  function automatic logic ref_taken(rr_ex_float_t r);
    case (r.payload.fu_op)
      FU_OP_FBEQ: return ref_feq(r.common.rs1_val, r.common.rs2_val);
      FU_OP_FBNE: return !ref_feq(r.common.rs1_val, r.common.rs2_val);
      FU_OP_FBLT: return ref_flt(r.common.rs1_val, r.common.rs2_val);
      FU_OP_FBGE: return !ref_flt(r.common.rs1_val, r.common.rs2_val);
      default:    return 1'b0;
    endcase
  endfunction

  function automatic pc_t ref_target(rr_ex_float_t r, word_t im);
    if (!ref_taken(r)) return r.payload.pc + 16'd1;
    return pc_t'(32'(r.payload.pc) + im);
  endfunction

  // real（倍精度）を binary32 に最近接偶数丸めで直す。正規化数の範囲だけ考える
  // shortreal は Verilator で使えないので自分でやる
  function automatic word_t to_f32(real v);
    logic [63:0] d;
    logic [7:0]  e;
    logic [28:0] rest;
    logic        up;
    d = $realtobits(v);
    e = 8'(int'(d[62:52]) - 1023 + 127);
    rest = d[28:0];
    up = rest > 29'h1000_0000 || (rest == 29'h1000_0000 && d[29]);
    return {d[63], e, d[51:29]} + 32'(up);
  endfunction

  // flhi の定数表（10 進の値から binary32 を作る）
  function automatic word_t ref_flhi(logic [4:0] ind);
    case (ind)
      5'd0: return to_f32(-0.2);
      5'd1: return to_f32(-0.1);
      5'd2: return to_f32(1.0e-4);
      5'd3: return to_f32(0.01);
      5'd4: return to_f32(0.017453293);
      5'd5: return to_f32(0.05);
      5'd6: return to_f32(0.1);
      5'd7: return to_f32(0.15);
      5'd8: return to_f32(0.2);
      5'd9: return to_f32(0.3);
      5'd10: return to_f32(0.9);
      5'd11: return to_f32(3.1415927);
      5'd12: return to_f32(1.0e8);
      5'd13: return to_f32(1.0e9);
      default: return 32'h0;
    endcase
  endfunction

  function automatic word_t ref_value(rr_ex_float_t r, word_t im);
    word_t a;
    a = r.common.rs1_val;
    case (r.payload.fu_op)
      FU_OP_FLI: return im;
      FU_OP_FLHI: return ref_flhi(im[4:0]);
      default: begin  // FCSIGN
        case (im[1:0])
          2'b00:   return a;
          2'b01:   return {~a[31], a[30:0]};
          2'b10:   return {1'b0, a[30:0]};
          default: return {1'b1, a[30:0]};
        endcase
      end
    endcase
  endfunction

  // ---------------- 入力を作る ----------------

  typedef struct {
    logic         rst;
    logic         flush;
    rr_ex_float_t rr;
    word_t        imm;
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
    u.pc = rnd_pc();
    u.target = rnd_pc();
    u.rob_idx = rob_idx_t'(rnd(ROB_SIZE));
    return u;
  endfunction

  function automatic in_t gen_input(int cyc);
    in_t         x;
    fu_op_t      op;
    logic [19:0] r20;
    logic [14:0] r15;
    x.rst = cyc < 3 || rnd(2000) == 0;
    x.flush = rnd(50) == 0;
    x.upd = gen_br_update();
    x.rr = '0;
    op = ops[rnd(NOPS)];
    x.rr.common.valid = rnd(8) != 0;
    x.rr.common.rs1_val = rnd_float();
    x.rr.common.rs2_val = rnd_float_near(x.rr.common.rs1_val);
    x.rr.common.dest_fu = FU_F_SHORT;
    x.rr.common.brmask = brmask_t'($urandom() & $urandom()) & ~x.upd.kill_mask & ~x.upd.resolve_mask;
    if (is_br(op)) x.rr.common.rd = preg_t'{typ: PREG_TYPE_NONE, idx: '0};
    else x.rr.common.rd = preg_t'{typ: PREG_TYPE_F, idx: preg_idx_t'(rnd(64))};
    x.rr.payload.fu_op = op;
    x.rr.payload.pc = rnd_pc();
    x.rr.payload.ftq_idx = ftq_idx_t'(rnd(32));
    x.rr.payload.rob_idx = rob_idx_t'(rnd(ROB_SIZE));
    x.rr.payload.br_tag = br_tag_t'(rnd(MAX_BR));
    r20 = 20'($urandom());
    r15 = 15'($urandom());
    if (rnd(2) == 0) r15 = 15'(rnd(64)) - 15'd32;
    // ex_top が imm_type で拡張した形で渡す
    case (op)
      FU_OP_FLI: begin
        x.rr.payload.imm_type = IMM_A;
        x.imm = {r20, 12'b0};
      end
      FU_OP_FLHI: begin
        x.rr.payload.imm_type = IMM_B;
        // 表の中（0〜13）を多めにする
        if (rnd(4) != 0) r20 = 20'(rnd(14));
        x.imm = {{12{r20[19]}}, r20};
      end
      FU_OP_FCSIGN: begin
        x.rr.payload.imm_type = IMM_C;
        x.imm = {{17{r15[14]}}, r15};
      end
      default: begin
        x.rr.payload.imm_type = IMM_D;
        x.imm = {{17{r15[14]}}, r15};
      end
    endcase
    x.rr.payload.imm = r20;
    // 半分は正しい予測にする
    x.rr.payload.predict_pc = (rnd(2) == 0) ? ref_target(x.rr, x.imm) : rnd_pc();
    return x;
  endfunction

  // ---------------- 実行と照合 ----------------

  int unsigned cycles;
  int unsigned seed;
  int          cyc;
  int          errors;
  logic        have_prev;
  in_t         prev;
  in_t         cur;

  // 何を確かめたかの数
  int n_check;
  int n_op[NOPS];
  int n_taken[2];
  int n_mispredict[2];
  int n_zero_pair;
  int n_exit_kill;
  int n_exit_flush;

  task automatic fail(string msg);
    errors++;
    if (errors <= MAX_ERRORS) $display("[cycle %0d] NG: %s", cyc, msg);
  endtask

  task automatic check();
    logic         exp_valid;
    logic         exp_br;
    word_t        exp_value;
    logic         exp_taken;
    pc_t          exp_target;
    logic         exp_mispredict;
    brmask_t      exp_brmask;
    rr_ex_float_t p;
    string        tag;

    p = prev.rr;
    tag = $sformatf("%s rs1=%h rs2=%h imm=%h pc=%h", op_name(p.payload.fu_op), p.common.rs1_val, p.common.rs2_val,
                    prev.imm, p.payload.pc);

    exp_valid = p.common.valid && !prev.rst && !prev.flush && !cur.flush
                && !(|(p.common.brmask & cur.upd.kill_mask));
    exp_br = exp_valid && is_br(p.payload.fu_op);

    if (p.common.valid && !prev.rst && !prev.flush) begin
      if (cur.flush) n_exit_flush++;
      else if (|(p.common.brmask & cur.upd.kill_mask)) n_exit_kill++;
    end

    if (to_wb.valid !== exp_valid) fail($sformatf("to_wb.valid=%b 期待 %b（%s）", to_wb.valid, exp_valid, tag));
    if (br_result.valid !== exp_br) fail($sformatf("br_result.valid=%b 期待 %b（%s）", br_result.valid, exp_br, tag));
    if (!exp_valid) return;

    n_check++;
    for (int i = 0; i < NOPS; i++) if (ops[i] == p.payload.fu_op) n_op[i]++;

    if (to_wb.rd !== p.common.rd) fail($sformatf("to_wb.rd=%h 期待 %h（%s）", to_wb.rd, p.common.rd, tag));
    if (to_wb.rob_idx !== p.payload.rob_idx)
      fail($sformatf("to_wb.rob_idx=%0d 期待 %0d（%s）", to_wb.rob_idx, p.payload.rob_idx, tag));
    if (!is_br(p.payload.fu_op)) begin
      exp_value = ref_value(p, prev.imm);
      if (to_wb.value !== exp_value) fail($sformatf("to_wb.value=%h 期待 %h（%s）", to_wb.value, exp_value, tag));
    end

    if (!exp_br) return;

    exp_taken = ref_taken(p);
    exp_target = ref_target(p, prev.imm);
    exp_mispredict = exp_target != p.payload.predict_pc;
    exp_brmask = p.common.brmask & ~cur.upd.resolve_mask;
    n_taken[exp_taken]++;
    n_mispredict[exp_mispredict]++;
    if (is_zero(p.common.rs1_val) && is_zero(p.common.rs2_val) && p.common.rs1_val != p.common.rs2_val) n_zero_pair++;

    if (br_result.taken !== exp_taken) fail($sformatf("br_result.taken=%b 期待 %b（%s）", br_result.taken, exp_taken, tag));
    if (br_result.target !== exp_target)
      fail($sformatf("br_result.target=%h 期待 %h（%s）", br_result.target, exp_target, tag));
    if (br_result.mispredict !== exp_mispredict)
      fail($sformatf("br_result.mispredict=%b 期待 %b（predict_pc=%h、%s）", br_result.mispredict, exp_mispredict,
                     p.payload.predict_pc, tag));
    if (br_result.tag !== p.payload.br_tag)
      fail($sformatf("br_result.tag=%0d 期待 %0d（%s）", br_result.tag, p.payload.br_tag, tag));
    if (br_result.brmask !== exp_brmask)
      fail($sformatf("br_result.brmask=%b 期待 %b（resolve_mask=%b、%s）", br_result.brmask, exp_brmask,
                     cur.upd.resolve_mask, tag));
    if (br_result.pc !== p.payload.pc) fail($sformatf("br_result.pc=%h 期待 %h（%s）", br_result.pc, p.payload.pc, tag));
    if (br_result.rob_idx !== p.payload.rob_idx)
      fail($sformatf("br_result.rob_idx=%0d 期待 %0d（%s）", br_result.rob_idx, p.payload.rob_idx, tag));
  endtask

  initial begin
    if (!$value$plusargs("cycles=%d", cycles)) cycles = 200000;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    $display("eu_2_top: seed=%0d cycles=%0d", seed, cycles);
    rst = 1'b1;
    flush = 1'b0;
    rr_ex = '0;
    imm = '0;
    br_update_ff = '0;
    cyc = 0;
    errors = 0;
    have_prev = 1'b0;
  end

  // initial から直接 DUT の入力を書くと Verilator 5.020 の --timing で組み合わせ回路が
  // 評価し直されないことがあるので、always の中で入れる
  always @(negedge clk) begin
    cur = gen_input(cyc);
    rst = cur.rst;
    flush = cur.flush;
    rr_ex = cur.rr;
    imm = cur.imm;
    br_update_ff = cur.upd;
    #1;
    if (have_prev) check();
    prev = cur;
    have_prev = 1'b1;
    cyc++;
    if (cyc >= cycles) begin
      $display("確かめた命令 %0d", n_check);
      for (int i = 0; i < NOPS; i++) $display("  %-6s %0d", op_name(ops[i]), n_op[i]);
      $display("  taken %0d / not taken %0d", n_taken[1], n_taken[0]);
      $display("  mispredict あり %0d / なし %0d", n_mispredict[1], n_mispredict[0]);
      $display("  +0 と -0 の比較 %0d", n_zero_pair);
      $display("  出口で kill %0d / flush %0d", n_exit_kill, n_exit_flush);
      if (errors == 0) $display("PASS");
      else $display("FAIL（%0d 件）", errors);
      $finish;
    end
  end

endmodule

`default_nettype wire
