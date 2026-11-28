`timescale 1ns / 1ps
`default_nettype none

module nlp_top #(
    parameter int FETCH_W = 2,
    parameter int BTB_ENTRY_SIZE = 128,
    parameter int BTB_TAG_WIDTH = 9,
    parameter int RAS_SIZE = 8
) (
    input wire logic clk,
    input wire logic rst,

    input wire types::pc_t nlp_pc_key,
    output frontend_pkg::nlp_resp_t nlp_resp_F2,
    output frontend_pkg::nlp_resp_t nlp_resp_F1,
    input wire logic nlp_pipeline_en,

    // btb_io
    input wire logic btb_update_en,
    input wire frontend_pkg::btb_update_t btb_update,

    // ras_io
    input wire logic ras_push,
    input wire types::pc_t ras_push_pc,
    input wire logic ras_pop,
    output logic ras_empty,
    output logic ras_full
);

  frontend_pkg::btb_resp_t btb_resp;
  types::pc_t ras_target;
  types::pc_t nlp_pc_key_F1;

  btb #(
      .FETCH_W(FETCH_W),
      .BTB_ENTRY_SIZE(BTB_ENTRY_SIZE),
      .BTB_TAG_WIDTH(BTB_TAG_WIDTH)
  ) u_btb (
      .clk(clk),
      .rst(rst),
      .pc(nlp_pc_key_F1),
      .resp(btb_resp),
      .update_en(btb_update_en),
      .btb_update(btb_update)
  );

  ras #(
      .RAS_SIZE(RAS_SIZE)
  ) u_ras (
      .clk(clk),
      .rst(rst),
      .ras_push(ras_push),
      .ras_push_pc(ras_push_pc),
      .ras_pop(ras_pop),
      .ras_target(ras_target),
      .ras_empty(ras_empty),
      .ras_full(ras_full)
  );

  assign nlp_resp_F1.valid = btb_resp.hit;
  assign nlp_resp_F1.taken = btb_resp.hit ?
        (btb_resp.content.jmp ? 1'b1 : bim_get_resp_taken) : 1'b0;

  assign nlp_resp_F1.target = btb_resp.hit ?
        (btb_resp.content.ret ? ras_target : btb_resp.content.target) : '0;

  always_ff @(posedge clk) begin : pipeline
    if (rst) begin
      nlp_resp_F2   <= '0;
      nlp_pc_key_F1 <= '0;
    end else if (nlp_pipeline_en) begin
      nlp_resp_F2   <= nlp_resp_F1;
      nlp_pc_key_F1 <= nlp_pc_key;
    end
  end

endmodule
`default_nettype wire
