`timescale 1ns / 1ps
`default_nettype none

package back_types;
  import types::*;
  import ooo_types::*;
  import uop_types::*;

  typedef struct packed {
    logic     valid;
    preg_t    preg;
    latency_t latency;  // ◯cycle後から来てもいいよ
  } wakeup_t;

  // mispredictした分岐に依存していたら消す
  function automatic logic br_kill_check(input brmask_t brmask, input br_update_t upd);
    return |(brmask & upd.kill_mask);
  endfunction

  // 当たった分岐のビットを落とす
  function automatic brmask_t apply_br_resolve(input brmask_t brmask, input br_update_t upd);
    return brmask & ~upd.resolve_mask;
  endfunction

endpackage

`default_nettype wire
