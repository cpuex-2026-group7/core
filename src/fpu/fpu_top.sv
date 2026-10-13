`timescale 1ns / 1ps
`default_nettype none

module fpu_top
  import types::*;
  import isa::*;
(
  input wire word_t src1,
  input wire word_t src2,
  input wire fpu_op_t fpu_op,
  output word_t result
);

  always_comb begin
    unique case (fpu_op)
      FPU_CVT_S_W: result = 32'd0;
      FPU_SQRT:    result = 32'd1;
      FPU_NEG:     result = 32'd2;
      FPU_ABS:     result = 32'd3;
      FPU_ADD:     result = 32'd4;
      FPU_SUB:     result = 32'd5;
      FPU_MUL:     result = 32'd6;
      FPU_DIV:     result = 32'd7;
      FPU_CVT_W_S: result = 32'd8;
      FPU_EQ:      result = 32'd9;
      FPU_LT:      result = 32'd10;
      default:     result = 32'd11;
    endcase
  end

endmodule

`default_nettype wire
