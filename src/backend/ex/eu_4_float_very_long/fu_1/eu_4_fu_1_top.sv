`timescale 1ns / 1ps
`default_nettype none

module eu_4_fu_1_top
  import types::*;
(
  input wire logic  clk,
  input wire logic  rst,
  input wire logic  issued,
  input wire logic  abort_ff,
  input wire word_t rs1_val,
  input wire word_t rs2_val,

  output logic  done,
  output word_t result
);

  fdiv u_fdiv (
    .clk(clk),
    .rst(rst),
    .issued(issued),
    .abort_ff(abort_ff),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .done(done),
    .result(result)
  );

endmodule

`default_nettype wire
