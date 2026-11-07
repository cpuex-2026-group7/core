`timescale 1ns / 1ps
`default_nettype none

module fcsign
  import types::*;
(
  input wire logic       clk,
  input wire logic [1:0] aux,
  input wire word_t      rs1_val,

  output word_t result
);

  logic [1:0] aux_ff;
  word_t      rs1_ff;

  always_ff @(posedge clk) begin
    aux_ff <= aux;
    rs1_ff <= rs1_val;
  end

endmodule

`default_nettype wire
