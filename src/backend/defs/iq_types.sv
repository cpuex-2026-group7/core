`timescale 1ns / 1ps
`default_nettype none

package iq_types;
  import types::*;
  import ooo_types::*;
  import isa::*;
  import uop_types::*;

  typedef struct packed {
    logic      valid;
    disp_uop_t uop;
  } disp_iq_t;

  typedef latency_t cnt_down_t;

  typedef struct packed {
    // counting && cnt == 0がready
    logic      counting;
    cnt_down_t cnt;
  } src_state_t;

  typedef struct packed {
    preg_t      preg;
    src_state_t st;
  } src_reg_t;

  typedef struct packed {
    preg_t    rd;
    src_reg_t rs1;
    src_reg_t rs2;
    latency_t lat;
    dest_eu_t dest_eu;
    dest_fu_t dest_fu;
    brmask_t  brmask;
  } wrapper_ff_t;

  typedef struct packed {
    opcode_t  op;
    imm_raw_t imm;
    pc_t      pc;
    pc_t      predict_pc;
    ftq_idx_t ftq_idx;
    rob_idx_t rob_idx;
    br_tag_t  br_tag;
  } int_payload_t;

  typedef struct packed {
    opcode_t  op;
    imm_raw_t imm;
    rob_idx_t rob_idx;
    ldq_idx_t ldq_idx;
    stq_idx_t stq_idx;
  } mem_payload_t;

  typedef struct packed {
    opcode_t  op;
    imm_raw_t imm;
    pc_t      pc;
    pc_t      predict_pc;
    ftq_idx_t ftq_idx;
    rob_idx_t rob_idx;
    br_tag_t  br_tag;
  } float_payload_t;

  // IQとRRの間のFF
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
