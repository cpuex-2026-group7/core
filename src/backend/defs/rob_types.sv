`timescale 1ns / 1ps
`default_nettype none

package rob_types;
  import types::*;

  // WBからROBへの完了通知
  typedef struct packed {
    logic     valid;
    rob_idx_t rob_idx;
  } complete_t;

endpackage

`default_nettype wire
