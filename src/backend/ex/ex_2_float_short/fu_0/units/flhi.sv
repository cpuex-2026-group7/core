`timescale 1ns / 1ps
`default_nettype none

module flhi
  import types::*;
(
  input wire logic       clk,
  input wire logic [4:0] aux,

  output word_t result
);

  logic [4:0] aux_ff;

  always_ff @(posedge clk) begin
    aux_ff <= aux;
  end

endmodule

`default_nettype wire
