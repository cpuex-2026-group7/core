`timescale 1ns / 1ps
`default_nettype none

package ex_types;
  import types::*;

  // EXとWBの間のFF
  typedef struct packed {
    logic     valid;
    preg_t    rd;
    word_t    value;
    rob_idx_t rob_idx;
  } ex_wb_t;

endpackage

`default_nettype wire
