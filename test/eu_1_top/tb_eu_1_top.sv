`timescale 1ns / 1ps
`default_nettype none

// eu_1_top（MEM の EU）のテストベンチ（Verilator の --binary --timing で動かす）
//
// 実行時オプション
//   +cycles=N  ランダムテストのサイクル数（既定 200000）
//   +seed=N    乱数の種（既定 1）
//
// negedge で次のサイクルの入力（rr_ex / imm / br_update_ff / flush / rst）を入れ、1ns 待ってから出力を見る。
// このとき出力は「1 サイクル前の入力」の結果に「今の br_update_ff / flush」を当てたものになっているはず。
//
// テストの前提にしている仕様
//   - レイテンシは 1。入力の次のサイクルに ex_lsu が組み合わせで出る
//   - valid = 前のサイクルの rr_ex.valid && !前の rst && !前の flush && !今の flush
//             && 前の brmask が今の kill_mask に当たらない
//   - addr_valid = valid && issue_part[0]、data_valid = valid && issue_part[1]
//   - addr = rs1 + imm（addr_valid のときだけ見る）、data = rs2（data_valid のときだけ見る）
//   - is_store / ldq_idx / stq_idx は前の rr_ex のもの（valid のときだけ見る）
//   - rr_ex は RR で今の br_update を当てた後のものなので、brmask は今の kill_mask / resolve_mask と重ねない
//   - load の issue_part は 01、store は 01（STA だけ）/ 10（STD だけ）/ 11（両方）

module tb_eu_1_top
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
  rr_ex_mem_t rr_ex;
  word_t      imm;
  br_update_t br_update_ff;
  ex_lsu_t    ex_lsu;

  eu_1_top dut (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .rr_ex(rr_ex),
    .imm(imm),
    .br_update_ff(br_update_ff),
    .ex_lsu(ex_lsu)
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

  // ---------------- 入力を作る ----------------

  typedef struct {
    logic       rst;
    logic       flush;
    rr_ex_mem_t rr;
    word_t      imm;
    br_update_t upd;
  } in_t;

  function automatic in_t gen_input(int cyc);
    in_t x;
    x.rst = cyc < 3 || rnd(2000) == 0;
    x.flush = rnd(50) == 0;
    x.upd = gen_br_update();
    x.rr = '0;
    x.rr.common.valid = rnd(8) != 0;
    x.rr.common.rs1_val = rnd_word();
    x.rr.common.rs2_val = rnd_word();
    x.rr.common.dest_fu = FU_MEM;
    x.rr.common.brmask = brmask_t'($urandom() & $urandom()) & ~x.upd.kill_mask & ~x.upd.resolve_mask;
    x.rr.payload.is_store = rnd(2) == 0;
    if (x.rr.payload.is_store) begin
      x.rr.common.rd = preg_t'{typ: PREG_TYPE_NONE, idx: '0};
      case (rnd(3))
        0: x.rr.issue_part = 2'b01;
        1: x.rr.issue_part = 2'b10;
        default: x.rr.issue_part = 2'b11;
      endcase
      x.rr.payload.imm_type = IMM_D;
    end else begin
      x.rr.common.rd = preg_t'{typ: (rnd(2) == 0) ? PREG_TYPE_I : PREG_TYPE_F, idx: preg_idx_t'(rnd(64))};
      x.rr.issue_part = 2'b01;
      x.rr.payload.imm_type = IMM_C;
    end
    x.rr.payload.imm = imm_raw_t'($urandom());
    x.rr.payload.rob_idx = rob_idx_t'(rnd(ROB_SIZE));
    x.rr.payload.ldq_idx = ldq_idx_t'(rnd(LDQ_SIZE));
    x.rr.payload.stq_idx = stq_idx_t'(rnd(STQ_SIZE));
    x.imm = (rnd(2) == 0) ? word_t'(rnd(64)) - 32'd32 : rnd_word();
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
  int n_load;
  int n_sta;
  int n_std;
  int n_st_both;
  int n_exit_kill;
  int n_exit_flush;

  task automatic fail(string msg);
    errors++;
    if (errors <= MAX_ERRORS) $display("[cycle %0d] NG: %s", cyc, msg);
  endtask

  task automatic check();
    logic       exp_valid;
    logic       exp_addr_valid;
    logic       exp_data_valid;
    addr_t      exp_addr;
    rr_ex_mem_t p;
    string      tag;

    p = prev.rr;
    tag = $sformatf("%s part=%b rs1=%h rs2=%h imm=%h", p.payload.is_store ? "ST" : "LD", p.issue_part,
                    p.common.rs1_val, p.common.rs2_val, prev.imm);

    exp_valid = p.common.valid && !prev.rst && !prev.flush && !cur.flush
                && !(|(p.common.brmask & cur.upd.kill_mask));
    exp_addr_valid = exp_valid && p.issue_part[0];
    exp_data_valid = exp_valid && p.issue_part[1];

    if (p.common.valid && !prev.rst && !prev.flush) begin
      if (cur.flush) n_exit_flush++;
      else if (|(p.common.brmask & cur.upd.kill_mask)) n_exit_kill++;
    end

    if (ex_lsu.addr_valid !== exp_addr_valid)
      fail($sformatf("addr_valid=%b 期待 %b（%s）", ex_lsu.addr_valid, exp_addr_valid, tag));
    if (ex_lsu.data_valid !== exp_data_valid)
      fail($sformatf("data_valid=%b 期待 %b（%s）", ex_lsu.data_valid, exp_data_valid, tag));
    if (!exp_valid) return;

    n_check++;
    if (!p.payload.is_store) n_load++;
    else if (p.issue_part == 2'b01) n_sta++;
    else if (p.issue_part == 2'b10) n_std++;
    else n_st_both++;

    if (ex_lsu.is_store !== p.payload.is_store)
      fail($sformatf("is_store=%b 期待 %b（%s）", ex_lsu.is_store, p.payload.is_store, tag));
    if (ex_lsu.ldq_idx !== p.payload.ldq_idx)
      fail($sformatf("ldq_idx=%0d 期待 %0d（%s）", ex_lsu.ldq_idx, p.payload.ldq_idx, tag));
    if (ex_lsu.stq_idx !== p.payload.stq_idx)
      fail($sformatf("stq_idx=%0d 期待 %0d（%s）", ex_lsu.stq_idx, p.payload.stq_idx, tag));
    exp_addr = addr_t'(p.common.rs1_val + prev.imm);
    if (exp_addr_valid && ex_lsu.addr !== exp_addr)
      fail($sformatf("addr=%h 期待 %h（%s）", ex_lsu.addr, exp_addr, tag));
    if (exp_data_valid && ex_lsu.data !== p.common.rs2_val)
      fail($sformatf("data=%h 期待 %h（%s）", ex_lsu.data, p.common.rs2_val, tag));
  endtask

  initial begin
    if (!$value$plusargs("cycles=%d", cycles)) cycles = 200000;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    $display("eu_1_top: seed=%0d cycles=%0d", seed, cycles);
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
      $display("  LD              %0d", n_load);
      $display("  ST（STA だけ）  %0d", n_sta);
      $display("  ST（STD だけ）  %0d", n_std);
      $display("  ST（両方）      %0d", n_st_both);
      $display("  出口で kill %0d / flush %0d", n_exit_kill, n_exit_flush);
      if (errors == 0) $display("PASS");
      else $display("FAIL（%0d 件）", errors);
      $finish;
    end
  end

endmodule

`default_nettype wire
