`timescale 1ns / 1ps
`default_nettype none

module eu_2_top
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
  input wire word_t        imm,    // ex_topで符号拡張したもの

  // EXから
  input wire br_update_t br_update_ff,

  // RFへ
  output ex_wb_t to_wb,

  // 全体へ
  output br_result_t br_result
);

  typedef struct packed {
    logic     valid;
    logic     is_br;
    preg_t    rd;
    brmask_t  brmask;
    br_tag_t  br_tag;
    rob_idx_t rob_idx;
    pc_t      pc;
  } meta_t;

  // FUの段数(1段)分のmeta
  meta_t meta_ff;

  word_t fu_0_result;
  logic  fu_0_taken;
  pc_t   fu_0_target;
  logic  fu_0_mispredict;

  eu_2_fu_0_top u_fu_0 (
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

  // 今FFにあるbr_updateとflushを当てたmeta
  meta_t n_meta;

  always_comb begin
    n_meta        = meta_ff;
    n_meta.valid  = meta_ff.valid & !flush & !br_kill_check(meta_ff.brmask, br_update_ff);
    n_meta.brmask = apply_br_resolve(meta_ff.brmask, br_update_ff);
  end

  assign to_wb.valid          = n_meta.valid;
  assign to_wb.rd             = n_meta.rd;
  assign to_wb.value          = fu_0_result;
  assign to_wb.rob_idx        = n_meta.rob_idx;

  assign br_result.valid      = n_meta.valid & n_meta.is_br;
  assign br_result.mispredict = fu_0_mispredict;
  assign br_result.tag        = n_meta.br_tag;
  assign br_result.brmask     = n_meta.brmask;
  assign br_result.taken      = fu_0_taken;
  assign br_result.pc         = n_meta.pc;
  assign br_result.target     = fu_0_target;
  assign br_result.rob_idx    = n_meta.rob_idx;

  // meta_ffの更新
  always_ff @(posedge clk) begin
    meta_ff.valid   <= !rst & !flush & rr_ex.common.valid;
    meta_ff.is_br   <= rr_ex.payload.fu_op[3:2] == 2'b00;
    meta_ff.rd      <= rr_ex.common.rd;
    meta_ff.brmask  <= rr_ex.common.brmask;
    meta_ff.br_tag  <= rr_ex.payload.br_tag;
    meta_ff.rob_idx <= rr_ex.payload.rob_idx;
    meta_ff.pc      <= rr_ex.payload.pc;
  end

endmodule

`default_nettype wire
