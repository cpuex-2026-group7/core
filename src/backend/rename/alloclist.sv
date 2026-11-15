`timescale 1ns / 1ps
`default_nettype none

module alloclist #(
    parameter int MAX_BR = 8,
    parameter int PREG_W = 64
) (
    // mask for alloclist update target
    input wire logic clk,
    input wire logic rst,

    input wire logic br_alive[MAX_BR],
    input wire logic [PREG_W-1:1] alloc_preg_I,
    input wire logic [PREG_W-1:1] alloc_preg_F,

    input wire ooo_types::br_tag_t get_br,
    output logic [PREG_W-1:1] out_alloclist_I,
    output logic [PREG_W-1:1] out_alloclist_F
);

  // FF bit vector.
  logic [PREG_W-1:1] alloclist_I[MAX_BR];
  logic [PREG_W-1:1] alloclist_F[MAX_BR];

  assign out_alloclist_I = alloclist_I[get_br];
  assign out_alloclist_F = alloclist_F[get_br];

  always_ff @(posedge clk) begin : update_alloc_list
    if (rst) begin
      for (int i = 0; i < MAX_BR; ++i) begin
        alloclist_I[i] <= '0;
        alloclist_F[i] <= '0;
      end
    end else begin
      for (int i = 0; i < MAX_BR; ++i) begin
        if (br_alive[i]) begin
          alloclist_I[i] <= alloclist_I[i] | alloc_preg_I;
          alloclist_F[i] <= alloclist_F[i] | alloc_preg_F;
        end
      end
    end
  end


endmodule

`default_nettype wire
