module hazard (
  input logic pc_jump_E,
  output logic stall_F,
  output logic stall_D,
  output logic flush_D,
  input logic [5:0] rs1_D,
  input logic [5:0] rs2_D,
  output logic flush_E,
  input logic [5:0] rs1_E,
  input logic [5:0] rs2_E,
  input logic [5:0] rd_E,
  input logic [5:0] rd_M,
  input logic mem_we_M,
  input logic reg_we_W,
  input result_src_t result_src_E,
  output isa::fwd_src_t forwardA_E,
  output isa::fwd_src_t forwardB_E
);

  logic lw_stall;
  assign lw_stall = (result_src_E == RES_MEM) & ((rs1_D == rd_E) | (rs2_D == rd_E));


endmodule
