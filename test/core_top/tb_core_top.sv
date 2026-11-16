`timescale 1ns / 1ps
`default_nettype none

// core_top のテスト（SIM_MODE=1 の memory で、UART からの boot と TX を見る）
//
// テストベンチがホスト（server.py）の役をする：
//   1. memory が 0x99 を送ってくる
//   2. プログラムのバイト数（4 バイト、little-endian）とプログラム（little-endian）を送る
//   3. memory が 0xaa を送ってくる
//   4. データ（little-endian）を送る。memory は無通信が続いたら受信完了とみなして boot_done を立てる
// boot の後は IMEM と DRAM の中身、コアのリセットが解けたことを確かめ、
// +cycles=N サイクル回して UART から出てきたバイトを全部表示する。
// まだ frontend などがつながっていないのでコアは命令を実行せず、TX は出ない。

module tb_core_top;
  // memory の SIM_MODE はデータ受信のタイムアウトが 200 クロックなので、1 バイト（10 bit）をそれより短くする
  localparam int BAUD = 115200;
  localparam int CLK_PER_BIT = 16;
  localparam int CLK_HZ = BAUD * CLK_PER_BIT;

  localparam int N_PROG = 8;  // プログラムのワード数
  localparam int N_DATA = 10;  // データのワード数（4 の倍数でなくして 0 埋めの経路も通す）

  logic clk = 1'b0;
  logic resetn = 1'b0;
  logic host_tx = 1'b1;  // ホスト → FPGA（UART_TXD_IN）
  logic host_rx;  // FPGA → ホスト（UART_RXD_OUT）

  wire [12:0] ddr2_addr;
  wire [2:0] ddr2_ba;
  wire ddr2_cas_n;
  wire [0:0] ddr2_ck_n;
  wire [0:0] ddr2_ck_p;
  wire [0:0] ddr2_cke;
  wire ddr2_ras_n;
  wire ddr2_we_n;
  wire [15:0] ddr2_dq;
  wire [1:0] ddr2_dqs_n;
  wire [1:0] ddr2_dqs_p;
  wire [0:0] ddr2_cs_n;
  wire [1:0] ddr2_dm;
  wire [0:0] ddr2_odt;

  always #5 clk = ~clk;

  core_top #(
    .CLK_HZ(CLK_HZ),
    .SIM_MODE(1'b1)
  ) dut (
    .CLK100MHZ(clk),
    .CPU_RESETN(resetn),
    .UART_TXD_IN(host_tx),
    .UART_RXD_OUT(host_rx),
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
    .ddr2_odt(ddr2_odt)
  );

  int cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;

  int errors = 0;

  // ---------------------------------------------------------------
  // ホストの UART 受信（FPGA の TX を受け取る）
  // ---------------------------------------------------------------
  logic rx_enable = 1'b0;
  logic [7:0] rx_bytes[$];
  int rx_cycle[$];

  initial begin
    logic [7:0] b;
    wait (rx_enable);
    forever begin
      @(negedge host_rx);
      // start bit の真ん中で確かめてから、各 bit の真ん中で取る
      repeat (CLK_PER_BIT / 2) @(posedge clk);
      if (host_rx !== 1'b0) begin
        $display("[%0d] UART 受信：start bit が短い（グリッチ）", cycle);
        errors++;
        continue;
      end
      for (int i = 0; i < 8; i++) begin
        repeat (CLK_PER_BIT) @(posedge clk);
        b[i] = host_rx;
      end
      repeat (CLK_PER_BIT) @(posedge clk);
      if (host_rx !== 1'b1) begin
        $display("[%0d] UART 受信：stop bit が 1 でない（データ %h）", cycle, b);
        errors++;
      end
      rx_bytes.push_back(b);
      rx_cycle.push_back(cycle);
    end
  end

  // ---------------------------------------------------------------
  // ホストの UART 送信（FPGA の RX へ）。DUT と同じ posedge で変えないよう negedge で動かす
  // ---------------------------------------------------------------
  task automatic uart_send(input logic [7:0] b);
    host_tx = 1'b0;
    repeat (CLK_PER_BIT) @(negedge clk);
    for (int i = 0; i < 8; i++) begin
      host_tx = b[i];
      repeat (CLK_PER_BIT) @(negedge clk);
    end
    host_tx = 1'b1;
    repeat (CLK_PER_BIT) @(negedge clk);
  endtask

  task automatic uart_send_word(input logic [31:0] w);
    for (int i = 0; i < 4; i++) uart_send(w[8*i+:8]);
  endtask

  // idx 番目に受け取るバイトが want であることを確かめる
  task automatic expect_byte(input int idx, input logic [7:0] want, input int timeout);
    int start;
    start = cycle;
    while (rx_bytes.size() <= idx) begin
      if (cycle - start > timeout) begin
        $display("[%0d] FAIL：%0d バイト目（期待 %h）が %0d サイクル待っても来ない", cycle, idx, want, timeout);
        errors++;
        return;
      end
      @(posedge clk);
    end
    if (rx_bytes[idx] !== want) begin
      $display("[%0d] FAIL：%0d バイト目 期待 %h 実際 %h", cycle, idx, want, rx_bytes[idx]);
      errors++;
    end
  endtask

  // ---------------------------------------------------------------
  // 本体
  // ---------------------------------------------------------------
  logic [31:0] prog[N_PROG];
  logic [31:0] data[N_DATA];
  int cycles;

  initial begin
    int start;
    logic [127:0] line;
    logic [31:0] want, got;

    if (!$value$plusargs("cycles=%d", cycles)) cycles = 2000;

    // バイトの並びが分かるように全バイト違う値にする
    for (int i = 0; i < N_PROG; i++) prog[i] = {8'(4 * i + 3), 8'(4 * i + 2), 8'(4 * i + 1), 8'(4 * i)} ^ 32'ha5000000;
    for (int i = 0; i < N_DATA; i++) data[i] = {8'(4 * i + 3), 8'(4 * i + 2), 8'(4 * i + 1), 8'(4 * i)} ^ 32'h5a000000;

    repeat (20) @(negedge clk);
    resetn = 1'b1;
    rx_enable = 1'b1;

    // 1. 0x99
    expect_byte(0, 8'h99, 2000);

    // 2. プログラム
    uart_send_word(32'(N_PROG * 4));
    for (int i = 0; i < N_PROG; i++) uart_send_word(prog[i]);

    // 3. 0xaa
    expect_byte(1, 8'haa, 2000);

    // 4. データ
    for (int i = 0; i < N_DATA; i++) uart_send_word(data[i]);

    start = cycle;
    while (!dut.boot_done) begin
      if (cycle - start > 2000) begin
        $display("[%0d] FAIL：データを送り終えても boot_done が立たない", cycle);
        errors++;
        break;
      end
      @(posedge clk);
    end
    $display("[%0d] boot_done", cycle);

    // IMEM：0 番地からプログラムが入っている
    for (int i = 0; i < N_PROG; i++) begin
      got = dut.u_mem_top.imem_inst.ram[i];
      if (got !== prog[i]) begin
        $display("FAIL：IMEM[%0d] 期待 %h 実際 %h", i, prog[i], got);
        errors++;
      end
    end

    // DRAM：0 番地からデータが入っている（1 行 = 4 ワード、行の端数は 0 埋め）
    for (int i = 0; i < (N_DATA + 3) / 4 * 4; i++) begin
      line = dut.u_mem_top.gen_sim_dram.sim_dram[i/4];
      got = line[32*(i%4)+:32];
      want = (i < N_DATA) ? data[i] : 32'h0;
      if (got !== want) begin
        $display("FAIL：DRAM ワード %0d 期待 %h 実際 %h", i, want, got);
        errors++;
      end
    end

    // コアのリセットが解ける
    repeat (2) @(posedge clk);
    if (dut.core_rst_ff !== 1'b0) begin
      $display("FAIL：boot_done の後もコアがリセットのまま");
      errors++;
    end

    // コアを回して、UART から出てきたものを表示する
    repeat (cycles) @(posedge clk);
    if (rx_bytes.size() > 2) begin
      $display("boot の後に UART から出たバイト：");
      for (int i = 2; i < rx_bytes.size(); i++) $display("  [%0d] %h", rx_cycle[i], rx_bytes[i]);
    end else begin
      $display("boot の後に UART から出たバイトは無い");
    end

    if (errors == 0) $display("PASS");
    else $display("FAIL：%0d 個のエラー", errors);
    $finish;
  end
endmodule

`default_nettype wire
