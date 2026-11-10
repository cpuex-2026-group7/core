`timescale 1ns / 1ps
`default_nettype none

package lsu_types;
  import types::*;
  import ooo_types::*;

  typedef logic [STQ_SIZE-1:0] stq_mask_t;
  typedef logic [LDQ_SIZE-1:0] ldq_mask_t;

  // LSUからWBへ(中身はex_wb_tと同じ)
  typedef ex_types::ex_wb_t lsu_wb_t;

  // MMIO(とりあえず)
  localparam addr_t MMIO_RX_ADDR = 32'hffff_ffff;  // read
  localparam addr_t MMIO_TX_ADDR = 32'hffff_fffe;  // write

  // dispatchからLDQへ
  typedef struct packed {
    logic     valid;
    preg_t    rd;
    rob_idx_t rob_idx;
    brmask_t  brmask;
  } disp_ldq_t;

  // dispatchからSTQへ
  // killはtail snapshotでやるのでbrmaskはいらない
  typedef struct packed {
    logic     valid;
    rob_idx_t rob_idx;
  } disp_stq_t;

  // STQからLDQへ
  typedef struct packed {
    stq_idx_t  tail_stq_idx;
    stq_mask_t st_dep_mask;   // 同じサイクルの前のスロットのstoreも含む
  } st_dep_t;

  // LDQのエントリ
  typedef struct packed {
    logic      valid;
    logic      addr_valid;
    addr_t     addr;
    logic      mmio;             // MMIOのloadはROBの先頭に来るまで待つ
    logic      cache_requested;  // NACK来たら落とす
    stq_mask_t st_dep_mask;      // 自分より古いstoreのmask
    stq_idx_t  tail_stq_idx;     // dispatch時のSTQのtail
    logic      violated;         // load順序違反
    logic      forwarded;        // forwardされた
    stq_idx_t  forward_stq_idx;  // forward元
    logic      gone_to_wb;       // WBに進んだ
    preg_t     rd;
    rob_idx_t  rob_idx;
    brmask_t   brmask;
  } ldq_entry_t;

  // STQのエントリ
  typedef struct packed {
    logic     valid;
    logic     addr_valid;
    addr_t    addr;
    logic     data_valid;
    word_t    data;
    logic     committed;
    logic     stored;      // D$がACKした
    rob_idx_t rob_idx;
  } stq_entry_t;

  // LDQからcontrollerへ
  typedef struct packed {
    logic     valid;
    logic     addr_valid;
    addr_t    addr;
    logic     mmio;
    logic     cache_requested;
    logic     gone_to_wb;
    preg_t    rd;
    rob_idx_t rob_idx;
    brmask_t  brmask;
  } ldq_controller_t;

  // LDQからsearcherへ
  typedef struct packed {
    logic      valid;
    logic      addr_valid;
    addr_t     addr;
    logic      cache_requested;
    logic      gone_to_wb;
    stq_mask_t st_dep_mask;
    stq_idx_t  tail_stq_idx;
    logic      forwarded;
    stq_idx_t  forward_stq_idx;
  } ldq_searcher_t;

  // STQからcontrollerへ
  typedef struct packed {
    logic     valid;  // commit済みでまだD$に出していない
    stq_idx_t idx;
    addr_t    addr;
    word_t    data;
  } stq_controller_t;

  // STQからsearcherへ
  typedef struct packed {
    logic  addr_valid;
    addr_t addr;
    logic  data_valid;
    word_t data;
  } stq_searcher_t;

  // controllerからLDQへ
  typedef struct packed {
    logic     valid;
    ldq_idx_t idx;
  } ldq_idx_with_valid_t;

  // controllerからSTQへ
  typedef struct packed {
    logic     valid;
    stq_idx_t idx;
  } stq_idx_with_valid_t;

  // controllerからLDQへ
  typedef struct packed {
    logic     valid;
    ldq_idx_t idx;
    addr_t    addr;
    logic     mmio;
  } ld_addr_t;

  // controllerからLDQへ
  typedef struct packed {
    logic     valid;
    ldq_idx_t idx;
    logic     forwarded;
    stq_idx_t forward_stq_idx;
  } ld_wb_notice_t;

  // controllerからSTQ、searcherへ
  typedef struct packed {
    logic     valid;
    stq_idx_t idx;
    addr_t    addr;
  } st_addr_t;

  // controllerからSTQへ
  typedef struct packed {
    logic     valid;
    stq_idx_t idx;
    word_t    data;
  } st_data_t;

  // controllerからsearcherへ
  typedef struct packed {
    logic     valid;
    ldq_idx_t idx;
    addr_t    addr;
  } forward_search_t;

  // searcherからcontrollerへ
  typedef struct packed {
    logic     hit;
    logic     data_valid;
    stq_idx_t stq_idx;
    word_t    data;
  } forward_result_t;

  // dc_req_ff、dc_respのtag
  typedef struct packed {
    logic     is_store;
    ldq_idx_t ldq_idx;
    stq_idx_t stq_idx;
  } lsu_tag_t;

  // D$に渡すtagの幅
  localparam int DC_TAG_W = $bits(lsu_tag_t);

  // controllerからD$へ
  typedef struct packed {
    logic valid;
    logic we;
    addr_t addr;
    word_t wdata;
    lsu_tag_t tag;
    brmask_t  brmask;  // このサイクルのbr_update_ffを当てた後。このサイクルにkillされるものは出さない
  } dc_req_t;

  // D$からcontrollerへ
  typedef struct packed {
    logic     valid;
    lsu_tag_t tag;
    logic     ack;    // 1:ack, 0:nack
    word_t    rdata;
  } dc_resp_t;

endpackage

`default_nettype wire
