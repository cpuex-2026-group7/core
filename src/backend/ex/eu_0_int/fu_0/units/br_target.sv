`timescale 1ns / 1ps
`default_nettype none

module br_target
  import types::*;
  import uop_types::*;
(
  input wire logic        clk,
  input wire word_t       rs1_val,
  input wire pc_t         pc,
  input wire pc_t         ofs,
  input wire logic  [1:0] aux,      // 0x:branch, 10:jal, 11:jalr

  output pc_t target
);

  word_t       rs1_ff;
  pc_t         pc_ff;
  pc_t         ofs_ff;
  logic  [1:0] aux_ff;

  always_ff @(posedge clk) begin
    rs1_ff <= rs1_val;
    ofs_ff <= ofs;
    pc_ff  <= pc;
    aux_ff <= aux;
  end

  pc_t pc_plus_ofs;
  pc_t reg_plus_ofs;

  assign pc_plus_ofs = pc_ff + ofs_ff;
  assign reg_plus_ofs = rs1_ff + ofs_ff;
  assign target = (aux_ff == 2'b11) ? reg_plus_ofs : pc_plus_ofs;

endmodule

`default_nettype wire
