`timescale 1ns / 1ps
`default_nettype none

package back_types;
  import types::*;
  import isa::*;
  import uop_types::*;

  typedef logic [2:0] latency_t;

  typedef struct packed {
    logic     valid;
    preg_t    preg;
    latency_t latency;  // ◯cycle後から来てもいいよ
  } wakeup_t;

  typedef logic [1:0] dest_fu_t;

  typedef struct packed {
    logic      valid;
    disp_uop_t uop;
  } disp_iq_t;

  typedef struct packed {
    logic     valid;
    preg_t    rd;
    preg_t    rs1;
    preg_t    rs2;
    dest_fu_t dest_fu;
    brmask_t  brmask;
  } iq_rr_t;

  localparam latency_t LAT_SLOW   = 3'd0;
  localparam latency_t LAT_FAST   = 3'd1;
  localparam latency_t LAT_ITOF   = 3'd2;
  localparam latency_t LAT_FADD   = 3'd2;
  localparam latency_t LAT_FMUL   = 3'd4;

  localparam dest_fu_t FU_F_SHORT = 2'b00;
  localparam dest_fu_t FU_F_LONG  = 2'b01;
  localparam dest_fu_t FU_F_DIV   = 2'b10;
  localparam dest_fu_t FU_F_SQRT  = 2'b11;

endpackage

`default_nettype wire
