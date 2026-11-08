`timescale 1ns / 1ps
`default_nettype none

package rr_types;
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import iq_types::*;

  // RRとEXの間のFF
  typedef struct packed {
    logic     valid;
    preg_t    rd;
    preg_t    rs1;
    preg_t    rs2;
    word_t    rs1_val;
    word_t    rs2_val;
    dest_fu_t dest_fu;
    brmask_t  brmask;
  } rr_ex_t;

  typedef struct packed {
    rr_ex_t       common;
    int_payload_t payload;
  } rr_ex_int_t;

  typedef struct packed {
    rr_ex_t       common;
    mem_payload_t payload;
    logic [1:0]   issue_part;
  } rr_ex_mem_t;

  typedef struct packed {
    rr_ex_t         common;
    float_payload_t payload;
  } rr_ex_float_t;

endpackage

`default_nettype wire
