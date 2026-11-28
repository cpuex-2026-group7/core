`timescale 1ns / 1ps
`default_nettype none

// ひとまず、backend redirectのときにfrontend
// が使用するための専用読み出しポートを用意
// する。汎用ポートは消すことになる気がする。

module ftq #(
    parameter int IDX_WIDTH = 5
) (
    input wire logic clk,
    input wire logic rst,

    input wire frontend_pkg::ftq_data_t din,
    input wire logic push,

    output ooo_types::ftq_idx_t next_ftq_idx,

    input wire logic [IDX_WIDTH-1:0] ftq_idx_req_redirect,
    output frontend_pkg::ftq_data_t ftq_resp_redirect,

    input wire logic pop,

    output logic full,
    output logic empty,

    input wire logic restore_en,
    input wire logic [IDX_WIDTH-1:0] restore_idx
);

  localparam int NENTRY = 2 ** IDX_WIDTH;

  frontend_pkg::ftq_data_t data[NENTRY];

  assign ftq_resp_redirect = data[ftq_idx_req_redirect];

  logic [IDX_WIDTH-1:0] ptr_head, ptr_tail, ptr_head_next, ptr_tail_next;
  assign ptr_head_next = ptr_head + IDX_WIDTH'(1);
  assign ptr_tail_next = ptr_tail + IDX_WIDTH'(1);

  assign next_ftq_idx = ptr_tail;

  assign full = ptr_head == ptr_tail_next;
  assign empty = ptr_head == ptr_tail;

  logic do_push;
  assign do_push = push & !full & !restore_en; // reject push from F3 on backend redirect because F3 should be flushed.
  logic do_pop;
  assign do_pop = pop & !empty;

  always_ff @(posedge clk) begin
    if (rst) begin
      ptr_head <= IDX_WIDTH'(0);
      ptr_tail <= IDX_WIDTH'(0);
    end else begin
      if (do_push) begin
        data[ptr_tail] <= din;
        ptr_tail <= ptr_tail_next;
      end
      if (do_pop) begin
        ptr_head <= ptr_head_next;
      end
      if (restore_en) begin
        ptr_tail <= restore_idx + IDX_WIDTH'(1);
      end
    end
  end

endmodule

`default_nettype wire
