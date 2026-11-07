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

  word_t      rs1_q;
  logic [1:0] aux_q;

  always_ff @(posedge clk) begin
    rs1_q <= rs1_val;
    aux_q <= aux;
  end

endmodule

`default_nettype wire
