`timescale 1ns / 1ps
`default_nettype none

// 2 bit saturating counter.
module bim #(
    parameter int BIM_ENTRY_SIZE = 256
) (
    input wire logic clk,
    rst,

    input wire types::pc_t get_req_key_pc,
    output logic get_resp_taken,

    input wire logic upd_req_valid,
    input wire types::pc_t upd_req_key_pc,
    input wire logic upd_req_taken
);

  logic [1:0] bim_entry[BIM_ENTRY_SIZE];
  frontend_pkg::bim_idx_t get_req_key, upd_req_key;

  function automatic frontend_pkg::bim_idx_t get_idx(input types::pc_t pc);
    return pc[$clog2(BIM_ENTRY_SIZE)-1:0];
  endfunction

  assign get_req_key = get_idx(get_req_key_pc);
  assign upd_req_key = get_idx(upd_req_key_pc);

  assign get_resp_taken = bim_entry[get_req_key][1];

  always_ff @(posedge clk) begin : update_table
    if (rst) begin
      for (int i = 0; i < BIM_ENTRY_SIZE; i++) begin
        bim_entry[i] <= 2'b01;
      end
    end else begin
      if (upd_req_valid) begin
        if (upd_req_taken) begin
          bim_entry[upd_req_key] <= bim_entry[upd_req_key] == 2'b11 ? 
             2'b11 : bim_entry[upd_req_key] + 2'b01;
        end else begin
          bim_entry[upd_req_key] <= bim_entry[upd_req_key] == 2'b00 ?
             2'b00 : bim_entry[upd_req_key] - 2'b01;
        end
      end
    end
  end

endmodule
`default_nettype wire
