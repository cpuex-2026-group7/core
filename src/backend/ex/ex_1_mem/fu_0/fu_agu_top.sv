`timescale 1ns / 1ps
`default_nettype none

module fu_agu_top
  import types::*;
  import uop_types::*;
(
  input wire logic     clk,
  input wire word_t    rs1_val,
  input wire word_t    rs2_val,
  input wire logic     is_store,
  input wire imm_raw_t imm,

  output addr_t addr,
  output word_t data
);

  agu u_agu (
    .clk(clk),
    .aux(is_store),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .imm(imm),
    .addr(addr),
    .data(data)
  );

endmodule

`default_nettype wire
