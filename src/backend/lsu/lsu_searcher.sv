`timescale 1ns / 1ps
`default_nettype none

module lsu_searcher
  import types::*;
  import ooo_types::*;
  import lsu_types::*;
(
  // LDQ
  input wire ldq_entry_t ldq[LDQ_SIZE],
  output ldq_mask_t violation_mask,

  // STQから
  input wire stq_entry_t stq[STQ_SIZE],

  // controller
  input wire forward_search_t forward_search,  // forward元のstoreを探す
  output forward_result_t forward_result,
  input wire st_addr_t violation_search  // 順序違反のloadを探す
);

endmodule

`default_nettype wire
