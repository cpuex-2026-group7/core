`timescale 1ns / 1ps
`default_nettype none

module ex_int_top
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import rr_types::*;
  import ex_types::*;
#(
  parameter int BR_UPDATE_W = 1
) (
  input wire logic clk,
  input wire logic rst,
  input wire logic flush,  // loadの順序違反でflush

  // RRから
  input wire rr_ex_int_t ex_ff,

  // EXから
  input wire br_update_t br_update[BR_UPDATE_W],

  // RFへ
  output ex_wb_t to_wb,

  // 全体へ
  output br_update_t br_update_out
);

endmodule

`default_nettype wire
