`timescale 1ns / 1ps
`default_nettype none

module fblt
  import types::*;
(
  input wire logic clk,
  input wire word_t rs1_val,
  input wire word_t rs2_val,
  input wire logic aux,  // 1でfbge

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

  logic rs1_zero, rs2_zero, lt;
  assign rs1_zero = (rs1_ff[30:0] == 31'd0);
  assign rs2_zero = (rs2_ff[30:0] == 31'd0);

  always_comb begin
    if (rs1_zero && rs2_zero) begin
      lt = 1'b0;  // -0 = +0は認める
    end else if (rs1_ff[31] != rs2_ff[31]) begin
      // 符号が違う
      lt = rs1_ff[31];
    end else begin
      // 符号が同じ
      lt = rs1_ff[31] ? (rs1_ff[30:0] > rs2_ff[30:0]) : (rs1_ff[30:0] < rs2_ff[30:0]);
    end
  end

  assign taken = aux_ff ? !lt : lt;

endmodule

`default_nettype wire
