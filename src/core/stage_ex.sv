`timescale 1ns / 1ps
`default_nettype none

module stage_ex
  import isa::*;
  import types::*;
(
  input wire word_t fpu_result_M,
  input wire word_t alu_result_M,
  input wire word_t hard_code_M,
  input wire word_t result_W,
  id_ex_if.cons id_ex,
  input wire logic [2:0] forwardA,
  input wire logic [2:0] forwardB,

  output addr_t pc_target_e,
  output logic pc_jump,
  ex_mem_if.prod ex_mem,
  output rf_idx_t rd_E,
  output rf_idx_t rs1_E,
  output rf_idx_t rs2_E
);

  word_t src_A, src_B;
  always_comb begin
    unique case (forwardA)
      3'b000:  src_A = id_ex.data.rdata1_E;
      3'b001:  src_A = alu_result_M;
      3'b010:  src_A = fpu_result_M;
      3'b011:  src_A = hard_code_M;
      default: src_A = result_W;
    endcase
    unique case (forwardB)
      3'b000:  src_B = id_ex.data.rdata2_E;
      3'b001:  src_B = alu_result_M;
      3'b010:  src_B = fpu_result_M;
      3'b011:  src_B = hard_code_M;
      default: src_B = result_W;
    endcase
  end

  fpu_top u_fpu (
    .src1  (src_A),
    .src2  (src_B),
    .fpu_op(id_ex.data.ctrl_E.fpu_op),
    .result(ex_mem.data.fpu_result_M)
  );

  alu u_alu (
    .src1  (src_A),
    .src2  (id_ex.data.ctrl_E.alu_src_is_imm ? id_ex.data.ext_imm_E : src_B),
    .alu_op(id_ex.data.ctrl_E.alu_op),
    .result(alu_result_E)
  );

  always_comb begin
    unique case (id_ex.data.ctrl_E.pc_src)
      PC_PLUS_ONE: pc_jump = 1'b0;
      PC_BRANCH:   pc_jump = alu_result_E[0];
      default:     pc_jump = 1'b1;
    endcase
  end
  assign ex_mem.data.alu_result_M = alu_result_E;
  assign ex_mem.data.wdata_M = src_B;

  hard_code u_hard_code (
    .addr(id_ex.data.ext_imm_E),
    .data(ex_mem.data.hard_code_M)
  );

  assign ex_mem.data.ctrl_M = id_ex.data.ctrl_E;
  assign ex_mem.data.rd_M = id_ex.data.rd_E;
  assign ex_mem.data.ext_imm_M = id_ex.data.ext_imm_E;
  assign ex_mem.data.pc_plus_1_M = id_ex.data.pc_plus_1_E;

  assign pc_target_E = id_ex.data.ext_imm_E + (id_ex.data.ctrl_E.jump_base_src ? srcA : id_ex.data.pc_E);

  assign rd_E = id_ex.data.rd_E;
  assign rs1_E = id_ex.data.rs1_E;
  assign rs2_E = id_ex.data.rs2_E;
endmodule

`default_nettype wire
