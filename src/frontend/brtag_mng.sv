`timescale 1ns / 1ps
`default_nettype none

module brtag_mng #(
    parameter int MAX_BR = 8,
    parameter int DISPATCH_W = 2
) (
    input wire logic rst,
    input wire logic clk,

    input wire logic [DISPATCH_W-1:0] req,
    output ooo_types::br_tag_t resp[DISPATCH_W],
    output logic [DISPATCH_W-1:0] resp_valid,

    // squashed_brtag_mask[i] = |(brmask[i] & kill_mask)
    // return_mask = resolve_mask | kill_mask | squashed_brtag_mask
    input wire logic [MAX_BR-1:0] return_mask,

    output logic [MAX_BR-1:0] brmask[DISPATCH_W],
    output logic empty
);

  logic [MAX_BR-1:0] brtag_freelist;
  logic [MAX_BR-1:0] remaining;
  logic [MAX_BR-1:0] selected_onehot[DISPATCH_W];
  ooo_types::br_tag_t selected_num[DISPATCH_W];

  assign empty = ~(|brtag_freelist);

  always_comb begin : find_entry
    remaining  = brtag_freelist;
    resp_valid = '0;
    for (int i = 0; i < DISPATCH_W; i++) begin
      brmask[i] = ~remaining;
      if (req[i]) begin
        selected_onehot[i] = remaining & (~remaining + 1);
        remaining = remaining & ~selected_onehot[i];
        resp_valid[i] = |selected_onehot[i];
      end
    end
  end

  generate
    for (genvar i = 0; i < DISPATCH_W; ++i) begin : gen_one_hot_enc
      one_hot_enc #(
          .SIZE(MAX_BR)
      ) u_one_hot_enc (
          .onehot(selected_onehot[i]),
          .num(selected_num[i])
      );
    end
  endgenerate

  always_comb begin : finalize
    for (int i = 0; i < DISPATCH_W; i++) begin
      resp[i] = selected_num[i];
    end
  end

  always_ff @(posedge clk) begin : update_list
    if (rst) begin
      brtag_freelist <= '1;
    end else begin
      brtag_freelist <= remaining | return_mask;
    end
  end

endmodule

`default_nettype wire
