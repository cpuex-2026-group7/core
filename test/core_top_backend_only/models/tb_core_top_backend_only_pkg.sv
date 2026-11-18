`timescale 1ns / 1ps
`default_nettype none

// テストベンチと backend_top_shim で合わせる backend の構成
package tb_core_top_backend_only_pkg;
  localparam int LSU_DISP_W = ooo_types::DISPATCH_W;  // 1 サイクルに出す命令の数（本番と同じ）
  localparam int COMMIT_W = ooo_types::DISPATCH_W;
endpackage

`default_nettype wire
