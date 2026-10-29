`timescale 1ns / 1ps
`default_nettype none

module iq_core
  import types::*;
  import back_types::*;
  import iq_types::*;
#(
  parameter int SIZE = 16,
  parameter int DISPATCH_W = 1,
  parameter int ISSUE_W = 1,
  parameter int DEST_FU_NUM = 1,
  parameter logic [DEST_FU_NUM-1:0][ISSUE_W-1:0] FU_TO_PORT = '1,
  parameter int WAKEUP_W = 5,
  parameter int BR_UPDATE_W = 1,
  parameter int PAYLOAD_W = 64
) (
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush

  // wrapper
  input wire logic disp_valid[DISPATCH_W],
  input wire wrapper_ff_t disp_entry[DISPATCH_W],  // wrapper -> ff
  input wire logic [PAYLOAD_W-1:0] disp_payload[DISPATCH_W],
  output logic disp_full,

  // wakeup bus
  input wire wakeup_t coming_wakeup[WAKEUP_W],
  output wakeup_t sending_wakeup[ISSUE_W],

  // ALUレーンのWBから
  input wire br_update_t br_update[BR_UPDATE_W],

  // FU (fdiv,fsqrtのブロック用)
  input wire logic dest_fu_blocked[DEST_FU_NUM],
  output logic fired[ISSUE_W],
  output dest_fu_t fired_dest_fu[ISSUE_W],

  // to RR
  output iq_rr_t to_rr[ISSUE_W],
  output logic [PAYLOAD_W-1:0] rr_payload[ISSUE_W]
);

  localparam int IDX_W = (SIZE > 1) ? $clog2(SIZE) : 1;

  logic alloc_valid[DISPATCH_W];
  logic [IDX_W-1:0] alloc_slot[DISPATCH_W];
  logic [IDX_W-1:0] is_slot[ISSUE_W];
  logic [PAYLOAD_W-1:0] is_payload[ISSUE_W];

  multi_port_ram #(
    .SIZE(SIZE),
    .ENTRY_WIDTH(PAYLOAD_W),
    .R(ISSUE_W),
    .W(DISPATCH_W)
  ) iq_payload (
    .clk   (clk),
    .w_en  (alloc_valid),
    .w_addr(alloc_slot),
    .w_data(disp_payload),
    .r_addr(is_slot),
    .r_data(is_payload)
  );

  // rr_payloadはFFにしてRRで使わせる
  always_ff @(posedge clk) rr_payload <= is_payload;

  logic [SIZE-1:0] bitmap;
  always_ff @(posedge clk) begin
    if (rst || flush) bitmap <= '0;
    else begin
      for (int i = 0; i < SIZE; i++) begin
        if (alloc_valid[i]) bitmap[alloc_slot[i]] <= 1'b1;
        if (fired[i]) bitmap[is_slot[i]] <= 1'b0;
      end
    end
  end

  logic [DISPATCH_W-1:0] empty_found;

  find_empty_slot #(
    .SIZE(SIZE),
    .FIND_NUM(DISPATCH_W)
  ) find_empty_slot (
    .bitmap(bitmap),
    .found (empty_found),
    .slot  (alloc_slot)
  );

  assign disp_full = ~empty_found[DISPATCH_W-1];

endmodule

`default_nettype wire
