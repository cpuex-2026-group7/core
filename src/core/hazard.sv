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
  input logic reg_we_M,
  input logic reg_we_W,
  input result_src_t result_src_E,
  input result_src_t result_src_M,
  output isa::fwd_src_t forwardA_E,
  output isa::fwd_src_t forwardB_E
);

  logic lw_stall;
  assign lw_stall = (result_src_E == RES_MEM) & ((rs1_D == rd_E) | (rs2_D == rd_E));

  assign stall_F  = lw_stall;
  assign stall_D  = lw_stall;
  assign flush_D  = pc_jump_E;
  assign flush_E  = lw_stall | pc_jump_E;

  // FWD_RES_W is not covered here. Covered explicitly in the next always_comb block.
  fwd_src_t fwd_candicate;
  always_comb begin
    unique if (result_src_M == RES_ALU) fwd_candicate = FWD_ALU_M;
    else if (result_src_M == RES_FPU) fwd_candicate = FWD_FPU_M;
    else if (result_src_M == RES_IMM) fwd_candicate = FWD_IMM_M;
    else if (result_src_M == RES_HARD_CODE) fwd_candicate = FWD_HARD_CODE_M;
    else fwd_candicate = FWD_NONE;
  end

  always_comb begin
    if ((rs1_E == rd_M) & reg_we_M & (rs1_E[4:0] != 5'b0)) forwardA_E = fwd_candicate;
    else if ((rs1_E == rd_W) & reg_we_W & (rs1_E[4:0] != 5'b0)) forwardA_E = FWD_RES_W;
    else forwardA_E = FWD_NONE;
  end

  always_comb begin
    if ((rs2_E == rd_M) & reg_we_M & (rs2_E[4:0] != 5'b0)) forwardB_E = fwd_candicate;
    else if ((rs2_E == rd_W) & reg_we_W & (rs2_E[4:0] != 5'b0)) forwardB_E = FWD_RES_W;
    else forwardB_E = FWD_NONE;
  end

endmodule
