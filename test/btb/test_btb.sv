`timescale 1ns / 1ps
`default_nettype none

module test_btb;
  import types::*;

  localparam int IDX_WIDTH = 7;
  localparam int TAG_WIDTH = 9;
  localparam int NENTRY = 2 ** IDX_WIDTH;

  // A と B は同じ index、異なる tag。C は別の index。
  localparam addr_t PC_A = 32'h0000_0081;
  localparam addr_t PC_B = 32'h0000_0101;
  localparam addr_t PC_C = 32'h0000_0082;

  logic clk = 0;
  logic rst = 0;
  addr_t pc = '0;
  frontend_pkg::btb_resp_t resp;
  logic update_en = 0;
  addr_t update_pc = '0;
  addr_t update_target = '0;
  int checks = 0;

  btb #(.TAG_WIDTH(TAG_WIDTH), .IDX_WIDTH(IDX_WIDTH)) dut (
    .clk(clk),
    .rst(rst),
    .pc(pc),
    .resp(resp),
    .update_en(update_en),
    .update_pc(update_pc),
    .update_target(update_target)
  );

  always #5 clk = ~clk;

  // 立ち下がりで入力を準備し、次の立ち上がりで取り込ませる。
  // 次の立ち下がりで制御信号を戻し、意図しない再書き込みを防ぐ。
  task automatic apply_cycle(
    input logic reset_value,
    input logic enable_value,
    input addr_t addr,
    input addr_t target
  );
    @(negedge clk);
    rst = reset_value;
    update_en = enable_value;
    update_pc = addr;
    update_target = target;
    @(posedge clk);
    #1;  // always_ff の nonblocking assignment の反映を待つ。
    @(negedge clk);
    rst = 0;
    update_en = 0;
  endtask

  task automatic check_lookup(
    input string label_text,
    input addr_t addr,
    input logic expected_valid,
    input addr_t expected_target
  );
    pc = addr;
    #1;  // always_comb の評価を待つ。読み出しにクロックは不要。
    if (resp.valid !== expected_valid)
      $fatal(1, "%s: pc=%h valid expected=%b actual=%b",
             label_text, addr, expected_valid, resp.valid);
    // valid=0 のとき、呼び出し側は target を利用しない。
    if (expected_valid && resp.target !== expected_target)
      $fatal(1, "%s: pc=%h target expected=%h actual=%h",
             label_text, addr, expected_target, resp.target);
    checks++;
  endtask

  initial begin
    $dumpfile("btb.vcd");
    $dumpvars(0, test_btb);

    // 1. リセット後は、すべての index でミスする。
    apply_cycle(1, 0, '0, '0);
    for (int i = 0; i < NENTRY; i++)
      check_lookup("initial reset", addr_t'(i), 0, '0);

    // 2. update_en=0 の入力は登録されない。
    apply_cycle(0, 0, PC_A, 32'h200);
    check_lookup("disabled update", PC_A, 0, '0);

    // 3. 登録した PC はヒットし、未登録の別 index はミスする。
    apply_cycle(0, 1, PC_A, 32'h200);
    check_lookup("insert", PC_A, 1, 32'h200);
    check_lookup("unused index", PC_C, 0, '0);
    check_lookup("tag mismatch", PC_B, 0, '0);

    // 4. 別 index への登録で既存エントリは壊れない。
    apply_cycle(0, 1, PC_C, 32'h500);
    check_lookup("independent index", PC_C, 1, 32'h500);
    check_lookup("preserved entry", PC_A, 1, 32'h200);

    // 5. 同じ PC の target を更新できる。
    apply_cycle(0, 1, PC_A, 32'h300);
    check_lookup("overwrite target", PC_A, 1, 32'h300);
    apply_cycle(0, 0, PC_A, 32'hdead_beef);
    check_lookup("disabled overwrite", PC_A, 1, 32'h300);

    // 6. 同じ index の別 tag を登録すると古い PC はミスする。
    apply_cycle(0, 1, PC_B, 32'h400);
    check_lookup("replacement", PC_B, 1, 32'h400);
    check_lookup("evicted entry", PC_A, 0, '0);
    check_lookup("unrelated entry", PC_C, 1, 32'h500);

    // 7. 全 index を登録する。端の index と target=0 も含む。
    for (int i = 0; i < NENTRY; i++)
      apply_cycle(0, 1, addr_t'(i), addr_t'(i * 4));
    for (int i = 0; i < NENTRY; i++)
      check_lookup("all entries", addr_t'(i), 1, addr_t'(i * 4));

    // 8. rst と update_en が同時ならリセットが優先される。
    apply_cycle(1, 1, PC_A, 32'h600);
    for (int i = 0; i < NENTRY; i++)
      check_lookup("reset populated table", addr_t'(i), 0, '0);
    check_lookup("reset beats update", PC_A, 0, '0);

    // 9. 再リセット後にも新しいエントリを登録できる。
    apply_cycle(0, 1, PC_A, 32'h700);
    check_lookup("insert after reset", PC_A, 1, 32'h700);

    $display("PASS: BTB (%0d checks)", checks);
    $finish;
  end

  initial begin
    #10000;
    $fatal(1, "Timeout");
  end
endmodule

`default_nettype wire
