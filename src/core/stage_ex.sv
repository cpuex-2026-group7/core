`timescale 1ns / 1ps
`default_nettype none

module stage_ex (
  output addr_t pc_target_e,
  id_ex_if.cons id_ex,
  ex_mem_if.prod ex_mem
);

  alu u_alu (
  //TODO
  );

  fpu_top u_fpu (
  //TODO
  );

endmodule

`default_nettype wire
