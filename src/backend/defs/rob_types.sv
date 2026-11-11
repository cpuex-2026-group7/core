`timescale 1ns / 1ps
`default_nettype none

package rob_types;
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import isa::*;

  // WBからROBへの完了通知
  typedef struct packed {
    logic     valid;
    rob_idx_t rob_idx;
  } complete_t;

  // LSUからROBへ
  // 一番古いviolationを通知
  typedef struct packed {
    logic     valid;
    rob_idx_t rob_idx;
  } load_violation_t;

  typedef struct packed {
    logic valid;
    logic busy;
    logic excp; // load violation
    brmask_t brmask;
    rf_idx_t ldst;
    preg_t stale_pdst;
    disp_uop_t uop;
  } rob_entry_t;
endpackage

`default_nettype wire
