`timescale 1ns / 1ps
`default_nettype none

// テスト用の fadd の代わり（fadd / fsub）
// 入口の FF から結果が出るまで LAT_FADD + 1 段。中身は eu_3_model_pkg の m_fadd
module fadd
  import types::*;
  import uop_types::*;
  import eu_3_model_pkg::*;
(
  input wire logic  clk,
  input wire word_t rs1_val,
  input wire word_t rs2_val,
  input wire logic  aux,  // 1 で fsub

  output word_t result
);

  localparam int STAGES = LAT_FADD + 1;

  word_t pipe_ff[STAGES];

  always_ff @(posedge clk) begin
    pipe_ff[0] <= m_fadd(rs1_val, rs2_val, aux);
    for (int i = 1; i < STAGES; i++) pipe_ff[i] <= pipe_ff[i-1];
  end

  assign result = pipe_ff[STAGES-1];

endmodule

`default_nettype wire
