`timescale 1ns / 1ps
`default_nettype none

module ex_int_top
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
  input wire rr_ex_int_t ex_ff,

  // EXから
  input wire br_update_t br_update,

  // RFへ
  output ex_wb_t to_wb,

  // 全体へ
  output br_result_t br_result
);

endmodule

`default_nettype wire
