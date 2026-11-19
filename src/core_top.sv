`timescale 1ns / 1ps
`default_nettype none

module core_top #(
  parameter int CLK_HZ = 80_000_000,  // コアで使う周波数
  parameter bit SIM_MODE = 1'b0  // memory用
) (
  input  wire logic CLK100MHZ,
  input  wire logic CPU_RESETN,
  input  wire logic UART_TXD_IN,
  output logic      UART_RXD_OUT,

  // DDR2用
  output wire [12:0] ddr2_addr,
  output wire [ 2:0] ddr2_ba,
  output wire        ddr2_cas_n,
  output wire [ 0:0] ddr2_ck_n,
  output wire [ 0:0] ddr2_ck_p,
  output wire [ 0:0] ddr2_cke,
  output wire        ddr2_ras_n,
  output wire        ddr2_we_n,
  inout  wire [15:0] ddr2_dq,
  inout  wire [ 1:0] ddr2_dqs_n,
  inout  wire [ 1:0] ddr2_dqs_p,
  output wire [ 0:0] ddr2_cs_n,
  output wire [ 1:0] ddr2_dm,
  output wire [ 0:0] ddr2_odt
);
  localparam int DC_TAG_W = lsu_types::DC_TAG_W;
  localparam int MAX_BR   = ooo_types::MAX_BR;

  // クロック生成
  logic clk, mig_clk, locked;
  clk_wiz_core clk_gen (
    .clk_out1(clk),
    .clk_out2(mig_clk),
    .reset(1'b0),
    .locked(locked),  // 1のときクロックが安定中
    .clk_in1(CLK100MHZ)
  );

  // リセット
  logic rstn_ff;
  async_to_sync #(
    .W(1)
  ) sync_reset (
    .clk  (clk),
    .async(CPU_RESETN),
    .sync (rstn_ff)
  );

  logic mem_rstn_ff, core_rst_ff, boot_done;
  always_ff @(posedge clk) begin
    mem_rstn_ff <= rstn_ff && locked;
    core_rst_ff <= !(rstn_ff && locked) || !boot_done;
  end

  // D$
  logic dc_req_valid_ff;
  logic dc_req_we_ff;
  logic [31:0] dc_req_addr_ff;
  logic [31:0] dc_req_wdata_ff;
  logic [DC_TAG_W-1:0] dc_req_tag_ff;
  logic [MAX_BR-1:0] dc_req_brmask_ff;
  logic dc_req_accepted;
  logic dc_resp_valid_ff;
  logic dc_resp_ack_ff;
  logic [31:0] dc_resp_rdata_ff;
  logic [DC_TAG_W-1:0] dc_resp_tag_ff;
  logic [MAX_BR-1:0] dc_br_kill_mask_ff;
  logic [MAX_BR-1:0] dc_br_resolve_mask_ff;
  logic dc_kill_all_ff;

  backend_top u_backend_top (
    .clk(clk),
    .rst(core_rst_ff),
    .dc_req_valid_ff(dc_req_valid_ff),
    .dc_req_we_ff(dc_req_we_ff),
    .dc_req_addr_ff(dc_req_addr_ff),
    .dc_req_wdata_ff(dc_req_wdata_ff),
    .dc_req_tag_ff(dc_req_tag_ff),
    .dc_req_brmask_ff(dc_req_brmask_ff),
    .dc_req_accepted(dc_req_accepted),
    .dc_resp_valid_ff(dc_resp_valid_ff),
    .dc_resp_ack_ff(dc_resp_ack_ff),
    .dc_resp_rdata_ff(dc_resp_rdata_ff),
    .dc_resp_tag_ff(dc_resp_tag_ff),
    .dc_br_kill_mask_ff(dc_br_kill_mask_ff),
    .dc_br_resolve_mask_ff(dc_br_resolve_mask_ff),
    .dc_kill_all_ff(dc_kill_all_ff)
  );

  mem_top #(
    .CORE_CLK_HZ(CLK_HZ),
    .DC_TAG_W(DC_TAG_W),
    .MAX_BR(MAX_BR),
    .SIM_MODE(SIM_MODE)
  ) u_mem_top (
    .ddr2_addr(ddr2_addr),
    .ddr2_ba(ddr2_ba),
    .ddr2_cas_n(ddr2_cas_n),
    .ddr2_ck_n(ddr2_ck_n),
    .ddr2_ck_p(ddr2_ck_p),
    .ddr2_cke(ddr2_cke),
    .ddr2_ras_n(ddr2_ras_n),
    .ddr2_we_n(ddr2_we_n),
    .ddr2_dq(ddr2_dq),
    .ddr2_dqs_n(ddr2_dqs_n),
    .ddr2_dqs_p(ddr2_dqs_p),
    .ddr2_cs_n(ddr2_cs_n),
    .ddr2_dm(ddr2_dm),
    .ddr2_odt(ddr2_odt),
    .clk(clk),
    .mig_clk(mig_clk),
    .rstn(mem_rstn_ff),
    .uart_txd_in(UART_TXD_IN),
    .uart_rxd_out(UART_RXD_OUT),
    .boot_done(boot_done),
    .dc_req_valid_ff(dc_req_valid_ff),
    .dc_req_we_ff(dc_req_we_ff),
    .dc_req_addr_ff(dc_req_addr_ff),
    .dc_req_wdata_ff(dc_req_wdata_ff),
    .dc_req_tag_ff(dc_req_tag_ff),
    .dc_req_brmask_ff(dc_req_brmask_ff),
    .dc_br_kill_mask_ff(dc_br_kill_mask_ff),
    .dc_br_resolve_mask_ff(dc_br_resolve_mask_ff),
    .dc_kill_all_ff(dc_kill_all_ff),
    .dc_req_accepted(dc_req_accepted),
    .dc_resp_valid_ff(dc_resp_valid_ff),
    .dc_resp_ack_ff(dc_resp_ack_ff),
    .dc_resp_rdata_ff(dc_resp_rdata_ff),
    .dc_resp_tag_ff(dc_resp_tag_ff)
  );
endmodule

`default_nettype wire
