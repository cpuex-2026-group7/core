`timescale 1ns / 1ps
`default_nettype none

module issue_queue #(
  parameter int SIZE = 16,
  parameter int DISPATCH_W = 1,
  parameter int ISSUE_W = 1,
  parameter int DEST_FU_NUM = 1,
  parameter logic [DEST_FU_NUM-1:0][ISSUE_W-1:0] FU_TO_PORT = '0,
  parameter int WAKEUP_W = 5,
  parameter int PAYLOAD_W = 64
) (
  input wire logic clk
);

endmodule

`default_nettype wire
