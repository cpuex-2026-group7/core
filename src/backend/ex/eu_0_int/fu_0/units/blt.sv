`timescale 1ns / 1ps
`default_nettype none

module blt
  import types::*;
(
  input wire logic clk,
  input wire word_t rs1_val,
  input wire word_t rs2_val,
  input wire logic aux,  // 1でbge

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

  logic lt;
  assign lt = ($signed(rs1_ff) < $signed(rs2_ff));
  assign taken = (aux_ff ? !lt : lt);

endmodule

`default_nettype wire
