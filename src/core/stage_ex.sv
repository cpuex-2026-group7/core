`timescale 1ns / 1ps
`default_nettype none

module stage_ex
  import isa::*;
  import types::*;
(
  input word_t fpu_result_M,
  input word_t alu_result_M,
  input word_t hard_code_M,
  input word_t result_W,
  id_ex_if.cons id_ex,
  input logic forwardFA,
  input logic forwardFB,
  input logic forwardAA,
  input logic forwardAB,

  output addr_t pc_target_e,
  output logic pc_jump,
  ex_mem_if.prod ex_mem,
  output rf_idx_t rd_E,
  output rf_idx_t rs1_E,
  output rf_idx_t rs2_E
);

  word_t fpu_A, fpu_B;
  always_comb begin
    unique case (forwardFA)
      2'b00:   fpu_A = fpu_result_M;
      2'b01:   fpu_A = hard_code_M;
      2'b10:   fpu_A = id_ex.data.rdata1_E;
      default: fpu_A = result_W;
    endcase
    unique case (forwardFB)
      2'b00:   fpu_B = fpu_result_M;
      2'b01:   fpu_B = hard_code_M;
      2'b10:   fpu_B = id_ex.data.rdata2_E;
      default: fpu_B = result_W;
    endcase
  end

  fpu_top u_fpu (
    .src1  (fpu_A),
    .src2  (fpu_B),
    .alu_op(id_ex.data.ctrl_E.fpu_op),
    .result(ex_mem.data.fpu_result_M)
  );

  word_t alu_A, alu_B, alu_result_E;
  always_comb begin
    unique case (forwardFA)
      2'b00:   alu_A = alu_result_M;
      2'b01:   alu_A = id_ex.data.rdata1_E;
      default: alu_A = result_W;
    endcase
    unique case (forwardFB)
      2'b00:   alu_B = alu_result_M;
      2'b01:   alu_B = id_ex.data.rdata2_E;
      default: alu_B = result_W;
    endcase
  end

  alu u_alu (
    .src1  (alu_A),
    .src2  (id_ex.data.ctrl_E.alu_src_is_imm ? id_ex.data.ext_imm_E : alu_B),
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
  assign ex_mem.data.wdata_M = id_ex.data.ctrl_E.alu_or_fpu ? fpu_result_E : alu_result_E;


  hard_code u_hard_code (
    .addr(id_ex.data.ext_imm_E),
    .data(ex_mem.data.hard_code_M)
  );

  assign ex_mem.data.ctrl_M = id_ex.data.ctrl_E;
  assign ex_mem.data.rd_M = id_ex.data.rd_E;
  assign ex_mem.data.ext_imm_M = id_ex.data.ext_imm_E;
  assign ex_mem.data.pc_plus_1_M = id_ex.data.pc_plus_1_E;

  assign pc_target_e = id_ex.data.ext_imm_E + (id_ex.data.ctrl_E.jump_base_src ? id_ex.data.pc_E : id_ex.data.rdata1_E);

  assign rd_E = id_ex.data.rd_E;
  assign rs1_E = id_ex.data.rs1_E;
  assign rs2_E = id_ex.data.rs2_E;
endmodule

`default_nettype wire
