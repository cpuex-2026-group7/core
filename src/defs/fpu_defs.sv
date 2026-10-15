`timescale 1ns / 1ps
`default_nettype none

package fpu_defs;
  // {eff[0], imm[0], id}
  typedef enum logic [3:0] {
    FPU_CVT_S_W = 4'b0000,
    FPU_SQRT    = 4'b0001,
    FPU_NEG     = 4'b0010,
    FPU_ABS     = 4'b0011,
    FPU_ADD     = 4'b0100,
    FPU_SUB     = 4'b0101,
    FPU_MUL     = 4'b0110,
    FPU_DIV     = 4'b0111,
    FPU_CVT_W_S = 4'b1000,
    FPU_EQ      = 4'b1100,
    FPU_LT      = 4'b1101
  } fpu_op_t;
endpackage

`default_nettype wire
