`timescale 1ns / 1ps
`default_nettype none

module fcmp_eq
  import types::*;
(
  input wire logic  clk,
  input wire logic  aux,  // 1で結果を反転(fbne)
  input wire word_t rs1_val,
  input wire word_t rs2_val,

  output logic taken
);

  logic  aux_ff;
  word_t rs1_ff;
  word_t rs2_ff;

  always_ff @(posedge clk) begin
    aux_ff <= aux;
    rs1_ff <= rs1_val;
    rs2_ff <= rs2_val;
  end

endmodule

`default_nettype wire
