`timescale 1ns / 1ps
`default_nettype none

module fu_float_short_top
  import types::*;
  import isa::*;
  import uop_types::*;
(
  input wire logic     clk,
  input wire word_t    rs1_val,
  input wire word_t    rs2_val,
  input wire opcode_t  op,
  input wire imm_raw_t imm,
  input wire pc_t      pc,

  output word_t result,
  output logic  taken,
  output pc_t   target
);

  opcode_t  op_q;
  imm_raw_t imm_q;
  pc_t      pc_q;

  always_ff @(posedge clk) begin
    op_q  <= op;
    imm_q <= imm;
    pc_q  <= pc;
  end

  logic  eq;
  logic  lt;
  word_t fli_result;
  word_t flhi_result;
  word_t fcsign_result;

  fcmp_eq u_fcmp_eq (
    .clk(clk),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .aux(op.id[0]),
    .result(eq)
  );

  fcmp_lt u_fcmp_lt (
    .clk(clk),
    .rs1_val(rs1_val),
    .rs2_val(rs2_val),
    .aux(op.id[0]),
    .result(lt)
  );

  fli u_fli (
    .clk(clk),
    .aux(imm),
    .result(fli_result)
  );

  flhi u_flhi (
    .clk(clk),
    .aux(imm[4:0]),
    .result(flhi_result)
  );

  fcsign u_fcsign (
    .clk(clk),
    .rs1_val(rs1_val),
    .aux(imm[1:0]),
    .result(fcsign_result)
  );

endmodule

`default_nettype wire
