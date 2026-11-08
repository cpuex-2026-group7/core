`timescale 1ns / 1ps
`default_nettype none

module fbr_target
  import types::*;
(
  input wire logic clk,
  input wire pc_t  pc,
  input wire pc_t  ofs,

  output pc_t target
);

  pc_t pc_ff;
  pc_t ofs_ff;

  always_ff @(posedge clk) begin
    pc_ff  <= pc;
    ofs_ff <= ofs;
  end

  assign target = pc_ff + ofs_ff;

endmodule

`default_nettype wire
