`timescale 1ns / 1ps
`default_nettype none

module fcsign
  import types::*;
(
  input wire logic        clk,
  input wire word_t       rs1_val,
  input wire logic  [1:0] aux,

  output word_t result
);

  word_t       rs1_ff;
  logic  [1:0] aux_ff;

  always_ff @(posedge clk) begin
    rs1_ff <= rs1_val;
    aux_ff <= aux;
  end

  always_comb begin
    case (aux_ff)
      2'b00:   result = rs1_ff;  // x
      2'b01:   result = {~rs1_ff[31], rs1_ff[30:0]};  // -x
      2'b10:   result = {1'b0, rs1_ff[30:0]};  // |x|
      default: result = {1'b1, rs1_ff[30:0]};  // -|x|
    endcase
  end

endmodule

`default_nettype wire
