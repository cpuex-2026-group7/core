`timescale 1ns / 1ps
`default_nettype none

module eu_4_top
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import rr_types::*;
  import ex_types::*;
(
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush

  // RRから
  input wire rr_ex_float_t rr_ex,

  // EXから
  input wire br_update_t br_update_ff,

  // RFへ
  output ex_wb_t to_wb,

  // IQへ
  output wakeup_t slow_wakeup,  // 書き込み時にwakeup
  output logic fdiv_blocked,
  output logic fsqrt_blocked
);

  localparam int FU_NUM = 2;  // fsqrt, fdiv

  // FUごとの演算中の命令のmeta
  typedef struct packed {
    logic     valid;
    preg_t    rd;
    brmask_t  brmask;
    rob_idx_t rob_idx;
  } meta_t;

  // 待たせているfdiv用
  typedef struct packed {
    logic     valid;
    preg_t    rd;
    brmask_t  brmask;
    rob_idx_t rob_idx;
    word_t    value;
  } hold_t;

  meta_t meta_ff[FU_NUM];
  hold_t hold_ff;
  logic abort_ff[FU_NUM];

  logic issued[FU_NUM];
  logic fu_done[FU_NUM];
  word_t fu_result[FU_NUM];

  always_comb begin
    for (int i = 0; i < FU_NUM; i++) begin
      issued[i] = !flush & rr_ex.common.valid & (rr_ex.common.dest_fu == i);
    end
  end

  eu_4_fu_0_top u_fu_0 (
    .clk(clk),
    .rst(rst),
    .issued(issued[FU_FSQRT]),
    .abort(abort_ff[FU_FSQRT]),
    .rs1_val(rr_ex.common.rs1_val),
    .done(fu_done[FU_FSQRT]),
    .result(fu_result[FU_FSQRT])
  );

  eu_4_fu_1_top u_fu_1 (
    .clk(clk),
    .rst(rst),
    .issued(issued[FU_FDIV]),
    .abort(abort_ff[FU_FDIV]),
    .rs1_val(rr_ex.common.rs1_val),
    .rs2_val(rr_ex.common.rs2_val),
    .done(fu_done[FU_FDIV]),
    .result(fu_result[FU_FDIV])
  );

  // 今FFにあるbr_updateとflushを当てたmetaとhold
  meta_t n_meta[FU_NUM];
  hold_t n_hold;

  logic meta_killed[FU_NUM];
  logic hold_killed;
  always_comb begin
    for (int i = 0; i < FU_NUM; i++) begin
      meta_killed[i] = flush | br_kill_check(meta_ff[i].brmask, br_update_ff);
    end
    hold_killed = flush | br_kill_check(hold_ff.brmask, br_update_ff);
  end

  always_comb begin
    for (int i = 0; i < FU_NUM; i++) begin
      n_meta[i]        = meta_ff[i];
      n_meta[i].valid  = meta_ff[i].valid & !meta_killed[i];
      n_meta[i].brmask = apply_br_resolve(meta_ff[i].brmask, br_update_ff);
    end

    n_hold        = hold_ff;
    n_hold.valid  = hold_ff.valid & !hold_killed;
    n_hold.brmask = apply_br_resolve(hold_ff.brmask, br_update_ff);
  end

  // abort_ffの更新
  always_ff @(posedge clk) begin
    for (int i = 0; i < FU_NUM; i++) begin
      if (rst) begin
        abort_ff[i] <= 1'b0;
      end else begin
        abort_ff[i] <= meta_ff[i].valid & meta_killed[i];
      end
    end
  end

  // 生きている命令が終わった
  logic done[FU_NUM];
  always_comb begin
    for (int i = 0; i < FU_NUM; i++) done[i] = fu_done[i] & n_meta[i].valid;
  end

  // 調停(同時に終わったらfdivを1サイクル待たせる)
  always_comb begin
    to_wb = '0;
    if (n_hold.valid) begin
      to_wb.valid   = 1'b1;
      to_wb.rd      = n_hold.rd;
      to_wb.value   = n_hold.value;
      to_wb.rob_idx = n_hold.rob_idx;
    end else if (done[FU_FSQRT]) begin
      to_wb.valid   = 1'b1;
      to_wb.rd      = n_meta[FU_FSQRT].rd;
      to_wb.value   = fu_result[FU_FSQRT];
      to_wb.rob_idx = n_meta[FU_FSQRT].rob_idx;
    end else if (done[FU_FDIV]) begin
      to_wb.valid   = 1'b1;
      to_wb.rd      = n_meta[FU_FDIV].rd;
      to_wb.value   = fu_result[FU_FDIV];
      to_wb.rob_idx = n_meta[FU_FDIV].rob_idx;
    end
  end

  assign slow_wakeup = wakeup_t'{valid: to_wb.valid, preg: to_wb.rd, latency: LAT_FAST};

  // meta_ffの更新
  always_ff @(posedge clk) begin
    for (int i = 0; i < FU_NUM; i++) begin
      if (rst) begin
        meta_ff[i].valid <= 1'b0;
      end else if (issued[i]) begin
        meta_ff[i] <= meta_t'{
          valid: 1'b1,
          rd: rr_ex.common.rd,
          brmask: rr_ex.common.brmask,
          rob_idx: rr_ex.payload.rob_idx
        };
      end else begin
        meta_ff[i] <= n_meta[i];
        // 終わったらWBかholdに移る
        if (done[i]) meta_ff[i].valid <= 1'b0;
      end
    end
  end

  // hold_ffの更新
  always_ff @(posedge clk) begin
    if (rst | flush) begin
      hold_ff <= '0;
    end else if (done[FU_FSQRT] & done[FU_FDIV]) begin
      // fdivをhold
      hold_ff <= hold_t'{
        valid: 1'b1,
        rd: n_meta[FU_FDIV].rd,
        rob_idx: n_meta[FU_FDIV].rob_idx,
        brmask: n_meta[FU_FDIV].brmask,
        value: fu_result[FU_FDIV]
      };
    end else begin
      hold_ff <= '0;
    end
  end

  assign fsqrt_blocked = meta_ff[FU_FSQRT].valid;
  assign fdiv_blocked  = meta_ff[FU_FDIV].valid | hold_ff.valid;

endmodule

`default_nettype wire
