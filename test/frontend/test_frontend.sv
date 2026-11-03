`timescale 1ns / 1ps
`default_nettype none

module test_frontend;
  localparam int QUEUE_IDX_WIDTH = 2;
  localparam int NENTRY = 2 ** QUEUE_IDX_WIDTH;

  logic clk = 0;
  logic rst = 1;
  always #5 clk = ~clk;

  types::addr_t pc_backend_redirect = '0;
  logic backend_redirect = 0;
  isa::instr_t fetchq_dout;
  logic fetchq_pop = 1;
  logic [QUEUE_IDX_WIDTH-1:0] ftq_get_idx = '0;
  frontend_pkg::ftq_data_t ftq_dout;
  logic ftq_pop = 0;
  // Restoring the slot before zero leaves an empty FTQ with tail=0.
  logic [QUEUE_IDX_WIDTH-1:0] ftq_restore_idx = '1;

  frontend #(
      .FETCHQ_IDX_WIDTH(QUEUE_IDX_WIDTH),
      .FTQ_IDX_WIDTH(QUEUE_IDX_WIDTH)
  ) dut (.*);

  // Independently check a nonzero reset vector as well.
  isa::instr_t reset_fetchq_dout;
  frontend_pkg::ftq_data_t reset_ftq_dout;
  frontend #(
      .FETCHQ_IDX_WIDTH(QUEUE_IDX_WIDTH),
      .FTQ_IDX_WIDTH(QUEUE_IDX_WIDTH),
      .RESET_PC(32'd64)
  ) reset_dut (
      .clk(clk), .rst(rst),
      .pc_backend_redirect(32'b0), .backend_redirect(1'b0),
      .fetchq_dout(reset_fetchq_dout), .fetchq_pop(1'b1),
      .ftq_get_idx(QUEUE_IDX_WIDTH'(0)), .ftq_dout(reset_ftq_dout),
      .ftq_pop(1'b0), .ftq_restore_idx(QUEUE_IDX_WIDTH'(0))
  );

  types::addr_t pushed_pcs[$];
  int pushed_cycles[$];
  isa::instr_t expected_fetchq[$];
  int cycle = 0;
  int checks = 0;
  int popped_count = 0;
  bit reset_pc_checked = 0;

  function automatic isa::instr_t marker(input int pc);
    // Distinct non-branch instructions identify the fetched memory words.
    return isa::instr_t'(32'h2000_0000 | 32'(pc));
  endfunction

  function automatic isa::instr_t jal(input int offset);
    return isa::instr_t'({5'b00101, 2'b00, 5'b0, 20'(offset)});
  endfunction

  // Compare actual Fetch Queue output against requests accepted at F3.
  // The module currently does not expose empty, so qualify pop internally.
  always @(posedge clk) begin
    if (rst) begin
      pushed_pcs.delete();
      pushed_cycles.delete();
      expected_fetchq.delete();
      popped_count = 0;
      cycle = 0;
      reset_pc_checked = 0;
    end else begin
      cycle++;
      if (!reset_pc_checked && reset_dut.fire_instr) begin
        if (reset_dut.pc_F3 !== 32'd64 || reset_dut.instr_F3 !== marker(64))
          $fatal(1, "Nonzero RESET_PC was not fetched first");
        reset_pc_checked = 1;
        checks++;
      end

      if (backend_redirect) begin
        expected_fetchq.delete();
        if (dut.fire_instr || dut.frontend_redirect_fire)
          $fatal(1, "Old F3 instruction was accepted on backend redirect");
      end else begin
        if (fetchq_pop && !dut.fetchq_empty) begin
          if (expected_fetchq.size() == 0)
            $fatal(1, "Unexpected Fetch Queue output");
          if (fetchq_dout !== expected_fetchq.pop_front())
            $fatal(1, "Fetch Queue output differs from the expected instruction");
          popped_count++;
          checks++;
        end
        if (dut.fire_instr) begin
          if (dut.instr_F3 !== isa::instr_t'(dut.u_i_mem.mem[dut.pc_F3[9:0]]))
            $fatal(1, "PC/instruction mismatch at PC=%0d", dut.pc_F3);
          pushed_pcs.push_back(dut.pc_F3);
          pushed_cycles.push_back(cycle);
          expected_fetchq.push_back(isa::instr_t'(dut.u_i_mem.mem[dut.pc_F3[9:0]]));
          checks++;
        end
      end
    end
  end

  task automatic tick;
    @(posedge clk);
    #1;
  endtask

  task automatic reset_all;
    @(negedge clk);
    rst = 1;
    backend_redirect = 0;
    fetchq_pop = 1;
    ftq_pop = 0;
    ftq_restore_idx = '1;
    for (int i = 0; i < 1024; i++) begin
      dut.u_i_mem.mem[i] = marker(i);
      reset_dut.u_i_mem.mem[i] = marker(i);
    end
    repeat (2) tick();
    @(negedge clk);
    rst = 0;
  endtask

  task automatic expect_pc(input int index, input types::addr_t pc);
    if (pushed_pcs.size() <= index)
      $fatal(1, "Missing fetch at index %0d; expected PC=%0d", index, pc);
    if (pushed_pcs[index] !== pc)
      $fatal(1, "Fetch %0d: expected PC=%0d, actual=%0d", index, pc, pushed_pcs[index]);
    checks++;
  endtask

  task automatic expect_linear(input int first_index, input types::addr_t first_pc);
    if (pushed_pcs.size() <= first_index)
      $fatal(1, "No instructions after PC=%0d", first_pc);
    for (int i = first_index; i < pushed_pcs.size(); i++)
      expect_pc(i, first_pc + 32'(i - first_index));
  endtask

  task automatic expect_redirect_request(input types::addr_t target);
    if (dut.pc_F1 !== target || dut.u_i_mem.addr_inner !== target ||
        dut.u_btb.pc_F1 !== target)
      $fatal(1, "PC, memory and BTB did not capture redirect PC=%0d together", target);
    if (!dut.instr_valid_F1 || dut.instr_valid_F2 || dut.instr_valid_F3)
      $fatal(1, "Incorrect valid bits after redirect");
    checks++;
  endtask

  initial begin
    int redirect_start;
    types::addr_t held_pc;
    isa::instr_t held_instr;
    frontend_pkg::btb_resp_t held_btb;

    reset_all();
    repeat (12) tick();
    expect_linear(0, 0);
    if (!reset_pc_checked || popped_count < 5)
      $fatal(1, "Sequential/reset-vector test did not make progress");
    $display("PASS: reset vectors and sequential fetch");

    reset_all();
    dut.u_i_mem.mem[0] = jal(100);
    repeat (12) tick();
    expect_pc(0, 0);
    expect_linear(1, 100);
    if (dut.u_ftq.data[0].pc !== 0 ||
        dut.u_ftq.data[0].bp_data.btype !== frontend_pkg::BR_JAL)
      $fatal(1, "Redirecting JAL was not preserved in the FTQ");
    $display("PASS: cold JAL preserves the branch and its target");

    // Re-fetch the learned branch; its target has no BTB entry.
    redirect_start = pushed_pcs.size();
    @(negedge clk);
    backend_redirect = 1;
    pc_backend_redirect = 0;
    tick();
    expect_redirect_request(0);
    @(negedge clk);
    backend_redirect = 0;
    repeat (8) tick();
    expect_pc(redirect_start, 0);
    expect_linear(redirect_start + 1, 100);
    if (pushed_cycles[redirect_start + 1] != pushed_cycles[redirect_start] + 1)
      $fatal(1, "Warm BTB prediction inserted a bubble");
    $display("PASS: warm BTB target and subsequent sequential PC");

    reset_all();
    ftq_pop = 1;
    dut.u_i_mem.mem[0] = jal(4);
    dut.u_i_mem.mem[4] = jal(-4);
    repeat (22) tick();
    if (pushed_pcs.size() < 6) $fatal(1, "Branch loop made no progress");
    for (int i = 0; i < pushed_pcs.size(); i++) begin
      expect_pc(i, (i % 2 == 0) ? 32'd0 : 32'd4);
      if (i >= 3 && pushed_cycles[i] != pushed_cycles[i-1] + 1)
        $fatal(1, "Warm branch loop inserted a bubble");
    end
    $display("PASS: warm branch loop has no wrong-path instructions or bubbles");

    reset_all();
    repeat (5) tick();
    redirect_start = pushed_pcs.size();
    @(negedge clk);
    backend_redirect = 1;
    pc_backend_redirect = 100;
    tick();
    expect_redirect_request(100);
    if (!dut.fetchq_empty) $fatal(1, "Backend redirect did not clear Fetch Queue");
    @(negedge clk);
    backend_redirect = 0;
    repeat (8) tick();
    expect_linear(redirect_start, 100);
    $display("PASS: backend redirect flushes queued and in-flight instructions");

    reset_all();
    fetchq_pop = 0;
    repeat (10) tick();
    if (!dut.stall || !dut.fetchq_full) $fatal(1, "Expected full Fetch Queue");
    redirect_start = pushed_pcs.size();
    @(negedge clk);
    backend_redirect = 1;
    pc_backend_redirect = 100;
    tick();
    expect_redirect_request(100);
    @(negedge clk);
    backend_redirect = 0;
    fetchq_pop = 1;
    repeat (8) tick();
    expect_linear(redirect_start, 100);
    $display("PASS: backend redirect overrides Fetch Queue stall");

    reset_all();
    for (int i = 0; i < NENTRY; i++) dut.u_i_mem.mem[i] = jal(1);
    repeat (16) tick();
    if (!dut.ftq_full || !dut.stall || dut.pc_F3 !== 3)
      $fatal(1, "Expected branch stalled by full FTQ");
    redirect_start = pushed_pcs.size();
    @(negedge clk);
    backend_redirect = 1;
    pc_backend_redirect = 100;
    ftq_restore_idx = QUEUE_IDX_WIDTH'(2);  // Preserve all three live entries.
    tick();
    expect_redirect_request(100);
    if (!dut.ftq_full || dut.u_btb.valid[3])
      $fatal(1, "Redirect changed retained FTQ entries or trained the killed branch");
    @(negedge clk);
    backend_redirect = 0;
    repeat (8) tick();
    expect_linear(redirect_start, 100);
    if (!dut.ftq_full) $fatal(1, "Non-branches should not consume FTQ entries");
    $display("PASS: backend redirect resumes non-branches while FTQ remains full");

    reset_all();
    fetchq_pop = 0;
    dut.u_i_mem.mem[3] = jal(7);
    repeat (10) tick();
    if (!dut.stall || !dut.frontend_redirect_F3 || dut.pc_F3 !== 3)
      $fatal(1, "Expected stalled frontend redirect at PC3");
    held_pc = dut.pc_F1;
    held_instr = dut.instr_F3;
    held_btb = dut.btb_resp_F3;
    repeat (3) begin
      tick();
      if (dut.pc_F1 !== held_pc || dut.u_i_mem.addr_inner !== held_pc ||
          dut.u_btb.pc_F1 !== held_pc || dut.instr_F3 !== held_instr ||
          dut.btb_resp_F3 !== held_btb || !dut.instr_valid_F3 || dut.u_btb.valid[3])
        $fatal(1, "Stall lost or changed a pending frontend redirect");
      checks++;
    end
    @(negedge clk);
    fetchq_pop = 1;
    repeat (12) tick();
    for (int i = 0; i < 4; i++) expect_pc(i, 32'(i));
    expect_linear(4, 10);
    $display("PASS: stalled frontend redirect is applied once when output resumes");

    reset_all();
    dut.u_i_mem.mem[0] = jal(100);
    repeat (3) tick();
    if (!dut.frontend_redirect_F3) $fatal(1, "Expected pending frontend redirect");
    @(negedge clk);
    backend_redirect = 1;
    pc_backend_redirect = 200;
    tick();
    expect_redirect_request(200);
    if (dut.u_btb.valid[0]) $fatal(1, "Killed F3 instruction trained BTB");
    @(negedge clk);
    backend_redirect = 0;
    repeat (8) tick();
    expect_linear(0, 200);
    $display("PASS: backend redirect wins over frontend redirect and BTB training");

    reset_all();
    repeat (5) tick();
    redirect_start = pushed_pcs.size();
    @(negedge clk);
    backend_redirect = 1;
    pc_backend_redirect = 100;
    tick();
    expect_redirect_request(100);
    @(negedge clk);
    pc_backend_redirect = 200;
    tick();
    expect_redirect_request(200);
    @(negedge clk);
    backend_redirect = 0;
    repeat (8) tick();
    expect_linear(redirect_start, 200);
    $display("PASS: consecutive backend redirects preserve only the latest path");

    reset_all();
    backend_redirect = 1;
    pc_backend_redirect = 200;
    tick();
    expect_redirect_request(200);
    @(negedge clk);
    backend_redirect = 0;
    repeat (8) tick();
    expect_linear(0, 200);
    $display("PASS: backend redirect can replace the initial reset request");

    $display("PASS: frontend (%0d checks)", checks);
    $finish;
  end

  initial begin
    #10000;
    $fatal(1, "Timeout");
  end
endmodule

`default_nettype wire
