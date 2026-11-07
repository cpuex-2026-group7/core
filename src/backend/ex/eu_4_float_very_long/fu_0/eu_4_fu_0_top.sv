`timescale 1ns / 1ps
`default_nettype none

module eu_4_fu_0_top
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

  fsqrt u_fsqrt (
    .clk(clk),
    .rst(rst),
    .issued(issued),
    .abort(abort),
    .rs1_val(rs1_val),
    .done(done),
    .result(result)
  );

endmodule

`default_nettype wire
