`timescale 1ns / 1ps
`default_nettype none

module i_mem
  import types::*;
  import isa::*;
(
  input wire logic clk,
  input wire logic en,
  input wire addr_t addr,
  output instr_t instr
);

  word_t mem[1024];
`ifdef VERILATOR
  initial begin
    string path;
    if (!$value$plusargs("imem=%s", path)) path = "fib.mem";
    $readmemh(path, mem);
  end
`else
  initial $readmemh("fib.mem", mem);
`endif
  always_ff @(posedge clk) begin
    if (en)
      instr <= instr_t'(mem[addr[9:0]]);
  end

endmodule

`default_nettype wire
