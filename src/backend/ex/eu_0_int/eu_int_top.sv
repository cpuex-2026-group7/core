`timescale 1ns / 1ps
`default_nettype none

module eu_int_top
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
  input wire rr_ex_int_t rr_ex,
  input wire word_t      imm,    // ex_topで符号拡張したもの

  // EXから
  input wire br_update_t br_update_ff,

  // RFへ
  output ex_wb_t to_wb,

  // 全体へ
  output br_result_t br_result
);

  word_t fu_0_result;
  logic  fu_0_taken;
  pc_t   fu_0_target;
  logic  fu_0_mispredict;

  eu_0_fu_0_top u_fu_0 (
    .clk(clk),
    .rs1_val(rr_ex.common.rs1_val),
    .rs2_val(rr_ex.common.rs2_val),
    .fu_op(rr_ex.payload.fu_op),
    .imm(imm),
    .pc(rr_ex.payload.pc),
    .predict_pc(rr_ex.payload.predict_pc),
    .result(fu_0_result),
    .taken(fu_0_taken),
    .target(fu_0_target),
    .mispredict(fu_0_mispredict)
  );

  // FUの段数(1段)ぶんのmeta
  typedef struct packed {
    logic     valid;
    logic     is_br;
    preg_t    rd;
    brmask_t  brmask;
    br_tag_t  br_tag;
    rob_idx_t rob_idx;
    pc_t      pc;
  } meta_t;

  meta_t meta_ff;

  always_ff @(posedge clk) begin
    meta_ff.valid   <= !rst & !flush & rr_ex.common.valid;
    meta_ff.is_br   <= rr_ex.payload.fu_op[3:2] == 2'b00;
    meta_ff.rd      <= rr_ex.common.rd;
    meta_ff.brmask  <= rr_ex.common.brmask;
    meta_ff.br_tag  <= rr_ex.payload.br_tag;
    meta_ff.rob_idx <= rr_ex.payload.rob_idx;
    meta_ff.pc      <= rr_ex.payload.pc;
  end

  // 出口でも今FFにあるbr_updateでkillする
  logic valid;
  assign valid                = meta_ff.valid & !flush & !br_kill_check(meta_ff.brmask, br_update_ff);

  assign to_wb.valid          = valid;
  assign to_wb.rd             = meta_ff.rd;
  assign to_wb.value          = fu_0_result;
  assign to_wb.rob_idx        = meta_ff.rob_idx;

  assign br_result.valid      = valid & meta_ff.is_br;
  assign br_result.mispredict = fu_0_mispredict;
  assign br_result.tag        = meta_ff.br_tag;
  assign br_result.brmask     = apply_br_resolve(meta_ff.brmask, br_update_ff);
  assign br_result.taken      = fu_0_taken;
  assign br_result.pc         = meta_ff.pc;
  assign br_result.target     = fu_0_target;
  assign br_result.rob_idx    = meta_ff.rob_idx;

endmodule

`default_nettype wire
