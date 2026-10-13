`timescale 1ns / 1ps
`default_nettype none

module alu
  import types::*;
  import isa::*;
(
  input wire word_t src1,
  input wire word_t src2,
  input wire alu_op_t alu_op,
  output word_t result
);

  word_t add, sub;
  logic eq, lt, cmp_true;
  assign add = src1 + src2;
  assign sub = src1 - src2;
  assign eq = (src1 == src2);
  assign lt = ($signed(src1) < $signed(src2));
  assign cmp_true = (alu_op[1] ? lt : eq) ^ alu_op[0];

  always_comb begin
    unique case (alu_op)
      ALU_ADD: result = add;
      ALU_SUB: result = sub;
      default: result = {31'b0, cmp_true};
    endcase
  end

endmodule

`default_nettype wire
