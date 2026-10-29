`timescale 1ns / 1ps
`default_nettype none

package types;
  typedef logic [31:0] word_t;
  typedef logic [31:0] addr_t;

  typedef logic [4:0] reg_addr_t;
  typedef logic [5:0] rf_idx_t;

  typedef logic [15:0] pc_t;

  localparam int NUM_PREG_I = 64;
  localparam int NUM_PREG_F = 64;
  localparam int PREG_W = $clog2((NUM_PREG_I > NUM_PREG_F) ? NUM_PREG_I : NUM_PREG_F);
  localparam int ROB_SIZE = 32;
  localparam int MAX_BR = 8;
  localparam int BR_TAG_W = (MAX_BR > 1) ? $clog2(MAX_BR) : 1;
  localparam int LDQ_SIZE = 8;
  localparam int STQ_SIZE = 8;

  typedef enum logic [1:0] {
    PREG_TYPE_INT  = 2'b00,
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

  typedef logic [$clog2(ROB_SIZE)-1:0] rob_idx_t;
  typedef logic [MAX_BR-1:0] brmask_t;
  typedef logic [BR_TAG_W-1:0] br_tag_t;
  typedef logic [$clog2(LDQ_SIZE)-1:0] ldq_idx_t;
  typedef logic [$clog2(STQ_SIZE)-1:0] stq_idx_t;

  typedef struct packed {
    logic    valid;
    logic    mispredict;
    br_tag_t tag;
    logic    taken;
    pc_t     pc;
    pc_t     target;
  } br_update_t;
endpackage

`default_nettype wire
