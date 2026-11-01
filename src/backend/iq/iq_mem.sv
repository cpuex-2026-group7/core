`timescale 1ns / 1ps
`default_nettype none

module iq_mem
  import types::*;
  import uop_types::*;
  import back_types::*;
  import iq_types::*;
#(
  parameter int SIZE = 16,
  parameter int DISPATCH_W = 1,
  parameter int WAKEUP_W = 5,
  parameter int BR_UPDATE_W = 1
) (
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush

  // dispatch
  input wire logic disp_valid[DISPATCH_W],
  input wire disp_uop_t disp_uop[DISPATCH_W],
  input wire src_state_t disp_rs1_st[DISPATCH_W],
  input wire src_state_t disp_rs2_st[DISPATCH_W],
  output logic disp_full,

  // wakeup bus
  input wire wakeup_t coming_wakeup[WAKEUP_W],
  output wakeup_t sending_wakeup[1],

  // ALUレーンのWBから
  input wire br_update_t br_update[BR_UPDATE_W],

  // to RR
  output iq_rr_t rr_ff[1],
  output mem_payload_t rr_payload[1]
);

  localparam int PAYLOAD_W = $bits(mem_payload_t);

  wrapper_ff_t disp_entry[DISPATCH_W];
  logic [PAYLOAD_W-1:0] disp_payload[DISPATCH_W];
  always_comb begin
    for (int i = 0; i < DISPATCH_W; i++) begin
      disp_entry[i].rd = disp_uop[i].rd;
      disp_entry[i].rs1.preg = disp_uop[i].rs1;
      disp_entry[i].rs1.st = disp_rs1_st[i];
      disp_entry[i].rs2.preg = disp_uop[i].rs2;
      disp_entry[i].rs2.st = disp_rs2_st[i];
      disp_entry[i].lat = disp_uop[i].lat;
      disp_entry[i].dest_fu = disp_uop[i].dest_fu;
      disp_entry[i].brmask = disp_uop[i].brmask;

      disp_payload[i] = mem_payload_t'{
        op: disp_uop[i].op,
        imm: disp_uop[i].imm,
        rob_idx: disp_uop[i].rob_idx,
        ldq_idx: disp_uop[i].ldq_idx,
        stq_idx: disp_uop[i].stq_idx
      };
    end
  end

  logic [PAYLOAD_W-1:0] rr_payload_raw[1];
  assign rr_payload[0] = mem_payload_t'(rr_payload_raw[0]);

  iq_core #(
    .SIZE(SIZE),
    .DISPATCH_W(DISPATCH_W),
    .ISSUE_W(1),
    .DEST_FU_NUM(1),
    .FU_LISTEN_PORT({1'b1}),
    .SLOW_WAKEUP_FU(1'b1),
    .BLOCKING_FU(1'b0),
    .WAKEUP_W(WAKEUP_W),
    .BR_UPDATE_W(BR_UPDATE_W),
    .PAYLOAD_W(PAYLOAD_W)
  ) u_iq_core_int (
    .clk  (clk),
    .rst  (rst),
    .flush(flush),

    .disp_valid(disp_valid),
    .disp_entry(disp_entry),
    .disp_payload(disp_payload),
    .disp_full(disp_full),
    .coming_wakeup(coming_wakeup),
    .sending_wakeup(sending_wakeup),
    .br_update(br_update),
    .dest_fu_blocked('{1'b0}),

    // to RR
    .rr_ff(rr_ff),
    .rr_payload(rr_payload_raw)
  );

endmodule

`default_nettype wire
