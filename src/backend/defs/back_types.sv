`timescale 1ns / 1ps
`default_nettype none

package back_types;
  import types::*;
  import isa::*;
  import uop_types::*;

  typedef logic [3:0] latency_t;
  typedef latency_t cnt_down_t;

  typedef struct packed {
    logic     valid;
    preg_t    preg;
    latency_t latency;  // ◯cycle後から来てもいいよ
  } wakeup_t;

  localparam int DEST_FU_W   = 3;
  localparam int MAX_DEST_FU = 1 << DEST_FU_W;
  typedef logic [DEST_FU_W-1:0] dest_fu_t;

  typedef struct packed {
    logic      waiting;
    cnt_down_t cnt;
  } src_state_t;

  typedef struct packed {
    preg_t      preg;
    src_state_t st;
  } iq_src_t;

endpackage

`default_nettype wire
