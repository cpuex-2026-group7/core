`timescale 1ns / 1ps
`default_nettype none

package uop_types;
  import types::*;
  import isa::*;

  // 形式はop.immから見る
  typedef logic [19:0] imm_raw_t;

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

    // load: 自分の位置とdispatch時のSTQ tail
    // store: 自分の位置とdispatch時のLDQ tail
    // flhiはLSUのエントリ使わん
    ldq_idx_t ldq_idx;
    stq_idx_t stq_idx;
  } disp_uop_t;

endpackage

`default_nettype wire
