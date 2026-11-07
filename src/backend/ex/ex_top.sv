`timescale 1ns / 1ps
`default_nettype none

module ex_top
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import rr_types::*;
  import ex_types::*;
(
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush

  // RRから
  input wire rr_ex_int_t   rr_ex_int[1],
  input wire rr_ex_mem_t   rr_ex_mem[1],
  input wire rr_ex_float_t rr_ex_fpu[3],

  // RFへ
  output ex_wb_t wb_alu[1],
  output ex_wb_t wb_fpu[3],

  // LSUへ
  output ex_lsu_t lsu_ff[1],

  // 全体へ(FF)
  output br_update_t br_update_ff,

  // IQへ
  output wakeup_t slow_wakeup_fpu,
  output logic fdiv_blocked,
  output logic fsqrt_blocked
);

  localparam int BR_EU_NUM = 2;  // ALU, F短

  br_result_t br_result[BR_EU_NUM];

  ex_int_top u_ex_int_top (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .rr_ex(rr_ex_int[0]),
    .br_update_ff(br_update_ff),
    .to_wb(wb_alu[0]),
    .br_result(br_result[0])
  );

  ex_mem_top u_ex_mem_top (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .rr_ex(rr_ex_mem[0]),
    .br_update_ff(br_update_ff),
    .lsu_ff(lsu_ff[0])
  );

  ex_float_short_top u_ex_float_short_top (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .rr_ex(rr_ex_fpu[0]),
    .br_update_ff(br_update_ff),
    .to_wb(wb_fpu[0]),
    .br_result(br_result[1])
  );

  ex_float_long_top u_ex_float_long_top (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .rr_ex(rr_ex_fpu[1]),
    .br_update_ff(br_update_ff),
    .to_wb(wb_fpu[1])
  );

  ex_float_very_long_top u_ex_float_very_long_top (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .rr_ex(rr_ex_fpu[2]),
    .br_update_ff(br_update_ff),
    .to_wb(wb_fpu[2]),
    .slow_wakeup(slow_wakeup_fpu),
    .fdiv_blocked(fdiv_blocked),
    .fsqrt_blocked(fsqrt_blocked)
  );

  // 分岐をまとめる
  br_update_t n_br_update;

  always_comb begin
    n_br_update = '0;
    // maskに入れる
    for (int i = 0; i < BR_EU_NUM; i++) begin
      if (br_result[i].valid) begin
        if (br_result[i].mispredict) n_br_update.kill_mask[br_result[i].tag] = 1'b1;
        else n_br_update.resolve_mask[br_result[i].tag] = 1'b1;
      end
    end
    for (int i = 0; i < BR_EU_NUM; i++) begin
      // 他のmispredictした分岐に依存しない一番古い分岐について...
      if (br_result[i].valid && br_result[i].mispredict && !(|(br_result[i].brmask & n_br_update.kill_mask))) begin
        // 復帰用データをセット
        n_br_update.mispredict = 1'b1;
        n_br_update.tag = br_result[i].tag;
        n_br_update.taken = br_result[i].taken;
        n_br_update.pc = br_result[i].pc;
        n_br_update.target = br_result[i].target;
        n_br_update.rob_idx = br_result[i].rob_idx;
      end
    end
  end

  always_ff @(posedge clk) begin
    br_update_ff <= (rst | flush) ? '0 : n_br_update;
  end

endmodule

`default_nettype wire
