`timescale 1ns / 1ps
`default_nettype none

// bitmapからFIND_NUM個の空きスロットを探す
module find_empty_slot #(
  parameter int SIZE = 16,
  parameter int FIND_NUM = 1
) (
  input wire logic [SIZE-1:0] bitmap,  // 1: used, 0: empty
  output logic found[FIND_NUM],  // 1: found, 0: not
  output logic [((SIZE>1)?$clog2(SIZE) : 1)-1:0] slot[FIND_NUM]  // found slot num
);

  localparam int IDX_W = (SIZE > 1) ? $clog2(SIZE) : 1;

  function automatic logic [IDX_W-1:0] onehot_to_idx(input logic [SIZE-1:0] onehot);
    onehot_to_idx = '0;
    for (int i = 0; i < SIZE; i++) begin
      if (onehot[i]) onehot_to_idx |= IDX_W'(i);
    end
  endfunction

  function automatic logic [SIZE-1:0] reverse(input logic [SIZE-1:0] x);
    for (int i = 0; i < SIZE; i++) reverse[i] = x[SIZE-1-i];
  endfunction

  logic [SIZE-1:0] empty;
  assign empty = ~bitmap;

  generate
    // 上からと下から
    if (FIND_NUM == 2) begin : g_find_two
      logic [SIZE-1:0] low_oh;
      logic [SIZE-1:0] high_oh;
      logic [SIZE-1:0] empty_rev;

      assign empty_rev = reverse(empty);
      assign low_oh = empty & (-empty);
      assign high_oh = reverse(empty_rev & (-empty_rev));

      assign found[0] = |empty;
      assign found[1] = (|empty) && (low_oh != high_oh);
      assign slot[0] = onehot_to_idx(low_oh);
      assign slot[1] = onehot_to_idx(high_oh);
    end else begin : g_find_many
      // 一番下の1を消すのを繰り返す
      for (genvar d = 0; d < FIND_NUM; d++) begin : g_each
        logic [SIZE-1:0] cur;
        logic [SIZE-1:0] onehot;
        if (d == 0) begin : g_first
          assign cur = empty;
        end else begin : g_next
          assign cur = g_each[d-1].cur & (g_each[d-1].cur - 1'b1);
        end
        assign onehot   = cur & (-cur);
        assign found[d] = |cur;
        assign slot[d]  = onehot_to_idx(onehot);
      end
    end
  endgenerate

endmodule

`default_nettype wire
