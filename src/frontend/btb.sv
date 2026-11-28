`timescale 1ns / 1ps
`default_nettype none

// TODO need fix; save only JALR
module btb
  import types::*;
#(
    parameter int FETCH_W = 2,
    parameter int BTB_ENTRY_SIZE = 128,
    parameter int BTB_TAG_WIDTH = 9
) (
    input wire logic clk,
    input wire logic rst,

    input wire pc_t pc,

    output frontend_pkg::btb_resp_t resp,

    input wire logic update_en,
    input wire frontend_pkg::btb_update_t btb_update
);

  frontend_pkg::btb_entry_t btb_entry[BTB_ENTRY_SIZE];

  frontend_pkg::btb_resp_t lookup_resp_F1;

  frontend_pkg::btb_idx_t pc_idx, btb_upd_idx;
  frontend_pkg::btb_tag_t pc_tag, btb_upd_tag;

  function automatic frontend_pkg::btb_idx_t get_idx(input types::pc_t pc);
    return pc[$clog2(BTB_ENTRY_SIZE)-1:0];
  endfunction

  function automatic frontend_pkg::btb_tag_t get_tag(input types::pc_t pc);
    return pc[BTB_TAG_WIDTH+$clog2(BTB_ENTRY_SIZE)-1:$clog2(BTB_ENTRY_SIZE)];
  endfunction

  assign resp = lookup_resp_F1;
  assign pc_idx = get_idx(pc);
  assign pc_tag = get_tag(pc);
  assign btb_upd_idx = get_idx(btb_update.pc);
  assign btb_upd_tag = get_tag(btb_update.pc);

  always_comb begin : find_entry
    lookup_resp_F1 = '0;
    if (btb_entry[pc_idx].valid && btb_entry[pc_idx].tag == pc_tag) begin
      lookup_resp_F1.hit = 1'b1;
      lookup_resp_F1.content = btb_entry[pc_idx];
    end
  end

  always_ff @(posedge clk) begin : update_btb_entries
    if (rst) begin
      for (int i = 0; i < BTB_ENTRY_SIZE; i++) begin
        btb_entry[i] <= '0;
      end
    end else if (update_en) begin
      btb_entry[btb_upd_idx].tag <= btb_upd_tag;
      btb_entry[btb_upd_idx].valid <= btb_update.valid;
      btb_entry[btb_upd_idx].target <= btb_update.target;
    end
  end

endmodule

`default_nettype wire
