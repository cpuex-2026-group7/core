`timescale 1ns / 1ps
`default_nettype none

module stage_wb
  import types::*;
(
  input wire addr_t pc_plus_1_F,
  input wire addr_t pc_target_E,
  input wire logic pc_jump_E,
  output word_t result_W,
  output rf_idx_t rd_W,
  output logic reg_we_W,
  mem_wb_if.cons mem_wb,
  wb_if_if.prod wb_if
);

  assign rd_W = mem_wb.data.rd_W;
  assign reg_we_W = mem_wb.data.ctrl_W.reg_we;
  assign wb_if.data.pc_F = pc_jump_E ? pc_target_E : pc_plus_1_F;

  always_comb begin
    unique case (mem_wb.data.ctrl_W.result_src)
      RES_ALU: result_W = mem_wb.data.alu_result_W;
      RES_FPU: result_W = mem_wb.data.fpu_result_W;
      RES_MEM: result_W = mem_wb.data.rdata_W;
      RES_IMM: result_W = mem_wb.data.ext_imm_W;
      RES_HARD_CODE: result_W = mem_wb.data.hard_code_W;
      RES_PC_PLUS_ONE: result_W = mem_wb.data.pc_plus_1_W;
    endcase
  end

endmodule

`default_nettype wire
