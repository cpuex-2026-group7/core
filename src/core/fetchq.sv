`timescale 1ns / 1ps
`default_nettype none

module fetchq #(
    parameter int IDX_WIDTH = 5
) (
    input wire logic clk,
    input wire logic rst,

    input wire types::instr_t din,
    input wire logic push,

    output types::instr_t dout,
    input wire logic pop,

    output logic full,
    output logic empty
);

  localparam int NENTRY = 2 ** IDX_WIDTH;

  types::instr_t data[NENTRY];

  assign dout = data[ptr_head];

  logic [IDX_WIDTH-1:0] ptr_head, ptr_tail, ptr_head_next, ptr_tail_next;
  assign ptr_head_next = ptr_head + IDX_WIDTH'(1);
  assign ptr_tail_next = ptr_tail + IDX_WIDTH'(1);

  assign full = ptr_head == ptr_tail_next;
  assign empty = ptr_head == ptr_tail;

  logic do_push;
  assign do_push = push & !full;
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
    end
  end

endmodule

`default_nettype wire
