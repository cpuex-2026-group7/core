`timescale 1ns / 1ps
`default_nettype none

package iq_types;
  import types::*;
  import isa::*;
  import uop_types::*;
  import back_types::*;

  typedef latency_t cnt_down_t;

  typedef struct packed {
    logic      waiting;
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
    dest_fu_t dest_fu;
    brmask_t  brmask;
  } wrapper_ff_t;

  typedef struct packed {
    opcode_t  op;
    imm_raw_t imm;
    pc_t      pc;
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
    rob_idx_t rob_idx;
  } fp_payload_t;

endpackage

`default_nettype wire
