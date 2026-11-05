`timescale 1ns / 1ps
`default_nettype none

module iq_mem
  import types::*;
  import isa::*;
  import ooo_types::*;
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
  output mem_payload_t rr_payload[1],
  output logic [1:0] rr_issue_part[1]  // 0:STA/LDA 1:STD
);

  localparam int PAYLOAD_W = $bits(mem_payload_t);

  wrapper_ff_t disp_entry[DISPATCH_W];
  logic [PAYLOAD_W-1:0] disp_payload[DISPATCH_W];
  logic [1:0] to_issue_part[DISPATCH_W];
  always_comb begin
    for (int i = 0; i < DISPATCH_W; i++) begin
      to_issue_part[i] = (disp_uop[i].op.eff == EFF_MEM) ? 2'b11 : 2'b01;
      disp_entry[i].rd = disp_uop[i].rd;
      disp_entry[i].rs1.preg = disp_uop[i].rs1;
      disp_entry[i].rs1.st = disp_rs1_st[i];
      disp_entry[i].rs2.preg = disp_uop[i].rs2;
      disp_entry[i].rs2.st = disp_rs2_st[i];
      disp_entry[i].lat = disp_uop[i].lat;
      disp_entry[i].dest_eu = disp_uop[i].dest_eu;
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
    .EU_BASE(EU_MEM),
    .SLOW_WAKEUP_FU(4'b0001),
    .BLOCKING_FU(4'b0000),
    .WAKEUP_W(WAKEUP_W),
    .BR_UPDATE_W(BR_UPDATE_W),
    .PAYLOAD_W(PAYLOAD_W),
    .ALLOW_SPLIT_ISSUE(1'b1)
  ) u_iq_core_mem (
    .clk  (clk),
    .rst  (rst),
    .flush(flush),

    .disp_valid(disp_valid),
    .disp_entry(disp_entry),
    .disp_payload(disp_payload),
    .to_issue_part(to_issue_part),
    .disp_full(disp_full),
    .coming_wakeup(coming_wakeup),
    .sending_wakeup(sending_wakeup),
    .br_update(br_update),
    .dest_fu_blocked(4'b0000),

    // to RR
    .rr_ff(rr_ff),
    .rr_payload(rr_payload_raw),
    .rr_issue_part(rr_issue_part)
  );

endmodule

`default_nettype wire
