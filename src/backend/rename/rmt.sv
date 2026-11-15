`timescale 1ns / 1ps
`default_nettype none

module rmt #(
    parameter int LREG_COUNT = 64,
    parameter int DISPATCH_W = 2,
    parameter int MAX_BR = 8
) (
    input wire logic clk,
    input wire logic rst,

    input wire logic mispredict,
    input wire ooo_types::br_tag_t brtag,
    input wire ooo_types::preg_t rmt_snapshot[MAX_BR][LREG_COUNT],

    input wire types::rf_idx_t rd_reqr [DISPATCH_W],
    input wire types::rf_idx_t rs1_reqr[DISPATCH_W],
    input wire types::rf_idx_t rs2_reqr[DISPATCH_W],

    output ooo_types::preg_t rd_respr [DISPATCH_W],
    output ooo_types::preg_t rs1_respr[DISPATCH_W],
    output ooo_types::preg_t rs2_respr[DISPATCH_W],

    input wire types::rf_idx_t   key_reqw  [DISPATCH_W],
    input wire ooo_types::preg_t value_reqw[DISPATCH_W],
    input wire logic             valid_reqw[DISPATCH_W]
);
  // assume that LREG_COUNT_I = LREG_COUNT_F
  localparam int LREG_COUNT_I = LREG_COUNT / 2;

  types::rf_idx_t req_read[3 * DISPATCH_W];
  ooo_types::preg_t resp_read[3 * DISPATCH_W];

  // FF array.
  ooo_types::preg_t rmt_entry[LREG_COUNT];

  always_comb begin : assign_read_result
    for (int i = 0; i < DISPATCH_W; i++) begin
      rd_respr[i]  = rmt_entry[rd_reqr[i]];
      rs1_respr[i] = rmt_entry[rs1_reqr[i]];
      rs2_respr[i] = rmt_entry[rs2_reqr[i]];
    end
  end

  always_ff @(posedge clk) begin : update_entry
    if (rst) begin
      // initialize all mapping to zeroreg
      for (int i = 0; i < LREG_COUNT_I; i++) begin
        rmt_entry[i].typ <= ooo_types::PREG_TYPE_I;
        rmt_entry[i].idx <= '0;
      end
      for (int i = LREG_COUNT_I; i < LREG_COUNT; i++) begin
        rmt_entry[i].typ <= ooo_types::PREG_TYPE_F;
        rmt_entry[i].idx <= '0;
      end
    end else if (mispredict) begin
      for (int i = 0; i < LREG_COUNT; i++) begin
        rmt_entry[i] <= rmt_snapshot[brtag][i];
      end
    end else begin
      for (int i = 0; i < DISPATCH_W; i++) begin
        if (valid_reqw[i]) rmt_entry[key_reqw[i]] <= value_reqw[i];
      end
    end
  end

endmodule

`default_nettype wire
