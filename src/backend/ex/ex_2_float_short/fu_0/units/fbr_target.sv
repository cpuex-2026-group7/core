`timescale 1ns / 1ps
`default_nettype none

module fbr_target
  import types::*;
  import uop_types::*;
(
  input wire logic     clk,
  input wire imm_raw_t imm,
  input wire pc_t      pc,
  input wire pc_t      predict_pc,

  output pc_t  target,               // pc+D
  output logic taken_mispredict,     // target != predict_pc
  output logic not_taken_mispredict  // pc+1 != predict_pc
);

  imm_raw_t imm_ff;
  pc_t      pc_ff;
  pc_t      predict_pc_ff;

  always_ff @(posedge clk) begin
    imm_ff        <= imm;
    pc_ff         <= pc;
    predict_pc_ff <= predict_pc;
  end

endmodule

`default_nettype wire
