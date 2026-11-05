`timescale 1ns / 1ps
`default_nettype none

package ex_types;
  import types::*;
  import ooo_types::*;

  // EXとWBの間のFF
  typedef struct packed {
    logic     valid;
    preg_t    rd;
    word_t    value;
    rob_idx_t rob_idx;
  } ex_wb_t;

  // AGUからLSUへ
  // validは addr_valid | data_valid
  // STAとSTDを同時にissueできるようにする
  typedef struct packed {
    logic     is_store;
    logic     addr_valid;  // LDA, STA
    logic     data_valid;  // STD
    addr_t    addr;
    word_t    data;
    ldq_idx_t ldq_idx;
    stq_idx_t stq_idx;
  } ex_lsu_t;

endpackage

`default_nettype wire
