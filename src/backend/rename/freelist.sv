`timescale 1ns / 1ps
`default_nettype none

// free list (bitvector)

// 1'b1 represents free slot.

// TODO alloc list support

// assumes NUM_PREG_I = NUM_PREG_F
// if you want to let them be different,
// just disable entries by assigning zeros to freelist.
module freelist #(
    parameter int PREG_W = 64,
    parameter int DISPATCH_W = 2,
    parameter int MAX_BR = 8
) (
    input wire logic rst,
    input wire logic clk,

    input wire logic mispredict,
    input wire ooo_types::br_tag_t brtag,

    input wire logic br_alive[MAX_BR],

    input wire ooo_types::preg_type_t req_alloc[DISPATCH_W],
    output wire ooo_types::preg_t resp_alloc[DISPATCH_W],
    output wire logic [DISPATCH_W-1:0] resp_valid,

    // idk if DISPATCH_W is suitable here.
    input wire ooo_types::preg_t req_return[DISPATCH_W],

    output wire logic empty_I,
    output wire logic empty_F
);

  logic [PREG_W-1:1] alloc_list_I;
  logic [PREG_W-1:1] alloc_list_F;

  // bitvector. 1'b1 represents free slot
  logic [PREG_W-1:1] free_list_I;
  logic [PREG_W-1:1] free_list_F;

  // remaining slots after allocation
  logic [PREG_W-1:1] remaining_I;
  logic [PREG_W-1:1] remaining_F;

  logic [PREG_W-1:1] alloc_preg_I;
  logic [PREG_W-1:1] alloc_preg_F;
  logic [PREG_W-1:1] selected_onehot[DISPATCH_W];
  ooo_types::preg_idx_t selected_num[DISPATCH_W];

  logic [PREG_W-1:0] req_return_idx_onehot[DISPATCH_W];
  logic [PREG_W-1:1] req_return_idx_mask_I;
  logic [PREG_W-1:1] req_return_idx_mask_F;

  assign empty_I = ~(|free_list_I);
  assign empty_F = ~(|free_list_F);

  alloclist #(
      .MAX_BR(MAX_BR),
      .PREG_W(PREG_W)
  ) u_alloc_list (
      .clk(clk),
      .rst(rst),
      .br_alive(br_alive),
      .alloc_preg_I(alloc_preg_I),
      .alloc_preg_F(alloc_preg_F),
      .get_br(brtag),
      .out_alloclist_I(alloc_list_I),
      .out_alloclist_F(alloc_list_F)
  );

  // naive priroity encoder; room for improvement.
  always_comb begin : find_entry
    remaining_I  = free_list_I;
    remaining_F  = free_list_F;
    alloc_preg_I = '0;
    alloc_preg_F = '0;
    for (int i = 0; i < DISPATCH_W; ++i) begin
      unique case (req_alloc[i])
        ooo_types::PREG_TYPE_I: begin
          selected_onehot[i] = remaining_I & (~remaining_I + 1'b1);
          remaining_I = remaining_I & ~selected_onehot[i];
          resp_valid[i] = |selected_onehot[i];
          alloc_preg_I = alloc_preg_F | selected_onehot[i];
        end
        ooo_types::PREG_TYPE_F: begin
          selected_onehot[i] = remaining_F & (~remaining_F + 1'b1);
          remaining_F = remaining_F & ~selected_onehot[i];
          resp_valid[i] = |selected_onehot[i];
          alloc_preg_F = alloc_preg_F | selected_onehot[i];
        end
        ooo_types::PREG_TYPE_NONE: begin
          selected_onehot[i] = '0;
          resp_valid[i] = 1'b0;
        end
        default: begin
          selected_onehot[i] = '0;
          resp_valid[i] = 1'b0;


`ifndef SYNTHESIS
          $warning("Unexpected case at freelist.sv/find_entry");
`endif
        end
      endcase
    end
  end

  // assumes PREG_COUNT_I = PREG_COUNT_F
  generate
    for (genvar i = 0; i < DISPATCH_W; ++i) begin : gen_one_hot_enc
      one_hot_enc #(
          .SIZE(PREG_W)
      ) u_one_hot_enc (
          .onehot({selected_onehot[i], 1'b0}),
          .num(selected_num[i])
      );

      one_hot_dec #(
          .SIZE(PREG_W)
      ) u_one_hot_dec (
          .num(req_return[i].idx),
          .onehot(req_return_idx_onehot[i])
      );
    end
  endgenerate

  always_comb begin : finalize
    for (int i = 0; i < DISPATCH_W; ++i) begin
      resp_alloc[i].typ = req_alloc[i];
      resp_alloc[i].idx = selected_num[i];
    end
  end

  always_comb begin : calc_ret_mask
    req_return_idx_mask_I = '0;
    req_return_idx_mask_F = '0;
    for (int i = 0; i < DISPATCH_W; ++i) begin
      unique case (req_return[i].typ)
        ooo_types::PREG_TYPE_I: begin
          req_return_idx_mask_I |= req_return_idx_onehot[i][PREG_W-1:1];
        end
        ooo_types::PREG_TYPE_F: begin
          req_return_idx_mask_F |= req_return_idx_onehot[i][PREG_W-1:1];
        end
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk) begin : update_freelist
    if (rst) begin
      free_list_I <= '1;
      free_list_F <= '1;
    end else if (mispredict) begin
      free_list_I <= free_list_I | alloc_list_I;
      free_list_F <= free_list_F | alloc_list_F;
    end else begin
      free_list_I <= remaining_I | req_return_idx_mask_I;
      free_list_F <= remaining_F | req_return_idx_mask_F;
    end
  end

endmodule

`default_nettype wire
