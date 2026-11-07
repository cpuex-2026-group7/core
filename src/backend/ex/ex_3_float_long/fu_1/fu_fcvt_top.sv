`timescale 1ns / 1ps
`default_nettype none

module fu_fcvt_top
  import types::*;
  import uop_types::*;
(
  input wire logic   clk,
  input wire word_t  rs1_val,
  input wire fu_op_t fu_op,

  output word_t result
);

  // 入口のFFから結果が出るまでのFFの段数
  localparam int STAGES = LAT_ITOF + 1;

  // 最後のmuxの選択用。unitの段数に合わせて流す
  logic [STAGES-1:0] is_ftoi_ff;

  always_ff @(posedge clk) begin
    is_ftoi_ff <= {is_ftoi_ff[STAGES-2:0], fu_op[0]};
  end

  word_t itof_result;
  word_t ftoi_result;

  itof u_itof (
    .clk(clk),
    .rs1_val(rs1_val),
    .result(itof_result)
  );

  ftoi u_ftoi (
    .clk(clk),
    .rs1_val(rs1_val),
    .result(ftoi_result)
  );

  assign result = is_ftoi_ff[STAGES-1] ? ftoi_result : itof_result;

endmodule

`default_nettype wire
