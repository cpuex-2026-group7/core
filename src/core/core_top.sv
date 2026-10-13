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

  addr_t pc = 32'b0;
  addr_t pc_plus_1;
  assign pc_plus_1 = pc + 32'd1;

  instr_t instr;
  i_mem imem (
    .addr (pc),
    .instr(instr)
  );

  ctrl_t ctrl;
  decoder u_decoder (
    .op  (instr.op),
    .ctrl(ctrl)
  );
  assign cpu_halted = ctrl.halt;

  word_t extended_imm;
  imm_extend u_imm_extend (
    .instr(instr),
    .imm_type(instr.op.imm),
    .extended_imm(extended_imm)
  );

  word_t rdata1, rdata2, write_back_data;
  reg_file u_reg_file (
    .clk(clk),
    .rd({ctrl.rd_is_f, instr[24:20]}),
    .rs1({ctrl.rs1_is_f, instr[19:15]}),
    .rs2({ctrl.rs2_is_f, instr[14:10]}),
    .write_en(!rst & en & ctrl.reg_we),
    .wdata(write_back_data),
    .r_dbg(reg_dbg),
    .rdata1(rdata1),
    .rdata2(rdata2),
    .r_dbg_data(reg_dbg_data)
  );

  addr_t jumped_pc, jalr_pc;
  assign jumped_pc = pc + extended_imm;
  assign jalr_pc   = rdata1 + extended_imm;

  word_t alu_result, fpu_result;
  alu u_alu (
    .src1  (rdata1),
    .src2  (ctrl.alu_src_is_imm ? extended_imm : rdata2),
    .alu_op(ctrl.alu_op),
    .result(alu_result)
  );
  fpu_top u_fpu (
    .src1  (rdata1),
    .src2  (rdata2),
    .fpu_op(ctrl.fpu_op),
    .result(fpu_result)
  );

  word_t hard_coded_data;
  hard_code u_hard_code (
    .addr(extended_imm),
    .data(hard_coded_data)
  );

  word_t mem_rdata;
  d_mem u_d_mem (
    .clk(clk),
    .rst(rst),
    .write_en(!rst & en & ctrl.mem_we),
    .addr(alu_result),
    .wdata(rdata2),
    .rdata(mem_rdata)
  );

  always_comb begin
    unique case (ctrl.result_src)
      RES_ALU:         write_back_data = alu_result;
      RES_FPU:         write_back_data = fpu_result;
      RES_MEM:         write_back_data = mem_rdata;
      RES_IMM:         write_back_data = extended_imm;
      RES_HARD_CODE:   write_back_data = hard_coded_data;
      RES_PC_PLUS_ONE: write_back_data = pc_plus_1;
      default:         write_back_data = 32'b0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      pc <= 32'b0;
    end else if (en && !ctrl.halt) begin
      unique case (ctrl.pc_src)
        PC_PLUS_ONE: pc <= pc_plus_1;
        PC_BRANCH:   pc <= alu_result[0] ? jumped_pc : pc_plus_1;
        PC_JAL:      pc <= jumped_pc;
        PC_JALR:     pc <= jalr_pc;
        default:     pc <= 32'b0;
      endcase
    end
  end

  assign uart_tx = 1'b0;
  assign pc_dbg  = pc;

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
