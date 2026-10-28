`timescale 1ns / 1ps
`default_nettype none

// https://github.com/rsd-devel/rsd を参考にした。

// ただのLUTRAM
module lutram_1r1w #(
  parameter int SIZE = 64,
  parameter int ENTRY_WIDTH = 32
) (
  input wire logic clk,
  input wire logic w_en,
  input wire [$clog2(SIZE)-1:0] w_addr,
  input wire [ENTRY_WIDTH-1:0] w_data,
  input wire [$clog2(SIZE)-1:0] r_addr,
  output logic [ENTRY_WIDTH-1:0] r_data
);
  (* ram_style = "distributed" *) logic [ENTRY_WIDTH-1:0] mem[SIZE];

  initial for (int i = 0; i < SIZE; i++) mem[i] = '0;

  always_ff @(posedge clk) begin
    if (w_en) mem[w_addr] <= w_data;
  end

  assign r_data = mem[r_addr];
endmodule

// lvt table用 これはxor方式
module lvt_table #(
  parameter int SIZE = 64,
  parameter int R = 4,
  parameter int W = 3
) (
  input wire logic clk,
  input wire logic w_en[W],
  input wire [$clog2(SIZE)-1:0] w_addr[W],
  input wire [$clog2(W)-1:0] w_data[W],
  input wire [$clog2(SIZE)-1:0] r_addr[R],
  output logic [$clog2(W)-1:0] r_data[R]
);

  localparam int WL = (W > 1) ? $clog2(W) : 1;

  logic [WL-1:0] write_data[W];
  logic [WL-1:0] for_read  [W] [R];  // for_read[i][j]  = バンクiをr_addr[j]で読んだ
  logic [WL-1:0] for_write [W] [W];  // for_write[i][j] = バンクiをw_addr[j]で読んだ

  generate
    for (genvar i = 0; i < W; i++) begin : g_rbank_w
      for (genvar j = 0; j < R; j++) begin : g_rbank_r
        lutram_1r1w #(
          .SIZE(SIZE),
          .ENTRY_WIDTH(WL)
        ) u_lutram_1r1w (
          .clk(clk),
          .w_en(w_en[i]),
          .w_addr(w_addr[i]),
          .w_data(write_data[i]),
          .r_addr(r_addr[j]),
          .r_data(for_read[i][j])  // バンクiをr_addr[j]で読んだ
        );
      end
    end

    for (genvar i = 0; i < W; i++) begin : g_wbank_w
      for (genvar j = 0; j < W; j++) begin : g_wbank_r
        if (i != j) begin : g_used
          lutram_1r1w #(
            .SIZE(SIZE),
            .ENTRY_WIDTH(WL)
          ) u_lutram_1r1w (
            .clk(clk),
            .w_en(w_en[i]),
            .w_addr(w_addr[i]),
            .w_data(write_data[i]),
            .r_addr(w_addr[j]),
            .r_data(for_write[i][j])  //バンクiをw_addr[j]で読んだ
          );
        end else begin : g_unused
          assign for_write[i][j] = '0;
        end
      end
    end
  endgenerate

  always_comb begin
    // write
    for (int i = 0; i < W; i++) begin
      write_data[i] = w_data[i];
      for (int j = 0; j < W; j++) begin
        if (i != j) write_data[i] ^= for_write[j][i];  // for_write[j][i] = バンクjをw_addr[i]で読んだ
      end
    end

    // read
    for (int i = 0; i < R; i++) begin
      r_data[i] = '0;
      for (int j = 0; j < W; j++) begin
        r_data[i] ^= for_read[j][i];  // for_read[j][i] = バンクjをr_addr[i]で読んだ
      end
    end

  end

`ifndef SYNTHESIS
  // 同じアドレスへの同時書き込みの検出
  always_ff @(posedge clk) begin
    for (int i = 0; i < W; i++) begin
      for (int j = i + 1; j < W; j++) begin
        if (w_en[i] && w_en[j] && w_addr[i] == w_addr[j]) begin
          $error("lvt_table: ポート %0d と %0d が同じアドレス %0d に同時書き込み", i, j, w_addr[i]);
        end
      end
    end
  end
`endif

endmodule

// 本体
module lvt_rf #(
  parameter int SIZE = 64,
  parameter int ENTRY_WIDTH = 32,
  parameter int R = 4,
  parameter int W = 3
) (
  input wire logic clk,
  input wire logic w_en[W],
  input wire [$clog2(SIZE)-1:0] w_addr[W],
  input wire [ENTRY_WIDTH-1:0] w_data[W],
  input wire [$clog2(SIZE)-1:0] r_addr[R],
  output logic [ENTRY_WIDTH-1:0] r_data[R]
);

  localparam int WL = (W > 1) ? $clog2(W) : 1;
  logic [ENTRY_WIDTH-1:0] bank_data[W][R];  // bank_data[i][j] = バンクiをr_addr[j]で読んだ

  generate
    for (genvar i = 0; i < W; i++) begin : g_w
      for (genvar j = 0; j < R; j++) begin : g_r
        lutram_1r1w #(
          .SIZE(SIZE),
          .ENTRY_WIDTH(ENTRY_WIDTH)
        ) u_lutram_1r1w (
          .clk(clk),
          .w_en(w_en[i]),
          .w_addr(w_addr[i]),
          .w_data(w_data[i]),
          .r_addr(r_addr[j]),
          .r_data(bank_data[i][j])
        );
      end
    end
  endgenerate

  logic [WL-1:0] port_id[W];  // Wポートiのidはi
  generate
    for (genvar i = 0; i < W; i++) begin : g_port_id
      assign port_id[i] = WL'(i);
    end
  endgenerate

  logic [WL-1:0] lvt[R];

  lvt_table #(
    .SIZE(SIZE),
    .R(R),
    .W(W)
  ) u_lvt_table (
    .clk(clk),
    .w_en(w_en),
    .w_addr(w_addr),
    .w_data(port_id),
    .r_addr(r_addr),
    .r_data(lvt)
  );

  always_comb begin
    for (int i = 0; i < R; i++) begin
      r_data[i] = bank_data[lvt[i]][i];
    end
  end

`ifndef SYNTHESIS
  // 全書き込みを素直に反映し、全読み出しポートの値と照合する
  logic [ENTRY_WIDTH-1:0] shadow[SIZE];
  initial for (int i = 0; i < SIZE; i++) shadow[i] = '0;

  always_ff @(posedge clk) begin
    for (int i = 0; i < W; i++) begin
      if (w_en[i]) shadow[w_addr[i]] <= w_data[i];
    end
    for (int i = 0; i < R; i++) begin
      if (r_data[i] != shadow[r_addr[i]]) begin
        $error("lvt_rf: 読み出しポート %0d（アドレス %0d）の値が不一致: %h != %h", i, r_addr[i],
               r_data[i], shadow[r_addr[i]]);
      end
    end
  end
`endif

endmodule

`default_nettype wire
