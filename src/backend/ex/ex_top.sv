`timescale 1ns / 1ps
`default_nettype none

module ex_top
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import rr_types::*;
  import ex_types::*;
#(
  parameter int BR_UPDATE_W = 1
) (
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush

  // RRから
  input wire rr_ex_int_t   ex_ff_int[1],
  input wire rr_ex_mem_t   ex_ff_mem[1],
  input wire rr_ex_float_t ex_ff_fpu[3],

  // EXから
  input wire br_update_t br_update[BR_UPDATE_W],

  // RFへ
  output ex_wb_t wb_alu[1],
  output ex_wb_t wb_fpu[3],

  // LSUへ
  output ex_lsu_t lsu_ff[1],

  // 全体へ
  output br_update_t br_update_out[BR_UPDATE_W],

  // IQへ
  output wakeup_t slow_wakeup_fpu,
  output logic fdiv_blocked,
  output logic fsqrt_blocked
);

  br_update_t br_update_fpu;

  ex_int_top #(
    .BR_UPDATE_W(BR_UPDATE_W)
  ) u_ex_int_top (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .ex_ff(ex_ff_int[0]),
    .br_update(br_update),
    .to_wb(wb_alu[0]),
    .br_update_out(br_update_out[0])
  );

  ex_mem_top #(
    .BR_UPDATE_W(BR_UPDATE_W)
  ) u_ex_mem_top (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .ex_ff(ex_ff_mem[0]),
    .br_update(br_update),
    .lsu_ff(lsu_ff[0])
  );

  ex_float_short_top #(
    .BR_UPDATE_W(BR_UPDATE_W)
  ) u_ex_float_short_top (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .ex_ff(ex_ff_fpu[0]),
    .br_update(br_update),
    .to_wb(wb_fpu[0]),
    .br_update_out(br_update_fpu)
  );

  if (BR_UPDATE_W > 1) begin : g_br_fpu
    assign br_update_out[1] = br_update_fpu;
  end

  ex_float_long_top #(
    .BR_UPDATE_W(BR_UPDATE_W)
  ) u_ex_float_long_top (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .ex_ff(ex_ff_fpu[1]),
    .br_update(br_update),
    .to_wb(wb_fpu[1])
  );

  ex_float_very_long_top #(
    .BR_UPDATE_W(BR_UPDATE_W)
  ) u_ex_float_very_long_top (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .ex_ff(ex_ff_fpu[2]),
    .br_update(br_update),
    .to_wb(wb_fpu[2]),
    .slow_wakeup(slow_wakeup_fpu),
    .fdiv_blocked(fdiv_blocked),
    .fsqrt_blocked(fsqrt_blocked)
  );

endmodule

`default_nettype wire
