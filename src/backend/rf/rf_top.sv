`timescale 1ns / 1ps
`default_nettype none

module rf_top
  import types::*;
  import uop_types::*;
  import back_types::*;
  import iq_types::*;
#(
  parameter int I_PREG_NUM  = 64,
  parameter int F_PREG_NUM  = 64,
  parameter int BR_UPDATE_W = 1
) (
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush

  // ALUレーンのWBから
  input wire br_update_t br_update[BR_UPDATE_W],

  // from IQ
  input wire logic issued_int[1],
  input iq_rr_t rr_ff_int[1],
  input int_payload_t rr_payload_int[1],

  input wire logic issued_mem[1],
  input iq_rr_t rr_ff_mem[1],
  input mem_payload_t rr_payload_mem[1],

  input wire logic issued_fpu[3],
  input iq_rr_t rr_ff_fpu[3],
  input float_payload_t rr_payload_fpu[3]

);


endmodule

`default_nettype wire
