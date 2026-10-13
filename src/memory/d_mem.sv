`timescale 1ns / 1ps
`default_nettype none

module d_mem
  import types::*;
(
  input wire logic clk,
  input wire logic rst,
  input wire logic write_en,
  input wire addr_t addr,
  input wire word_t wdata,
  output word_t rdata
);

  (* ram_style = "block" *) word_t mem[1024];

  always_ff @(negedge clk) begin
    if (write_en) mem[addr[9:0]] <= wdata;
    rdata <= mem[addr[9:0]];
  end

endmodule

`default_nettype wire
