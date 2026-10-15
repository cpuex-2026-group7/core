`timescale 1ns / 1ps
`default_nettype none

module stage_if
  import types::*;
(
  output addr_t pc_plus_1_F,
  wb_if_if.cons wb_if,
  if_id_if.prod if_id
);

  addr_t pc_plus_1;
  assign pc_plus_1 = wb_if.data.pc_F + 1;

  assign pc_plus_1_F = pc_plus_1;
  assign if_id.data.pc_plus_1_D = pc_plus_1;
  assign if_id.data.pc_D = wb_if.data.pc_F;

  i_mem imem (
    .addr (wb_if.data.pc_F),
    .instr(if_id.data.instr_D)
  );

endmodule

`default_nettype wire
