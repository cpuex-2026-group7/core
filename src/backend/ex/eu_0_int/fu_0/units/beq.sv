`timescale 1ns / 1ps
`default_nettype none

module beq
  import types::*;
(
  input wire logic clk,
  input wire word_t rs1_val,
  input wire word_t rs2_val,
  input wire logic aux,  // 1でbne

  output logic taken
);

  word_t rs1_ff;
  word_t rs2_ff;
  logic  aux_ff;

  always_ff @(posedge clk) begin
    rs1_ff <= rs1_val;
    rs2_ff <= rs2_val;
    aux_ff <= aux;
  end

  logic eq;
  assign eq = (rs1_ff == rs2_ff);
  assign taken = (aux_ff ? !eq : eq);

endmodule

`default_nettype wire
