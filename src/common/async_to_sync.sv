`timescale 1ns / 1ps
`default_nettype none

// ボタンとかスイッチとかに一旦FF噛ませて同期された信号にする

module async_to_sync #(
  parameter int W = 1
) (
  input wire logic clk,
  input wire logic [W-1:0] async,  // 非同期な入力
  output logic [W-1:0] sync
);
  (* ASYNC_REG = "TRUE" *) logic [W-1:0] s0 = '0, s1 = '0;
  always_ff @(posedge clk) begin
    s0 <= async;
    s1 <= s0;
  end

  assign sync = s1;
endmodule

`default_nettype wire
