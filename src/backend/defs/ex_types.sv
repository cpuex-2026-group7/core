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

  typedef enum logic [1:0] {
    LSU_LD,
    LSU_STA,
    LSU_STD
  } lsu_kind_t;

  // AGUからLSUへ
  typedef struct packed {
    logic      valid;
    lsu_kind_t kind;
    word_t     data;     // LD,STAならaddress、STDならdata
    ldq_idx_t  ldq_idx;
    stq_idx_t  stq_idx;
  } ex_lsu_t;

endpackage

`default_nettype wire
