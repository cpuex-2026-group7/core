`timescale 1ns / 1ps
`default_nettype none

module pc_plus_1_eu_2
  import types::*;
(
  input wire logic clk,
  input wire pc_t  pc,

  output pc_t result  // pc+1
);

  pc_t pc_ff;

  always_ff @(posedge clk) begin
    pc_ff <= pc;
  end

  assign result = pc_ff + 16'd1;

endmodule

`default_nettype wire
