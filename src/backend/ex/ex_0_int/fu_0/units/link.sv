`timescale 1ns / 1ps
`default_nettype none

module link
  import types::*;
(
  input wire logic clk,
  input wire pc_t  pc,

  output word_t result  // pc+1
);

  pc_t pc_ff;

  always_ff @(posedge clk) begin
    pc_ff <= pc;
  end

endmodule

`default_nettype wire
