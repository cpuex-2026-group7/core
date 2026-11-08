`timescale 1ns / 1ps
`default_nettype none

// eu_0_top（ALU の EU）のテストベンチ（Verilator の --binary --timing で動かす）
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
//   - to_wb.rd / rob_idx は前の rr_ex のもの。value は uop ごと（分岐は rd が NONE なので見ない）
//       ADD: rs1+rs2、ADDI: rs1+imm、SUB: rs1-rs2、JAL / JALR: pc+1（16bit で計算してゼロ拡張）
//       SRA: imm[5:0] を符号付きで見て、0 以上なら算術右シフト、負なら左シフト（-32 は 0）
//   - br_result.valid = valid && (条件分岐か JALR)。JAL は出さない
//       taken：BEQ / BNE / BLT / BGE は符号付き比較、JALR は 1
//       target：飛ぶなら JALR は rs1+imm、条件分岐は pc+imm（下位 16bit）、飛ばないなら pc+1
//       mispredict = target != 前の predict_pc
//       brmask = 前の brmask から今の resolve_mask のビットを落としたもの
//       tag / pc / rob_idx は前の rr_ex のもの

module tb_eu_0_top
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

  logic       rst;
  logic       flush;
  rr_ex_int_t rr_ex;
  word_t      imm;
  br_update_t br_update_ff;
  ex_wb_t     to_wb;
  br_result_t br_result;

  eu_0_top dut (
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

  // 境界の値を多めに出す
  function automatic word_t rnd_word();
    case (rnd(8))
      0: return 32'h0000_0000;
      1: return 32'hFFFF_FFFF;
      2: return 32'h8000_0000;
      3: return 32'h7FFF_FFFF;
      4: return word_t'(rnd(16));
      5: return -word_t'(rnd(16) + 1);
      default: return $urandom();
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

  // シフト量の下位 6bit（-32, -1, 0, 31 などを多めに）
  function automatic logic [5:0] rnd_shift();
    case (rnd(8))
      0: return 6'b100000;  // -32
      1: return 6'b111111;  // -1
      2: return 6'b000000;
      3: return 6'b011111;  // 31
      4: return 6'b000001;
      default: return 6'(rnd(64));
    endcase
  endfunction

  localparam int NOPS = 10;
  fu_op_t ops[NOPS] = '{FU_OP_BEQ, FU_OP_BNE, FU_OP_BLT, FU_OP_BGE, FU_OP_JAL, FU_OP_JALR,
                        FU_OP_ADD, FU_OP_ADDI, FU_OP_SUB, FU_OP_SRA};

  function automatic string op_name(fu_op_t op);
    case (op)
      FU_OP_BEQ:  return "BEQ";
      FU_OP_BNE:  return "BNE";
      FU_OP_BLT:  return "BLT";
      FU_OP_BGE:  return "BGE";
      FU_OP_JAL:  return "JAL";
      FU_OP_JALR: return "JALR";
      FU_OP_ADD:  return "ADD";
      FU_OP_ADDI: return "ADDI";
      FU_OP_SUB:  return "SUB";
      FU_OP_SRA:  return "SRA";
      default:    return "?";
    endcase
  endfunction

  function automatic logic is_cond_br(fu_op_t op);
    return op == FU_OP_BEQ || op == FU_OP_BNE || op == FU_OP_BLT || op == FU_OP_BGE;
  endfunction

  // ---------------- 参照モデル（DUT とは別の書き方で計算する） ----------------

  // 1bit ずつ組み立てる
  function automatic word_t ref_sra(word_t x, logic [5:0] sh);
    word_t r;
    int    s;
    s = sh[5] ? int'(sh) - 64 : int'(sh);
    for (int i = 0; i < 32; i++) begin
      if (s >= 0) r[i] = (i + s > 31) ? x[31] : x[i+s];
      else r[i] = (i + s < 0) ? 1'b0 : x[i+s];
    end
    return r;
  endfunction

  function automatic word_t ref_value(rr_ex_int_t r, word_t im);
    case (r.payload.fu_op)
      FU_OP_ADD:  return r.common.rs1_val + r.common.rs2_val;
      FU_OP_ADDI: return r.common.rs1_val + im;
      FU_OP_SUB:  return r.common.rs1_val - r.common.rs2_val;
      FU_OP_SRA:  return ref_sra(r.common.rs1_val, im[5:0]);
      default:    return 32'(pc_t'(r.payload.pc + 16'd1));  // JAL / JALR
    endcase
  endfunction

  function automatic logic ref_taken(rr_ex_int_t r);
    longint a, b;
    a = longint'($signed(r.common.rs1_val));
    b = longint'($signed(r.common.rs2_val));
    case (r.payload.fu_op)
      FU_OP_BEQ:  return a == b;
      FU_OP_BNE:  return a != b;
      FU_OP_BLT:  return a < b;
      FU_OP_BGE:  return a >= b;
      FU_OP_JAL,
      FU_OP_JALR: return 1'b1;
      default:    return 1'b0;
    endcase
  endfunction

  function automatic pc_t ref_target(rr_ex_int_t r, word_t im);
    if (!ref_taken(r)) return r.payload.pc + 16'd1;
    if (r.payload.fu_op == FU_OP_JALR) return pc_t'(r.common.rs1_val + im);
    return pc_t'(32'(r.payload.pc) + im);
  endfunction

  // ---------------- 入力を作る ----------------

  typedef struct {
    logic       rst;
    logic       flush;
    rr_ex_int_t rr;
    word_t      imm;
  } in_t;

  function automatic in_t gen_input(int cyc);
    in_t        x;
    fu_op_t     op;
    logic [5:0] sh;
    x.rst = cyc < 3 || rnd(2000) == 0;
    x.flush = rnd(50) == 0;
    x.rr = '0;
    op = ops[rnd(NOPS)];
    x.rr.common.valid = rnd(8) != 0;
    x.rr.common.rs1_val = rnd_word();
    x.rr.common.rs2_val = (rnd(4) == 0) ? x.rr.common.rs1_val : rnd_word();
    x.rr.common.dest_fu = FU_INT;
    x.rr.common.brmask = brmask_t'($urandom() & $urandom());
    if (is_cond_br(op)) x.rr.common.rd = preg_t'{typ: PREG_TYPE_NONE, idx: '0};
    else x.rr.common.rd = preg_t'{typ: PREG_TYPE_I, idx: preg_idx_t'(rnd(64))};
    x.rr.payload.fu_op = op;
    x.rr.payload.pc = rnd_pc();
    x.rr.payload.ftq_idx = ftq_idx_t'(rnd(32));
    x.rr.payload.rob_idx = rob_idx_t'(rnd(ROB_SIZE));
    x.rr.payload.br_tag = br_tag_t'(rnd(MAX_BR));
    case (op)
      FU_OP_JAL: x.rr.payload.imm_type = IMM_B;
      FU_OP_ADD, FU_OP_SUB: x.rr.payload.imm_type = IMM_D;
      default: x.rr.payload.imm_type = is_cond_br(op) ? IMM_D : IMM_C;
    endcase
    if (op == FU_OP_SRA) begin
      sh = rnd_shift();
      x.imm = {{26{sh[5]}}, sh};
    end else begin
      x.imm = (rnd(2) == 0) ? word_t'(rnd(64)) - 32'd32 : rnd_word();
    end
    // 半分は正しい予測にする
    x.rr.payload.predict_pc = (rnd(2) == 0) ? ref_target(x.rr, x.imm) : rnd_pc();
    return x;
  endfunction

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
  int n_mispredict[2];
  int n_exit_kill;
  int n_exit_flush;

  task automatic fail(string msg);
    errors++;
    if (errors <= MAX_ERRORS) $display("[cycle %0d] NG: %s", cyc, msg);
  endtask

  task automatic check();
    logic       exp_valid;
    logic       exp_br;
    word_t      exp_value;
    logic       exp_taken;
    pc_t        exp_target;
    logic       exp_mispredict;
    brmask_t    exp_brmask;
    rr_ex_int_t p;
    string      tag;

    p = prev.rr;
    tag = $sformatf("%s rs1=%h rs2=%h imm=%h pc=%h", op_name(p.payload.fu_op), p.common.rs1_val, p.common.rs2_val,
                    prev.imm, p.payload.pc);

    exp_valid = p.common.valid && !prev.rst && !prev.flush && !cur.flush
                && !(|(p.common.brmask & br_update_ff.kill_mask));
    exp_br = exp_valid && (is_cond_br(p.payload.fu_op) || p.payload.fu_op == FU_OP_JALR);

    if (p.common.valid && !prev.rst && !prev.flush) begin
      if (cur.flush) n_exit_flush++;
      else if (|(p.common.brmask & br_update_ff.kill_mask)) n_exit_kill++;
    end

    if (to_wb.valid !== exp_valid) fail($sformatf("to_wb.valid=%b 期待 %b（%s）", to_wb.valid, exp_valid, tag));
    if (br_result.valid !== exp_br) fail($sformatf("br_result.valid=%b 期待 %b（%s）", br_result.valid, exp_br, tag));
    if (!exp_valid) return;

    n_check++;
    for (int i = 0; i < NOPS; i++) if (ops[i] == p.payload.fu_op) n_op[i]++;

    if (to_wb.rd !== p.common.rd) fail($sformatf("to_wb.rd=%h 期待 %h（%s）", to_wb.rd, p.common.rd, tag));
    if (to_wb.rob_idx !== p.payload.rob_idx)
      fail($sformatf("to_wb.rob_idx=%0d 期待 %0d（%s）", to_wb.rob_idx, p.payload.rob_idx, tag));
    if (!is_cond_br(p.payload.fu_op)) begin
      exp_value = ref_value(p, prev.imm);
      if (to_wb.value !== exp_value) fail($sformatf("to_wb.value=%h 期待 %h（%s）", to_wb.value, exp_value, tag));
    end

    if (!exp_br) return;

    exp_taken = ref_taken(p);
    exp_target = ref_target(p, prev.imm);
    exp_mispredict = exp_target != p.payload.predict_pc;
    exp_brmask = p.common.brmask & ~br_update_ff.resolve_mask;
    n_mispredict[exp_mispredict]++;

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
                     br_update_ff.resolve_mask, tag));
    if (br_result.pc !== p.payload.pc) fail($sformatf("br_result.pc=%h 期待 %h（%s）", br_result.pc, p.payload.pc, tag));
    if (br_result.rob_idx !== p.payload.rob_idx)
      fail($sformatf("br_result.rob_idx=%0d 期待 %0d（%s）", br_result.rob_idx, p.payload.rob_idx, tag));
  endtask

  initial begin
    if (!$value$plusargs("cycles=%d", cycles)) cycles = 200000;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    $display("eu_0_top: seed=%0d cycles=%0d", seed, cycles);
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
    br_update_ff = gen_br_update();
    #1;
    if (have_prev) check();
    prev = cur;
    have_prev = 1'b1;
    cyc++;
    if (cyc >= cycles) begin
      $display("確かめた命令 %0d", n_check);
      for (int i = 0; i < NOPS; i++) $display("  %-5s %0d", op_name(ops[i]), n_op[i]);
      $display("  mispredict あり %0d / なし %0d", n_mispredict[1], n_mispredict[0]);
      $display("  出口で kill %0d / flush %0d", n_exit_kill, n_exit_flush);
      if (errors == 0) $display("PASS");
      else $display("FAIL（%0d 件）", errors);
      $finish;
    end
  end

endmodule

`default_nettype wire
