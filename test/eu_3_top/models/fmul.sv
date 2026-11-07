`timescale 1ns / 1ps
`default_nettype none

// テスト用の fmul の代わり（fmul）
// 入口の FF から結果が出るまで LAT_FMUL + 1 段。中身は eu_3_model_pkg の m_fmul
module fmul
  import types::*;
  import uop_types::*;
  import eu_3_model_pkg::*;
(
  input wire logic  clk,
  input wire word_t rs1_val,
  input wire word_t rs2_val,

  output word_t result
);

  localparam int STAGES = LAT_FMUL + 1;

  word_t pipe_ff[STAGES];

  always_ff @(posedge clk) begin
    pipe_ff[0] <= m_fmul(rs1_val, rs2_val);
    for (int i = 1; i < STAGES; i++) pipe_ff[i] <= pipe_ff[i-1];
  end

  assign result = pipe_ff[STAGES-1];

endmodule

`default_nettype wire
