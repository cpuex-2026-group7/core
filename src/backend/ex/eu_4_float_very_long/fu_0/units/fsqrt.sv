`timescale 1ns / 1ps
`default_nettype none

module fsqrt
  import types::*;
(
  input wire logic  clk,
  input wire logic  rst,
  input wire logic  issued,
  input wire logic  abort,
  input wire word_t rs1_val,

  output logic  done,
  output word_t result
);

  logic  issued_ff;
  word_t rs1_ff;

  always_ff @(posedge clk) begin
    issued_ff <= !rst & issued;
    rs1_ff    <= rs1_val;
  end

endmodule

`default_nettype wire
