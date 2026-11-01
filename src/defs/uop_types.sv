`timescale 1ns / 1ps
`default_nettype none

package uop_types;
  import types::*;
  import isa::*;

  // 形式はop.immから見る
  typedef logic [19:0] imm_raw_t;

  typedef logic [1:0] latency_t;
  typedef logic [1:0] dest_fu_t;

  localparam latency_t LAT_FAST   = 2'd0;
  localparam latency_t LAT_ITOF   = 2'd1;
  localparam latency_t LAT_FADD   = 2'd1;
  localparam latency_t LAT_FMUL   = 2'd3;

  localparam dest_fu_t FU_F_SHORT = 2'b00;
  localparam dest_fu_t FU_F_LONG  = 2'b01;
  localparam dest_fu_t FU_F_DIV   = 2'b10;
  localparam dest_fu_t FU_F_SQRT  = 2'b11;

  // 使わないレジスタは typ=PREG_TYPE_NONE
  typedef struct packed {
    opcode_t  op;
    preg_t    rd;
    preg_t    rs1;
    preg_t    rs2;
    imm_raw_t imm;
    pc_t      pc;
    rob_idx_t rob_idx;
    brmask_t  brmask;
    br_tag_t  br_tag;

    latency_t lat;
    dest_fu_t dest_fu;

    // load: 自分の位置とdispatch時のSTQ tail
    // store: 自分の位置とdispatch時のLDQ tail
    // flhiはLSUのエントリ使わん
    ldq_idx_t ldq_idx;
    stq_idx_t stq_idx;
  } disp_uop_t;

endpackage

`default_nettype wire
