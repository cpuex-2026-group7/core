`timescale 1ns / 1ps
`default_nettype none

module fdiv
  import types::*;
(
  input wire logic  clk,
  input wire logic  rst,
  input wire logic  start,
  input wire logic  abort,
  input wire word_t rs1_val,
  input wire word_t rs2_val,

  output logic  busy,
  output logic  done,
  output word_t result
);

  logic  start_ff;
  word_t rs1_ff;
  word_t rs2_ff;

  always_ff @(posedge clk) begin
    start_ff <= !rst & start;
    rs1_ff   <= rs1_val;
    rs2_ff   <= rs2_val;
  end

endmodule

`default_nettype wire
