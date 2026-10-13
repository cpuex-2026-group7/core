`timescale 1ns / 1ps
`default_nettype none

module top (
  input  wire logic        CLK100MHZ,
  input  wire logic        CPU_RESETN,
  input  wire logic [15:0] SW,
  input  wire logic        BTNC,
  input  wire logic        BTNU,
  input  wire logic        BTNL,
  input  wire logic        BTNR,
  input  wire logic        BTND,
  output logic      [15:0] LED,
  output logic      [ 7:0] AN,
  output logic             CA,
  output logic             CB,
  output logic             CC,
  output logic             CD,
  output logic             CE,
  output logic             CF,
  output logic             CG,
  output logic             DP,
  output logic             LED16_B,
  output logic             LED16_G,
  output logic             LED16_R,
  output logic             LED17_B,
  output logic             LED17_G,
  output logic             LED17_R,
  input  wire logic        UART_TXD_IN,
  output logic             UART_RXD_OUT
);

  // クロック生成
  logic clk_out1, clk_out2, locked;
  clk_wiz_0 clk_gen (
    .clk_out1(clk_out1),
    .clk_out2(clk_out2),
    .reset(1'b0),
    .locked(locked),
    .clk_in1(CLK100MHZ)
  );

  // 入力を同期にする
  logic reset_button, step_button;
  logic [6:0] switch;
  async_to_sync #(1) sync1 (
    .clk  (clk_out1),
    .async(CPU_RESETN),
    .sync (reset_button)
  );
  async_to_sync #(1) sync2 (
    .clk  (clk_out1),
    .async(SW[15]),
    .sync (step_button)
  );
  async_to_sync #(7) sync3 (
    .clk  (clk_out1),
    .async(SW[6:0]),
    .sync (switch)
  );
  logic rst;
  assign rst = ~reset_button;

  logic step_pulse;
  pulse_button u_btnr (
    .clk(clk_out1),
    .btn_in(BTNR),
    .pulse(step_pulse)
  );

  logic cpu_en;
  assign cpu_en = locked && (step_button ? step_pulse : 1'b1);

  // CPU
  logic [31:0] pc_dbg, reg_dbg_data;
  logic cpu_halted;
  core_top u_core (
    .clk         (clk_out1),
    .rst         (rst),
    .en          (cpu_en),
    .uart_rx     (UART_TXD_IN),
    .uart_tx     (UART_RXD_OUT),
    .pc_dbg      (pc_dbg),        // for debug
    .reg_dbg     (switch[5:0]),   // for debug
    .reg_dbg_data(reg_dbg_data),  // for debug
    .cpu_halted  (cpu_halted)     // for debug
  );


  // 7セグ表示
  logic [31:0] seg7_val;
  always_comb begin
    if (switch < 7'd64) seg7_val = reg_dbg_data;  // 0-63はレジスタ
    else if (switch == 7'd64) seg7_val = pc_dbg;  // 64はPC
    else seg7_val = 32'h0;  // 65-127は予約
  end

  logic [6:0] seg;
  seven_seg u_seg (
    .clk(clk_out1),
    .value(seg7_val),
    .anode(AN),
    .seg(seg),
    .decimal_point(DP)
  );
  assign {CG, CF, CE, CD, CC, CB, CA} = seg;

  // LED表示
  assign LED[14:0] = '0;
  assign LED[15] = SW[15];

  // RGB LED表示
  assign LED16_B = ~cpu_en && ~cpu_halted;
  assign LED16_G = cpu_en && ~cpu_halted;
  assign LED16_R = cpu_halted;
  assign LED17_B = 1'b0;
  assign LED17_G = 1'b0;
  assign LED17_R = 1'b0;
endmodule

`default_nettype wire
