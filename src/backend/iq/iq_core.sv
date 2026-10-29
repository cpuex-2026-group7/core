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

endmodule

`default_nettype wire
