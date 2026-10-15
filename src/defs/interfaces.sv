`timescale 1ns / 1ps
`default_nettype none

interface if_id_if;
  import types::*;
  import isa::*;
  import ctrl_defs::*;
  typedef struct packed {
    instr_t instr_D;
    addr_t  pc_D;
    addr_t  pc_plus_1_D;
  } payload_t;

  payload_t data;

  modport prod(output data);
  modport cons(input data);
endinterface  //if_id_if

interface id_ex_if;
  import types::*;
  import isa::*;
  typedef struct packed {
    ctrl_t   ctrl_E;
    word_t   rdata1_E;
    word_t   rdata2_E;
    rf_idx_t rs1_E;
    rf_idx_t rs2_E;
    rf_idx_t rd_E;
    word_t   ext_imm_E;
    addr_t   pc_E;
    addr_t   pc_plus_1_E;
  } payload_t;

  payload_t data;

  modport prod(output data);
  modport cons(input data);
endinterface  //id_ex_if

interface ex_mem_if;
  import types::*;
  import isa::*;
  typedef struct packed {
    ctrl_t   ctrl_M;
    word_t   alu_result_M;
    word_t   fpu_result_M;
    word_t   wdata_M;
    rf_idx_t rd_M;
    word_t   ext_imm_M;
    word_t   hard_code_M;
    addr_t   pc_plus_1_M;
  } payload_t;

  payload_t data;

  modport prod(output data);
  modport cons(input data);
endinterface  //ex_mem_if

interface mem_wb_if;
  import types::*;
  import isa::*;
  typedef struct packed {
    ctrl_t   ctrl_W;
    word_t   fpu_result_W;
    word_t   alu_result_W;
    word_t   rdata_W;
    rf_idx_t rd_W;
    word_t   ext_imm_W;
    word_t   hard_code_W;
    addr_t   pc_plus_1_W;
  } payload_t;

  payload_t data;

  modport prod(output data);
  modport cons(input data);
endinterface  //mem_wb_if

interface wb_if_if;
  import types::*;
  import isa::*;
  typedef struct packed {addr_t pc_F;} payload_t;

  payload_t data;

  modport prod(output data);
  modport cons(input data);
endinterface  //wb_if_if

`default_nettype wire
