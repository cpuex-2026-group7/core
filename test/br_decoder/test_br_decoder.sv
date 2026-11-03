`timescale 1ns / 1ps
`default_nettype none

module test_br_decoder;
  isa::instr_t instr;
  types::addr_t pc;
  frontend_pkg::branch_type_t branch_type;
  types::addr_t target_pc;
  int checks = 0;

  br_decoder dut (.*);

  task automatic check_decode(
    input types::word_t bits_value,
    input types::addr_t pc_value,
    input frontend_pkg::branch_type_t expected_type,
    input types::addr_t expected_target
  );
    instr = isa::instr_t'(bits_value);
    pc = pc_value;
    #1;
    if (branch_type !== expected_type || target_pc !== expected_target)
      $fatal(1, "instr=%h pc=%h: expected type=%d target=%h, got type=%d target=%h",
             instr, pc, expected_type, expected_target, branch_type, target_pc);
    checks++;
  endtask

  initial begin
    // Branch immediates combine rd and rest; rs1/rs2 are register operands.
    for (int id = 0; id < 4; id++) begin
      check_decode({5'b00011, 2'(id), 5'd1, 5'd31, 5'd31, 10'd0},
                   32'h1000, frontend_pkg::BR_BRANCH, 32'h1400);
      check_decode({5'b00011, 2'(id), 5'd16, 5'd31, 5'd31, 10'd0},
                   32'h1000, frontend_pkg::BR_BRANCH, 32'hffff_d000);
      check_decode({5'b00011, 2'(id), 5'd31, 5'd0, 5'd0, 10'd1023},
                   32'h1000, frontend_pkg::BR_BRANCH, 32'h0fff);
    end

    // JAL immediates combine rs1, rs2 and rest; rd is the destination.
    check_decode({5'b00101, 2'b00, 5'd31, 20'h7ffff},
                 32'h1000, frontend_pkg::BR_JAL, 32'h0008_0fff);
    check_decode({5'b00101, 2'b00, 5'd31, 20'h80000},
                 32'h1000, frontend_pkg::BR_JAL, 32'hfff8_1000);
    check_decode({5'b00101, 2'b00, 5'd31, 20'hfffff},
                 32'h0, frontend_pkg::BR_JAL, 32'hffff_ffff);

    // Only id=00 is JALR; ADDI and LW share the upper five opcode bits.
    for (int id = 0; id < 4; id++)
      check_decode({5'b00110, 2'(id), 25'h1ff_ffff}, 32'h1000,
                   id == 0 ? frontend_pkg::BR_JALR : frontend_pkg::BR_NONE, '0);
    check_decode('0, 32'h1000, frontend_pkg::BR_NONE, '0);
    check_decode({5'b10011, 27'b0}, 32'h1000, frontend_pkg::BR_NONE, '0);

    $display("PASS: %0d branch decoder checks", checks);
    $finish;
  end
endmodule

`default_nettype wire
