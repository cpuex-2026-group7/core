`timescale 1ns / 1ps
`default_nettype none

package back_types;
  import types::*;
  import isa::*;
  import uop_types::*;

  typedef struct packed {
    logic     valid;
    preg_t    preg;
    latency_t latency;  // ◯cycle後から来てもいいよ
  } wakeup_t;

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

endpackage

`default_nettype wire
