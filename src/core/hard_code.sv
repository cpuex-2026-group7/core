`timescale 1ns / 1ps
`default_nettype none

module hard_code
  import types::*;
(
  input wire addr_t addr,
  output word_t data
);

  logic [31:0] idx;
  assign idx  = addr & 32'h0000003F;  // 0~63
  assign data = idx;

endmodule

`default_nettype wire
