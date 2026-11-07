`timescale 1ns / 1ps
`default_nettype none

module eu_1_top
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
  input wire rr_ex_mem_t rr_ex,
  input wire word_t      imm,    // ex_topで符号拡張したもの

  // EXから
  input wire br_update_t br_update_ff,

  // LSUへ
  output ex_lsu_t ex_lsu
);

  typedef struct packed {
    logic       valid;
    logic [1:0] issue_part;  // [0]がLDA/STA、[1]がSTD
    logic       is_store;
    brmask_t    brmask;
    ldq_idx_t   ldq_idx;
    stq_idx_t   stq_idx;
  } meta_t;

  // FUの段数(1段)分のmeta
  meta_t meta_ff;

  addr_t fu_0_addr;
  word_t fu_0_data;

  eu_1_fu_0_top u_fu_0 (
    .clk(clk),
    .rs1_val(rr_ex.common.rs1_val),
    .rs2_val(rr_ex.common.rs2_val),
    .imm(imm),
    .addr(fu_0_addr),
    .data(fu_0_data)
  );

  // 今FFにあるbr_updateとflushを当てたmeta
  meta_t n_meta;

  always_comb begin
    n_meta        = meta_ff;
    n_meta.valid  = meta_ff.valid & !flush & !br_kill_check(meta_ff.brmask, br_update_ff);
    n_meta.brmask = apply_br_resolve(meta_ff.brmask, br_update_ff);
  end

  assign ex_lsu.is_store   = n_meta.is_store;
  assign ex_lsu.addr_valid = n_meta.valid & n_meta.issue_part[0];
  assign ex_lsu.data_valid = n_meta.valid & n_meta.issue_part[1];
  assign ex_lsu.addr       = fu_0_addr;
  assign ex_lsu.data       = fu_0_data;
  assign ex_lsu.ldq_idx    = n_meta.ldq_idx;
  assign ex_lsu.stq_idx    = n_meta.stq_idx;

  // meta_ffの更新
  always_ff @(posedge clk) begin
    meta_ff.valid      <= !rst & !flush & rr_ex.common.valid;
    meta_ff.issue_part <= rr_ex.issue_part;
    meta_ff.is_store   <= rr_ex.payload.is_store;
    meta_ff.brmask     <= rr_ex.common.brmask;
    meta_ff.ldq_idx    <= rr_ex.payload.ldq_idx;
    meta_ff.stq_idx    <= rr_ex.payload.stq_idx;
  end

endmodule

`default_nettype wire
