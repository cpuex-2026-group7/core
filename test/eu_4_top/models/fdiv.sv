`timescale 1ns / 1ps
`default_nettype none

// テスト用の fdiv の代わり（非パイプライン）
// issued のサイクルから eu_4_model_pkg の lat_fdiv サイクル後に done を 1 サイクル出す。
// abort が来たら次のサイクルから idle（abort のサイクルに done が出ることはある）。
// 演算中に issued が来たら n_protocol_error を数える（テストベンチが見る）
module fdiv
  import types::*;
  import eu_4_model_pkg::*;
(
  input wire logic  clk,
  input wire logic  rst,
  input wire logic  issued,
  input wire logic  abort,
  input wire word_t rs1_val,
  input wire word_t rs2_val,

  output logic  done,
  output word_t result
);

  logic  busy_ff;
  int    cnt_ff;
  word_t result_ff;
  int    n_protocol_error = 0;

  always_ff @(posedge clk) begin
    if (rst) begin
      busy_ff <= 1'b0;
    end else begin
      if (issued && busy_ff && !abort) n_protocol_error <= n_protocol_error + 1;
      if (abort) begin
        busy_ff <= 1'b0;
      end else if (issued) begin
        busy_ff   <= 1'b1;
        cnt_ff    <= lat_fdiv(rs1_val, rs2_val) - 1;
        result_ff <= m_fdiv(rs1_val, rs2_val);
      end else if (busy_ff) begin
        if (cnt_ff == 0) busy_ff <= 1'b0;
        else cnt_ff <= cnt_ff - 1;
      end
    end
  end

  assign done   = busy_ff && cnt_ff == 0;
  assign result = result_ff;

endmodule

`default_nettype wire
