`timescale 1ns / 1ps
`default_nettype none

module ras #(
    parameter int RAS_SIZE = 8
) (
    input wire logic clk,
    input wire logic rst,

    input wire logic ras_push,
    input wire types::pc_t ras_push_pc,

    input wire logic ras_pop,

    output types::pc_t ras_target
);

  localparam int RAS_IDX_W = (RAS_SIZE > 1) ? $clog2(RAS_SIZE) : 1;
  typedef logic [RAS_IDX_W-1:0] ras_idx_t;
  localparam ras_idx_t LAST_IDX = ras_idx_t'(RAS_SIZE - 1);

  types::pc_t ras_entry[RAS_SIZE];
  ras_idx_t ras_head;  // index of the current top-of-stack entry
  ras_idx_t ras_head_next;
  ras_idx_t ras_head_prev;

  assign ras_head_next = (ras_head == LAST_IDX) ? '0 : ras_head + ras_idx_t'(1);
  assign ras_head_prev = (ras_head == '0) ? LAST_IDX : ras_head - ras_idx_t'(1);

  assign ras_target = ras_entry[ras_head];

  always_ff @(posedge clk) begin : update_ras
    if (rst) begin
      for (int i = 0; i < RAS_SIZE; i++) begin
        ras_entry[i] <= '0;
      end
      ras_head <= LAST_IDX;
    end else begin
      unique case ({ras_push, ras_pop})
        2'b10: begin
          ras_entry[ras_head_next] <= ras_push_pc;
          ras_head <= ras_head_next;
        end
        2'b01: begin
          ras_head <= ras_head_prev;
        end
        2'b11: begin
          ras_entry[ras_head] <= ras_push_pc;
        end
        default: ;
      endcase
    end
  end

endmodule
`default_nettype wire
