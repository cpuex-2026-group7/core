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

  logic [SIZE-1:0] bitmap;
  logic [SIZE-1:0] n_bitmap;
  logic [DISPATCH_W-1:0] empty_found;
  logic [IDX_W-1:0] alloc_slot[DISPATCH_W];

  // empty slot
  find_empty_slot #(
    .SIZE(SIZE),
    .FIND_NUM(DISPATCH_W)
  ) find_empty_slot (
    .bitmap(bitmap),
    .found (empty_found),
    .slot  (alloc_slot)
  );

  assign disp_full = ~empty_found[DISPATCH_W-1];

  logic alloc_valid[DISPATCH_W];
  logic [IDX_W-1:0] issue_slot[ISSUE_W];

  // bitmap更新
  always_comb begin
    for (int i = 0; i < DISPATCH_W; i++) begin
      alloc_valid[i] = disp_valid[i] && empty_found[i];
    end

    n_bitmap = bitmap;
    if (rst || flush) n_bitmap = '0;
    else begin
      for (int i = 0; i < DISPATCH_W; i++) begin
        if (alloc_valid[i] && empty_found[i]) n_bitmap[alloc_slot[i]] = 1'b1;
      end
      for (int i = 0; i < ISSUE_W; i++) begin
        if (fired[i]) n_bitmap[issue_slot[i]] = 1'b0;
      end
    end
  end

  always_ff @(posedge clk) bitmap <= n_bitmap;

  logic [PAYLOAD_W-1:0] iq_payload[ISSUE_W];

  // payload
  multi_port_ram #(
    .SIZE(SIZE),
    .ENTRY_WIDTH(PAYLOAD_W),
    .R(ISSUE_W),
    .W(DISPATCH_W)
  ) payload_ram (
    .clk   (clk),
    .w_en  (alloc_valid),
    .w_addr(alloc_slot),
    .w_data(disp_payload),
    .r_addr(issue_slot),
    .r_data(iq_payload)
  );

  // rr_payloadはFFにしてRRで使わせる
  always_ff @(posedge clk) rr_payload <= iq_payload;

  // FF
  wrapper_ff_t iq_ff  [SIZE];
  wrapper_ff_t n_iq_ff[SIZE];

  always_comb begin
    n_iq_ff = iq_ff;
    // ff更新
  end

  always_ff @(posedge clk) begin
    for (int i = 0; i < SIZE; i++) iq_ff[i] <= n_iq_ff[i];
  end

endmodule

`default_nettype wire
