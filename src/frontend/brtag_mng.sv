`timescale 1ns / 1ps
`default_nettype none

module brtag_mng #(
    parameter int MAX_BR  = 8,
    parameter int FETCH_W = 2
) (
    input wire logic rst,
    input wire logic clk,

    input wire logic [FETCH_W-1:0] req,
    output ooo_types::br_tag_t resp[FETCH_W],
    output logic [FETCH_W-1:0] resp_valid,

    // squashed_brtag_mask[i] = |(brmask[i] & kill_mask)
    // return_mask = resolve_mask | kill_mask | squashed_brtag_mask
    input wire ooo_types::brmask_t resolve_mask,
    input wire ooo_types::brmask_t kill_mask,

    output ooo_types::brmask_t brmask[FETCH_W],
    output logic empty
);

  // 分岐命令のbrtag
  ooo_types::brmask_t brmask_storage[MAX_BR];
  logic [MAX_BR-1:0] brtag_freelist;
  logic [MAX_BR-1:0] remaining;
  logic [MAX_BR-1:0] selected_onehot[FETCH_W];
  ooo_types::br_tag_t selected_num[FETCH_W];

  ooo_types::brmask_t return_mask;
  ooo_types::brmask_t squashed_brtag_mask;

  assign empty = ~(|brtag_freelist);
  assign return_mask = resolve_mask | kill_mask | squashed_brtag_mask;

  always_comb begin : calc_sqbrtag_mask
    for (int i = 0; i < MAX_BR; i++) begin
      squashed_brtag_mask[i] = |(brmask_storage[i] & kill_mask);
    end
  end

  always_comb begin : find_entry
    remaining  = brtag_freelist;
    resp_valid = '0;
    for (int i = 0; i < FETCH_W; i++) begin
      brmask[i] = ~remaining;
      selected_onehot[i] = '0;
      if (req[i]) begin
        selected_onehot[i] = remaining & (~remaining + 1);
        remaining = remaining & ~selected_onehot[i];
        resp_valid[i] = |selected_onehot[i];
      end
    end
  end

  generate
    for (genvar i = 0; i < FETCH_W; ++i) begin : gen_one_hot_enc
      one_hot_enc #(
          .SIZE(MAX_BR)
      ) u_one_hot_enc (
          .onehot(selected_onehot[i]),
          .num(selected_num[i])
      );
    end
  endgenerate

  always_comb begin : finalize
    for (int i = 0; i < FETCH_W; i++) begin
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

  always_ff @(posedge clk) begin : update_brmask_storage
    if (rst) begin
      for (int i = 0; i < MAX_BR; i++) begin
        brmask_storage[i] <= '0;
      end
    end else begin
      for (int i = 0; i < MAX_BR; i++) begin
        brmask_storage[i] <= brmask_storage[i] & ~resolve_mask;
      end
      for (int i = 0; i < FETCH_W; i++) begin
        if (resp_valid[i]) begin
          brmask_storage[resp[i]] <= brmask[i] & ~resolve_mask;
        end
      end
    end
  end

endmodule

`default_nettype wire
