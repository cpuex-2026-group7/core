`timescale 1ns / 1ps
`default_nettype none

// テストベンチと backend_top_shim で合わせる backend の構成
package tb_core_top_backend_only_pkg;
  localparam int LSU_DISP_W = 3;  // 1 サイクルに出す命令は 3 つまで（test/backend_top と同じ）
  localparam int COMMIT_W = 2;
endpackage

`default_nettype wire
