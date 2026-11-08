`timescale 1ns / 1ps
`default_nettype none

module fbeq
  import types::*;
(
  input wire logic clk,
  input wire word_t rs1_val,
  input wire word_t rs2_val,
  input wire logic aux,  // 1でfbne

  output logic taken
);

  word_t rs1_ff;
  word_t rs2_ff;
  logic  aux_ff;

  always_ff @(posedge clk) begin
    rs1_ff <= rs1_val;
    rs2_ff <= rs2_val;
    aux_ff <= aux;
  end

  logic rs1_zero, rs2_zero, eq;
  assign rs1_zero = (rs1_ff[30:0] == 31'd0);
  assign rs2_zero = (rs2_ff[30:0] == 31'd0);
  assign eq = (rs1_ff == rs2_ff) || (rs1_zero && rs2_zero);  // -0 = +0は認める

  assign taken = aux_ff ? !eq : eq;
endmodule

`default_nettype wire
