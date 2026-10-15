`timescale 1ns / 1ps
`default_nettype none

package ctrl_defs;
  import fpu_defs::*;

  typedef enum logic [1:0] {
    PC_PLUS_ONE,  // pc+1
    PC_BRANCH,    // pc+1+imm (条件付き)
    PC_JAL,       // pc+1+imm
    PC_JALR       // rs1+imm
  } pc_src_t;

  typedef enum logic [2:0] {
    RES_ALU,
    RES_FPU,
    RES_MEM,
    RES_IMM,
    RES_HARD_CODE,
    RES_PC_PLUS_ONE
  } result_src_t;

  typedef enum logic [2:0] {
    FWD_NONE = 3'b000,
    FWD_ALU_M = 3'b001,
    FWD_FPU_M = 3'b010,
    FWD_IMM_M = 3'b011,
    FWD_HARD_CODE_M = 3'b100,
    FWD_RES_W = 3'b101
  } fwd_src_t;

  typedef enum logic [2:0] {
    ALU_ADD = 3'b000,
    ALU_SUB = 3'b001,
    ALU_EQ  = 3'b100,
    ALU_NE  = 3'b101,
    ALU_LT  = 3'b110,
    ALU_GE  = 3'b111
  } alu_op_t;

  typedef struct packed {
    logic    rd_is_f;
    logic    rs1_is_f;
    logic    rs2_is_f;
    alu_op_t alu_op;
    fpu_op_t fpu_op;
    logic    jump_base_src;
    logic    alu_src_is_imm;
    logic    reg_we;
    logic    mem_we;
    pc_src_t pc_src;
    result_src_t result_src;
    logic    halt;
  } ctrl_t;

endpackage

`default_nettype wire
