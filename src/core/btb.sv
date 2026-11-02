`timescale 1ns / 1ps
`default_nettype none

module btb
  import types::*;
#(
    parameter int TAG_WIDTH = 9,
    parameter int IDX_WIDTH = 7   // 2^IDX_WIDTH entries.
) (
    input wire logic clk,
    input wire logic rst,
    input wire logic en,
    input wire addr_t pc,
    output frontend_pkg::btb_resp_t resp,
    output frontend_pkg::btb_resp_t resp_F0,
    input wire logic update_en,
    input wire logic update_validness,
    input wire addr_t update_pc,
    input wire addr_t update_target
);

  localparam int NENTRY = 2 ** IDX_WIDTH;

  logic [NENTRY-1:0] valid;
  logic [TAG_WIDTH-1:0] tags[NENTRY];
  addr_t targets[NENTRY];

  addr_t pc_F1;
  frontend_pkg::btb_resp_t lookup_resp_F1;

  assign resp_F0 = lookup_resp_F1;

  always_comb begin
    lookup_resp_F1 = '0;
    if (valid[pc_F1[IDX_WIDTH-1:0]] &&
        tags[pc_F1[IDX_WIDTH-1:0]] == pc_F1[IDX_WIDTH+TAG_WIDTH-1:IDX_WIDTH]) begin
      lookup_resp_F1.valid  = 1'b1;
      lookup_resp_F1.target = targets[pc_F1[IDX_WIDTH-1:0]];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      pc_F1 <= '0;
      resp  <= '0;
    end else if (en) begin
      pc_F1 <= pc;
      resp  <= lookup_resp_F1;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      valid <= '0;
    end else if (update_en) begin
      valid[update_pc[IDX_WIDTH-1:0]] <= update_validness;
      tags[update_pc[IDX_WIDTH-1:0]] <= update_pc[IDX_WIDTH+TAG_WIDTH-1:IDX_WIDTH];
      targets[update_pc[IDX_WIDTH-1:0]] <= update_target;
    end
  end

endmodule

`default_nettype wire
