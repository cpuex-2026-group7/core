`timescale 1ns / 1ps
`default_nettype none

module seven_seg #(
  parameter int SCAN_BITS = 17
) (
  input  wire logic        clk,
  input  wire logic [31:0] value,
  output logic      [ 7:0] anode,         // どの桁をつけるか? (active low)
  output logic      [ 6:0] seg,           // 7segのパターン (active low)
  output logic             decimal_point  // 小数点 (active low)
);
  logic [SCAN_BITS-1:0] cnt = '0;
  always_ff @(posedge clk) cnt <= cnt + 1;

  logic [2:0] digit;
  assign digit = cnt[SCAN_BITS-1-:3];

  logic [3:0] num;
  logic [6:0] pattern;
  always_comb begin
    num   = value[digit*4+:4];
    anode = ~(8'd1 << digit);
    unique case (num)
      4'h0: pattern = 7'h3F;
      4'h1: pattern = 7'h06;
      4'h2: pattern = 7'h5B;
      4'h3: pattern = 7'h4F;
      4'h4: pattern = 7'h66;
      4'h5: pattern = 7'h6D;
      4'h6: pattern = 7'h7D;
      4'h7: pattern = 7'h07;
      4'h8: pattern = 7'h7F;
      4'h9: pattern = 7'h6F;
      4'hA: pattern = 7'h77;
      4'hB: pattern = 7'h7C;
      4'hC: pattern = 7'h39;
      4'hD: pattern = 7'h5E;
      4'hE: pattern = 7'h79;
      4'hF: pattern = 7'h71;
    endcase
    seg = ~pattern;
    decimal_point = 1'b1;  // 消灯
  end
endmodule

`default_nettype wire
