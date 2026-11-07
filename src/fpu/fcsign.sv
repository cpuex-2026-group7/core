`timescale 1ns / 1ps
`default_nettype none

module fcsign
  import types::*;
(
  input wire logic       clk,
  input wire word_t      rs1_val,
  input wire logic [1:0] aux,

  output word_t result
);

  word_t      rs1_ff;
  logic [1:0] aux_ff;

  always_ff @(posedge clk) begin
    rs1_ff <= rs1_val;
    aux_ff <= aux;
  end

endmodule

`default_nettype wire
