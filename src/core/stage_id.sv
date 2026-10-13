module stage_id
  import types::*;
(
  input clk,
  input reg_addr_t rd_w,
  input word_t result_w,
  if_id_if.cons if_id,
  id_ex_if.prod id_ex
);

  reg_file u_reg_file (
    .clk(~clk)  // negedge(moduleではposedgeになっているのでここでclkを反転させる)
    //TODO!
  );

  hard_code u_hard_code (
  //TODO
  );

  imm_extend u_imm_extend (
  //TODO!
  );

  decoder u_decoder (
  //TODO!
  );

endmodule
