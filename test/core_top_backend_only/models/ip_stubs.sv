`timescale 1ns / 1ps
`default_nettype none

// Vivado の IP の代わり（シミュレーションできないので形だけ）

// クロックは入力をそのまま出す。テストは CLK_HZ を UART のボーレートの計算にだけ使う
module clk_wiz_core (
  output logic clk_out1,
  output logic clk_out2,
  output logic locked,
  input  wire logic reset,
  input  wire logic clk_in1
);
  assign clk_out1 = clk_in1;
  assign clk_out2 = clk_in1;
  assign locked = ~reset;
endmodule

// 以下は SIM_MODE=1 では使われないが、Verilator がモジュールの定義を要求するので置く
module fifo_generator_0 (
  input  wire logic rst,
  input  wire logic wr_clk,
  input  wire logic rd_clk,
  input  wire logic [155:0] din,
  input  wire logic wr_en,
  input  wire logic rd_en,
  output logic [155:0] dout,
  output logic full,
  output logic empty
);
  assign dout = '0;
  assign full = 1'b0;
  assign empty = 1'b1;
endmodule

module fifo_generator_1 (
  input  wire logic rst,
  input  wire logic wr_clk,
  input  wire logic rd_clk,
  input  wire logic [127:0] din,
  input  wire logic wr_en,
  input  wire logic rd_en,
  output logic [127:0] dout,
  output logic full,
  output logic empty
);
  assign dout = '0;
  assign full = 1'b0;
  assign empty = 1'b1;
endmodule

module mig_7series_0 (
  output wire [12:0] ddr2_addr,
  output wire [2:0] ddr2_ba,
  output wire ddr2_cas_n,
  output wire [0:0] ddr2_ck_n,
  output wire [0:0] ddr2_ck_p,
  output wire [0:0] ddr2_cke,
  output wire ddr2_ras_n,
  output wire ddr2_we_n,
  inout  wire [15:0] ddr2_dq,
  inout  wire [1:0] ddr2_dqs_n,
  inout  wire [1:0] ddr2_dqs_p,
  output wire [0:0] ddr2_cs_n,
  output wire [1:0] ddr2_dm,
  output wire [0:0] ddr2_odt,
  input  wire logic [26:0] app_addr,
  input  wire logic [2:0] app_cmd,
  input  wire logic app_en,
  output logic app_rdy,
  input  wire logic [127:0] app_wdf_data,
  input  wire logic app_wdf_end,
  input  wire logic [15:0] app_wdf_mask,
  input  wire logic app_wdf_wren,
  output logic app_wdf_rdy,
  output logic [127:0] app_rd_data,
  output logic app_rd_data_end,
  output logic app_rd_data_valid,
  input  wire logic app_sr_req,
  input  wire logic app_ref_req,
  input  wire logic app_zq_req,
  output logic app_sr_active,
  output logic app_ref_ack,
  output logic app_zq_ack,
  output logic init_calib_complete,
  output logic ui_clk,
  output logic ui_clk_sync_rst,
  input  wire logic sys_clk_i,
  input  wire logic sys_rst
);
  assign {ddr2_addr, ddr2_ba, ddr2_cas_n, ddr2_ck_n, ddr2_ck_p, ddr2_cke, ddr2_ras_n, ddr2_we_n} = '0;
  assign {ddr2_cs_n, ddr2_dm, ddr2_odt} = '0;
  assign {app_rdy, app_wdf_rdy, app_rd_data, app_rd_data_end, app_rd_data_valid} = '0;
  assign {app_sr_active, app_ref_ack, app_zq_ack, init_calib_complete, ui_clk_sync_rst} = '0;
  assign ui_clk = sys_clk_i;
endmodule

`default_nettype wire
