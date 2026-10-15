`timescale 1ns / 1ps
`default_nettype none

module core_top
  import types::*;
  import isa::*;
(
  input wire logic clk,
  input wire logic rst,
  input wire logic en,
  input wire logic uart_rx,
  output logic uart_tx,
  output addr_t pc_dbg,
  input wire rf_idx_t reg_dbg,
  output word_t reg_dbg_data,
  output logic cpu_halted
);

  if_id_if if_id_p (), if_id_c ();
  id_ex_if id_ex_p (), id_ex_c ();
  ex_mem_if ex_mem_p (), ex_mem_c ();
  mem_wb_if mem_wb_p (), mem_wb_c ();
  wb_if_if wb_if_p (), wb_if_c ();

  logic pc_jump_E, stall_F, stall_D, flush_D, flush_E;
  fwd_src_t forwardA_E, forwardB_E;

  hazard u_hazard (
    .pc_jump_E   (pc_jump_E),
    .stall_F     (stall_F),
    .stall_D     (stall_D),
    .flush_D     (flush_D),
    .rs1_D       (id_ex_p.data.rs1_E),
    .rs2_D       (id_ex_p.data.rs2_E),
    .flush_E     (flush_E),
    .rs1_E       (id_ex_c.data.rs1_E),
    .rs2_E       (id_ex_c.data.rs2_E),
    .rd_E        (id_ex_c.data.rd_E),
    .rd_M        (ex_mem_c.data.rd_M),
    .rd_W        (mem_wb_c.data.rd_W),
    .reg_we_M    (ex_mem_c.data.ctrl_M.reg_we),
    .reg_we_W    (mem_wb_c.data.ctrl_W.reg_we),
    .result_src_E(id_ex_c.data.ctrl_E.result_src),
    .result_src_M(ex_mem_c.data.ctrl_M.result_src),
    .forwardA_E  (forwardA_E),
    .forwardB_E  (forwardB_E)
  );

  addr_t pc_plus_1_F;
  stage_if u_stage_if (
    .pc_plus_1_F(pc_plus_1_F),
    .wb_if(wb_if_c),
    .if_id(if_id_p)
  );

  if_id_reg u_if_id_reg (
    .clk(clk),
    .rst_n(~rst),
    .stall_D(stall_D),
    .flush_D(flush_D),
    .d(if_id_p),
    .q(if_id_c)
  );

  word_t result_W;
  stage_id u_stage_id (
    .clk(clk),
    .if_id(if_id_c),
    .reg_we_W(mem_wb_c.data.ctrl_W.reg_we),
    .rd_W(mem_wb_c.data.rd_W),
    .result_W(result_W),
    .r_dbg(reg_dbg),

    .id_ex(id_ex_p),
    .r_dbg_data(reg_dbg_data)
  );

  id_ex_reg u_id_ex_reg (
    .clk(clk),
    .rst_n(~rst),
    .flush_E(flush_E),
    .d(id_ex_p),
    .q(id_ex_c)
  );

  addr_t pc_target_E;
  stage_ex u_stage_ex (
    .fpu_result_M(ex_mem_c.data.fpu_result_M),
    .alu_result_M(ex_mem_c.data.alu_result_M),
    .ext_imm_M(ex_mem_c.data.ext_imm_M),
    .hard_code_M(ex_mem_c.data.hard_code_M),
    .result_W(result_W),
    .id_ex(id_ex_c),
    .forwardA(forwardA_E),
    .forwardB(forwardB_E),

    .pc_target_E(pc_target_E),
    .pc_jump(pc_jump_E),
    .ex_mem(ex_mem_p)
  );

  ex_mem_reg u_ex_mem_reg (
    .clk(clk),
    .rst_n(~rst),
    .d(ex_mem_p),
    .q(ex_mem_c)
  );

  stage_mem u_stage_mem (
    .clk(clk),
    .rst(rst),
    .ex_mem(ex_mem_c),
    .mem_wb(mem_wb_p)
  );

  mem_wb_reg u_mem_wb_reg (
    .clk(clk),
    .rst_n(~rst),
    .d(mem_wb_p),
    .q(mem_wb_c)
  );

  stage_wb u_stage_wb (
    .pc_plus_1_F(pc_plus_1_F),
    .pc_target_E(pc_target_E),
    .pc_jump_E(pc_jump_E),
    .result_W(result_W),
    .mem_wb(mem_wb_c),
    .wb_if(wb_if_p)
  );

  wb_if_reg u_wb_if_reg (
    .clk(clk),
    .rst_n(~rst),
    .stall_F(stall_F),
    .d(wb_if_p),
    .q(wb_if_c)
  );


`ifdef VERILATOR
  import "DPI-C" function void dpi_commit(
    input int pc,
    input int instr,
    input bit reg_we,
    input bit rd_is_f,
    input int rd,
    input int wdata,
    input bit mem_we,
    input int mem_addr,
    input int mem_wdata
  );

  always_ff @(posedge clk) begin
    if (!rst && en && !ctrl.halt)
      dpi_commit(pc, instr, ctrl.reg_we, ctrl.rd_is_f, 32'(instr.rd), write_back_data, ctrl.mem_we, alu_result, rdata2);
  end
`endif
endmodule

`default_nettype wire
