`timescale 1ns / 1ps
`default_nettype none

module eu_4_fu_1_top
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

  fdiv u_fdiv (
    .clk(clk),
    .rst(rst),
    .start(start),
    .abort(abort),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .busy(busy),
    .done(done),
    .result(result)
  );

endmodule

`default_nettype wire
