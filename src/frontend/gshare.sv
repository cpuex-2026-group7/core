`timescale 1ns / 1ps
`default_nettype none

module gshare #(
    parameter int GSHARE_ENTRY_SIZE = 128,
    parameter int GHR_SIZE = 16,
    parameter int FETCH_W = 2
) (
    input wire logic clk,
    input wire logic rst,

    input wire types::pc_t req_pc,
    input wire logic [GHR_SIZE-1:0] ghr,
    output frontend_pkg::bpd_resp_t resp,

    input wire frontend_pkg::gshare_idx_t upd_req_idx,
    input wire logic [FETCH_W-1:0] upd_req_taken,
    input wire logic upd_req_valid
);

  logic [FETCH_W-1:0] gshare_table_p[GSHARE_ENTRY_SIZE];
  logic [FETCH_W-1:0] gshare_table_h[GSHARE_ENTRY_SIZE];

  localparam int IDX_W = $clog2(GSHARE_ENTRY_SIZE);
  localparam int PC_W  = $bits(types::pc_t);

  function automatic logic [IDX_W-1:0] hash_pc_ghr(input types::pc_t pc,
                                                   input logic [GHR_SIZE-1:0] hist);
    logic [IDX_W-1:0] hash;
    hash = '0;
    for (int offset = 0; offset < PC_W; offset = offset + IDX_W) begin
      hash = hash ^ IDX_W'(pc >> offset);
    end
    for (int offset = 0; offset < GHR_SIZE; offset = offset + IDX_W) begin
      hash = hash ^ IDX_W'(hist >> offset);
    end
    return hash;
  endfunction

  logic [IDX_W-1:0] hashed_PC;
  always_comb begin : calc_hashed_pc
    hashed_PC = hash_pc_ghr(req_pc, ghr);
  end

  always_ff @(posedge clk) begin : calc_resp
    resp.gshare_idx <= hashed_PC;
    resp.taken <= gshare_table_p[hashed_PC];
  end

  always_ff @(posedge clk) begin : update_pht
    if (rst) begin
      // initialize to 01.
      for (int i = 0; i < GSHARE_ENTRY_SIZE; i++) begin
        gshare_table_p[i] <= '0;
        gshare_table_h[i] <= '1;
      end
    end else begin
      if (upd_req_valid) begin
        for (int i = 0; i < FETCH_W; i++) begin
          if (~upd_req_taken[i]) gshare_table_p[upd_req_idx][i] <= gshare_table_h[upd_req_idx][i];
          gshare_table_h[upd_req_idx][i] <= upd_req_taken[i];
        end
      end
    end
  end

endmodule

`default_nettype wire
