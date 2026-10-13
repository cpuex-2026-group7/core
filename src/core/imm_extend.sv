`timescale 1ns / 1ps
`default_nettype none

module imm_extend
  import types::*;
  import isa::*;
(
  input wire instr_t instr,
  input wire imm_t imm_type,
  output word_t extended_imm
);

  always_comb begin
    unique case (imm_type)
      IMM_A: extended_imm = {instr[19:0], 12'b0};
      IMM_B: extended_imm = {{12{instr[19]}}, instr[19:0]};
      IMM_C: extended_imm = {{17{instr[14]}}, instr[14:0]};
      IMM_D: extended_imm = {{17{instr[24]}}, instr[24:20], instr[9:0]};
    endcase
  end

endmodule

`default_nettype wire
