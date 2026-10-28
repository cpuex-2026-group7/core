`timescale 1ns / 1ps
`default_nettype none

module btb
  import types::*;
  #(
    parameter int TAG_WIDTH = 9,
    parameter int IDX_WIDTH = 7 // 2^IDX_WIDTH entries.
  )
(
  input wire logic clk,
  input wire logic rst,
  input wire addr_t pc,
  output frontend::btb_resp_t resp,
  input wire logic update_en,
  input wire addr_t update_pc,
  input wire addr_t update_target
);

  localparam int NENTRY = 2 ** IDX_WIDTH;

  logic [NENTRY-1:0] valid;
  logic [TAG_WIDTH-1:0] tags [NENTRY];
  addr_t targets [NENTRY];

  always_comb begin
    resp = '0;
    if (valid[pc[IDX_WIDTH-1:0]] && tags[pc[IDX_WIDTH-1:0]] == pc[IDX_WIDTH+TAG_WIDTH-1:IDX_WIDTH]) begin
      resp.valid = 1'b1;
      resp.target = targets[pc[IDX_WIDTH-1:0]];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      valid <= '0;
    end else if (update_en) begin
      valid[update_pc[IDX_WIDTH-1:0]] <= 1'b1;
      tags[update_pc[IDX_WIDTH-1:0]] <= update_pc[IDX_WIDTH+TAG_WIDTH-1:IDX_WIDTH];
      targets[update_pc[IDX_WIDTH-1:0]] <= update_target;
    end
  end

endmodule

`default_nettype wire
