`timescale 1ns / 1ps
`default_nettype none

module fcmp_lt
  import types::*;
(
  input wire logic  clk,
  input wire word_t rs1_val,
  input wire word_t rs2_val,
  input wire logic  aux,  // 1で結果を反転

  output logic result
);

  word_t rs1_q;
  word_t rs2_q;
  logic  aux_q;

  always_ff @(posedge clk) begin
    rs1_q <= rs1_val;
    rs2_q <= rs2_val;
    aux_q <= aux;
  end

endmodule

`default_nettype wire
