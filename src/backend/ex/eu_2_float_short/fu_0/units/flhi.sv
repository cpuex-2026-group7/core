`timescale 1ns / 1ps
`default_nettype none

module flhi
  import types::*;
(
  input wire logic       clk,
  input wire logic [4:0] aux,

  output word_t result
);

  logic [4:0] aux_ff;

  always_ff @(posedge clk) begin
    aux_ff <= aux;
  end

  always_comb begin
    case (aux_ff)
      5'd0: result = 32'hbe4ccccd;  // -0.2
      5'd1: result = 32'hbdcccccd;  // -0.1
      5'd2: result = 32'h38d1b717;  // 1.0e-4
      5'd3: result = 32'h3c23d70a;  // 0.01
      5'd4: result = 32'h3c8efa35;  // 0.017453293
      5'd5: result = 32'h3d4ccccd;  // 0.05
      5'd6: result = 32'h3dcccccd;  // 0.1
      5'd7: result = 32'h3e19999a;  // 0.15
      5'd8: result = 32'h3e4ccccd;  // 0.2
      5'd9: result = 32'h3e99999a;  // 0.3
      5'd10: result = 32'h3f666666;  // 0.9
      5'd11: result = 32'h40490fdb;  // 3.1415927
      5'd12: result = 32'h4cbebc20;  // 1.0e8
      5'd13: result = 32'h4e6e6b28;  // 1.0e9
      default: result = 32'h0;
    endcase
  end

endmodule

`default_nettype wire
