`timescale 1ns / 1ps
`default_nettype none

module issue_queue
  import back_types::*;
#(
  parameter int SIZE = 16,
  parameter int DISPATCH_W = 1,
  parameter int ISSUE_W = 1,
  parameter int DEST_FU_NUM = 1,
  parameter logic [DEST_FU_NUM-1:0][ISSUE_W-1:0] FU_TO_PORT = '0,
  parameter int WAKEUP_W = 5,
  parameter int PAYLOAD_W = 64
) (
  input wire logic clk

  // with dispatch
  input wire logic disp_valid[DISPATCH_W],

);

  localparam latency_t LAT_SLOW = 4'd0;
  localparam latency_t LAT_1    = 4'd1;
  localparam latency_t LAT_2    = 4'd2;
  localparam latency_t LAT_3    = 4'd3;
  localparam latency_t LAT_4    = 4'd4;
  localparam latency_t LAT_5    = 4'd5;

    localparam dest_fu_t FU_F_SHORT = 3'd0;
  localparam dest_fu_t FU_F_LONG  = 3'd1;
  localparam dest_fu_t FU_F_DIV   = 3'd2;
  localparam dest_fu_t FU_F_SQRT  = 3'd3;

endmodule

`default_nettype wire
