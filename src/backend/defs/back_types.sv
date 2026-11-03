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

  // 1本ずつ見る
  // mispredictした分岐に依存していたら消す
  function automatic logic br_killed(input brmask_t brmask, input br_update_t upd);
    return upd.valid && upd.mispredict && brmask[upd.tag];
  endfunction

  // 当たった分岐のビットを落とす
  function automatic brmask_t br_resolved(input brmask_t brmask, input br_update_t upd);
    brmask_t ret = brmask;
    if (upd.valid && !upd.mispredict) ret[upd.tag] = 1'b0;
    return ret;
  endfunction

endpackage

`default_nettype wire
