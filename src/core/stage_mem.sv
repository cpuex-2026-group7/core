module stage_mem (
  input logic clk,
  input logic rst,
  output logic [5:0] rd_M,
  output logic mem_we_M,
  ex_mem_if.cons ex_mem,
  mem_wb_if.prod mem_wb
);

  assign rd_M = ex_mem.data.rd_M;
  assign mem_we_M = ex_mem.data.ctrl_M.mem_we;

  assign mem_wb.data.ctrl_W = ex_mem.data.ctrl_M;
  assign mem_wb.data.fpu_result_W = ex_mem.data.fpu_result_M;
  assign mem_wb.data.alu_result_W = ex_mem.data.alu_result_M;
  assign mem_wb.data.rd_W = ex_mem.data.rd_M;
  assign mem_wb.data.ext_imm_W = ex_mem.data.ext_imm_M;
  assign mem_wb.data.hard_code_W = ex_mem.data.hard_code_M;
  assign mem_wb.data.pc_plus_1_W = ex_mem.data.pc_plus_1_M;

  d_mem u_d_mem (
    .clk(clk),
    .rst(rst),
    .write_en(ex_mem.data.ctrl_M.mem_we),
    .addr(ex_mem.data.alu_result_M),
    .wdata(ex_mem.data.wdata_M),
    .rdata(mem_wb.data.rdata_W)
  );

endmodule
