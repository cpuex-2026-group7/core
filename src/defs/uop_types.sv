`timescale 1ns / 1ps
`default_nettype none

package uop_types;
  import types::*;
  import ooo_types::*;
  import isa::*;

  // 形式はimm_typeから見る
  typedef logic [19:0] imm_raw_t;

  typedef logic [1:0] latency_t;
  typedef logic [2:0] dest_eu_t;
  typedef logic [1:0] dest_fu_t;  // EUの中のFU

  localparam int       FU_PER_EU      = 1 << $bits(dest_fu_t);

  localparam latency_t LAT_FAST       = 2'd0;
  localparam latency_t LAT_ITOF       = 2'd2;
  localparam latency_t LAT_FADD       = 2'd3;
  localparam latency_t LAT_FMUL       = 2'd1;

  localparam dest_eu_t EU_ALU         = 3'd0;
  localparam dest_eu_t EU_MEM         = 3'd1;
  localparam dest_eu_t EU_F_SHORT     = 3'd2;
  localparam dest_eu_t EU_F_LONG      = 3'd3;
  localparam dest_eu_t EU_F_VERY_LONG = 3'd4;

  // INT
  localparam dest_fu_t FU_INT         = 2'd0;
  // MEM
  localparam dest_fu_t FU_MEM         = 2'd0;
  // F短
  localparam dest_fu_t FU_F_SHORT     = 2'd0;
  // F長
  localparam dest_fu_t FU_FMUL        = 2'd0;
  localparam dest_fu_t FU_FCVT        = 2'd1;                   // itof, ftoi
  localparam dest_fu_t FU_FADD        = 2'd2;                   // fadd, fsub
  // F超長
  localparam dest_fu_t FU_FSQRT       = 2'd0;
  localparam dest_fu_t FU_FDIV        = 2'd1;

  // FUの中の演算。意味はFUごと
  // 条件分岐は[3:2]=00で[1:0]は命令のidと同じ([1]=0がeq/1がlt、[0]=1で反転)
  // [3:2]=01がjal/jalr、[3:2]=10がそれ以外
  // 1つのunitで複数のuopをやるときは下位bitで区別する
  typedef logic [3:0] fu_op_t;

  // ALU
  localparam fu_op_t FU_OP_BEQ    = 4'b0000;
  localparam fu_op_t FU_OP_BNE    = 4'b0001;
  localparam fu_op_t FU_OP_BLT    = 4'b0010;
  localparam fu_op_t FU_OP_BGE    = 4'b0011;
  localparam fu_op_t FU_OP_JAL    = 4'b0100;
  localparam fu_op_t FU_OP_JALR   = 4'b0101;
  localparam fu_op_t FU_OP_ADD    = 4'b1000;
  localparam fu_op_t FU_OP_ADDI   = 4'b1001;
  localparam fu_op_t FU_OP_SUB    = 4'b1010;
  localparam fu_op_t FU_OP_SRA    = 4'b1011;
  // MEM
  localparam fu_op_t FU_OP_AGU    = 4'b1000;
  // F短
  localparam fu_op_t FU_OP_FBEQ   = 4'b0000;
  localparam fu_op_t FU_OP_FBNE   = 4'b0001;
  localparam fu_op_t FU_OP_FBLT   = 4'b0010;
  localparam fu_op_t FU_OP_FBGE   = 4'b0011;
  localparam fu_op_t FU_OP_FLI    = 4'b1000;
  localparam fu_op_t FU_OP_FLHI   = 4'b1001;
  localparam fu_op_t FU_OP_FCSIGN = 4'b1010;
  // F長
  localparam fu_op_t FU_OP_FMUL   = 4'b1000;
  localparam fu_op_t FU_OP_ITOF   = 4'b1000;
  localparam fu_op_t FU_OP_FTOI   = 4'b1001;
  localparam fu_op_t FU_OP_FADD   = 4'b1000;
  localparam fu_op_t FU_OP_FSUB   = 4'b1001;
  // F超長
  localparam fu_op_t FU_OP_FSQRT  = 4'b1000;
  localparam fu_op_t FU_OP_FDIV   = 4'b1000;

  // 使わんレジスタは typ=PREG_TYPE_NONE
  typedef struct packed {
    preg_t    rd;
    preg_t    rs1;
    preg_t    rs2;
    imm_t     imm_type;
    imm_raw_t imm;
    pc_t      pc;
    pc_t      predict_pc;
    ftq_idx_t ftq_idx;
    rob_idx_t rob_idx;
    brmask_t  brmask;
    br_tag_t  br_tag;

    dest_eu_t dest_eu;
    dest_fu_t dest_fu;
    fu_op_t   fu_op;
    latency_t lat;

    // load: 自分の位置とdispatch時のSTQ tail
    // store: 自分の位置とdispatch時のLDQ tail
    // flhiはLSUのエントリ使わん
    logic     is_store;
    ldq_idx_t ldq_idx;
    stq_idx_t stq_idx;
  } disp_uop_t;

endpackage

`default_nettype wire
