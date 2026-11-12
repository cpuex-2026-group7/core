`timescale 1ns / 1ps
`default_nettype none

// frontend/backendで共有
package ooo_types;
  import types::*;

  localparam int NUM_PREG_I = 64;
  localparam int NUM_PREG_F = 64;
  localparam int PREG_W = $clog2((NUM_PREG_I > NUM_PREG_F) ? NUM_PREG_I : NUM_PREG_F);
  localparam int DISPATCH_W = 1;
  localparam int ROB_SIZE = 32;
  localparam int MAX_BR = 8;
  localparam int BR_TAG_W = (MAX_BR > 1) ? $clog2(MAX_BR) : 1;
  localparam int LDQ_SIZE = 8;
  localparam int STQ_SIZE = 8;
  localparam int FTQ_IDX_WIDTH = 5;

  typedef enum logic [1:0] {
    PREG_TYPE_I  = 2'b00,
    PREG_TYPE_F    = 2'b01,
    PREG_TYPE_NONE = 2'b10
  } preg_type_t;
  typedef logic [PREG_W-1:0] preg_idx_t;
  typedef struct packed {
    preg_type_t typ;
    preg_idx_t  idx;
  } preg_t;

  typedef enum logic {
    MEM_TYPE_LD = 1'b0,
    MEM_TYPE_ST = 1'b1
  } ls_type_t;

  typedef logic [((ROB_SIZE > 1) ? $clog2(ROB_SIZE) : 1)-1:0] rob_row_t;
  typedef struct packed {
    rob_row_t row;
    logic [((DISPATCH_W > 1) ? $clog2(DISPATCH_W) : 1)-1:0] bank;
  } rob_idx_t;

  typedef logic [MAX_BR-1:0] brmask_t;
  typedef logic [BR_TAG_W-1:0] br_tag_t;
  typedef logic [$clog2(LDQ_SIZE)-1:0] ldq_idx_t;
  typedef logic [$clog2(STQ_SIZE)-1:0] stq_idx_t;
  typedef logic [FTQ_IDX_WIDTH-1:0] ftq_idx_t;

  // 分岐EUが1本ずつ出す結果
  typedef struct packed {
    logic     valid;
    logic     mispredict;
    br_tag_t  tag;
    brmask_t  brmask;      // 自分より真に古い未解決の分岐のmask
    logic     taken;
    pc_t      pc;
    pc_t      target;
    rob_idx_t rob_idx;
  } br_result_t;

  // ex_topでFFに入れた後配られる
  typedef struct packed {
    brmask_t  resolve_mask;  // 予測が当たった分岐
    brmask_t  kill_mask;     // 予測が外れた分岐
    logic     mispredict;
    // これ以降は復帰用の情報
    br_tag_t  tag;
    logic     taken;
    pc_t      pc;
    pc_t      target;
    rob_idx_t rob_idx;
  } br_update_t;
endpackage

`default_nettype wire
