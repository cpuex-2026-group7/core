`timescale 1ns / 1ps
`default_nettype none

package isa;
  import types::*;
  // ちなみにx0=0, f0=0の規約。
  // ワードアドレッシング

  // どっちのユニットを使うか?
  typedef enum logic {
    UNIT_ALU = 1'b0,  // ALUを使う
    UNIT_FPU = 1'b1   // FPUを使う
  } unit_t;

  // 作用
  typedef enum logic [1:0] {
    EFF_NONE = 2'b00,  // 書き込みなし
    EFF_WI   = 2'b01,  // Iレジスタに書く
    EFF_WF   = 2'b10,  // Fレジスタに書く
    EFF_MEM  = 2'b11   // メモリに書く
  } eff_t;

  // 即値形式
  typedef enum logic [1:0] {
    IMM_A = 2'b00,  // 引数1(float拡張)
    IMM_B = 2'b01,  // 引数1(imm20)
    IMM_C = 2'b10,  // 引数2(imm15)
    IMM_D = 2'b11   // 引数3(imm5+10)
  } imm_t;

  typedef struct packed {
    unit_t      unit;  // [31:31]
    eff_t       eff;   // [30:29]
    imm_t       imm;   // [28:27]
    logic [1:0] id;    // [26:25]
  } opcode_t;

  typedef struct packed {
    opcode_t    op;   // [31:25]
    reg_addr_t  rd;   // [24:20]
    reg_addr_t  rs1;  // [19:15]
    reg_addr_t  rs2;  // [14:10]
    logic [9:0] rest;  // [9:0]
  } instr_t;

endpackage

`default_nettype wire
