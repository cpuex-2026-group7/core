`timescale 1ns / 1ps
`default_nettype none

// 押されたら1クロックだけ1のパルス出すボタン

module pulse_button #(
  parameter int STABLE_BITS = 16
) (
  input wire logic clk,
  input wire logic btn_in,
  output logic pulse
);
  logic button_sync;
  async_to_sync to_sync (
    .clk,
    .async(btn_in),
    .sync (button_sync)
  );

  logic pushed = 1'b0;
  logic [STABLE_BITS-1:0] cnt = '0;
  always_ff @(posedge clk) begin
    if (!button_sync) begin
      pushed <= 1'b0;
      cnt    <= '0;
    end else begin
      cnt <= cnt + 1;
      if (&cnt) begin  // 全bitが1でpush判定
        pushed <= 1'b1;
        cnt    <= '0;
      end
    end
  end

  logic [1:0] pushed_hist = '0;
  always_ff @(posedge clk) pushed_hist <= {pushed_hist[0], pushed};
  assign pulse = ~pushed_hist[1] & pushed_hist[0];
endmodule

`default_nettype wire
