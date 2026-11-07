`timescale 1ns / 1ps
`default_nettype none

module eu_mem_top
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import rr_types::*;
  import ex_types::*;
(
  input wire logic clk,
  input wire logic rst,
  input wire logic flush,  // loadの順序違反でflush

  // RRから
  input wire rr_ex_mem_t rr_ex,
  input wire word_t      imm,  // ex_topで符号拡張したもの

  // EXから
  input wire br_update_t br_update_ff,

  // LSUへ
  output ex_lsu_t lsu_ff
);

endmodule

`default_nettype wire
