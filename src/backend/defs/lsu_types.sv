`timescale 1ns / 1ps
`default_nettype none

package lsu_types;
  import types::*;
  import ooo_types::*;

  typedef struct packed {
    logic     wrap;
    ldq_idx_t ldq_idx;
  } ldq_ptr_t;

  typedef struct packed {
    logic     wrap;
    stq_idx_t stq_idx;
  } stq_ptr_t;

  localparam int STQ_CNT_W = $clog2(STQ_SIZE + 1);
  typedef logic [STQ_CNT_W-1:0] stq_cnt_t;

  function automatic ldq_ptr_t ldq_ptr_inc(input ldq_ptr_t p);
    if (p.ldq_idx == ldq_idx_t'(LDQ_SIZE - 1)) begin
      ldq_ptr_inc.wrap = ~p.wrap;
      ldq_ptr_inc.ldq_idx = '0;
    end else begin
      ldq_ptr_inc.wrap = p.wrap;
      ldq_ptr_inc.ldq_idx = p.ldq_idx + 1'b1;
    end
  endfunction

  function automatic ldq_ptr_t ldq_ptr_dec(input ldq_ptr_t p);
    if (p.ldq_idx == ldq_idx_t'(0)) begin
      ldq_ptr_dec.wrap = ~p.wrap;
      ldq_ptr_dec.ldq_idx = ldq_idx_t'(LDQ_SIZE - 1);
    end else begin
      ldq_ptr_dec.wrap = p.wrap;
      ldq_ptr_dec.ldq_idx = p.ldq_idx - 1'b1;
    end
  endfunction

  function automatic logic ldq_ptr_full(input ldq_ptr_t head, input ldq_ptr_t tail);
    ldq_ptr_full = head.ldq_idx == tail.ldq_idx && head.wrap != tail.wrap;
  endfunction

  function automatic stq_ptr_t stq_ptr_inc(input stq_ptr_t p);
    if (p.stq_idx == stq_idx_t'(STQ_SIZE - 1)) begin
      stq_ptr_inc.wrap = ~p.wrap;
      stq_ptr_inc.stq_idx = '0;
    end else begin
      stq_ptr_inc.wrap = p.wrap;
      stq_ptr_inc.stq_idx = p.stq_idx + 1'b1;
    end
  endfunction

  // fromからtoまでの個数
  function automatic stq_cnt_t stq_ptr_dist(input stq_ptr_t from, input stq_ptr_t to);
    if (from.wrap == to.wrap) begin
      stq_ptr_dist = stq_cnt_t'(to.stq_idx) - stq_cnt_t'(from.stq_idx);
    end else begin
      stq_ptr_dist = stq_cnt_t'(to.stq_idx) + stq_cnt_t'(STQ_SIZE) - stq_cnt_t'(from.stq_idx);
    end
  endfunction

  // idxのfromからのオフセット
  function automatic stq_cnt_t stq_ptr_ofs(input stq_idx_t idx, input stq_ptr_t from);
    if (idx >= from.stq_idx) begin
      stq_ptr_ofs = idx - stq_cnt_t'(from.stq_idx);
    end else begin
      stq_ptr_ofs = idx + stq_cnt_t'(STQ_SIZE) - stq_cnt_t'(from.stq_idx);
    end
  endfunction

  // エントリiがfromからtoまでに入っているか
  function automatic logic stq_in_range(input stq_idx_t i, input stq_ptr_t from, input stq_ptr_t to);
    stq_in_range = stq_ptr_ofs(i, from) < stq_ptr_dist(from, to);
  endfunction

  function automatic logic stq_ptr_full(input stq_ptr_t head, input stq_ptr_t tail);
    stq_ptr_full = head.stq_idx == tail.stq_idx && head.wrap != tail.wrap;
  endfunction

  typedef logic [STQ_SIZE-1:0] stq_mask_t;
  typedef logic [LDQ_SIZE-1:0] ldq_mask_t;

  // 当たったstoreのビットを落とす
  function automatic stq_mask_t apply_st_resolve(input stq_mask_t brmask, input stq_mask_t release_mask);
    return brmask & ~release_mask;
  endfunction

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
    stq_mask_t older_st_mask;  // 同じサイクルの前のスロットのstoreも含む
  } older_st_t;

  // LDQのエントリ
  typedef struct packed {
    logic valid;
    logic addr_valid;
    addr_t addr;
    logic mmio;  // MMIOのloadはROBの先頭に来るまで待つ
    logic ld_requested;  // NACK来たら落とす
    logic stale;  // D$に出した後に古いstoreとアドレスが一致した。respを捨てて出し直す
    stq_mask_t older_st_mask;  // 自分より古いstoreのmask
    stq_idx_t tail_stq_idx;  // dispatch時のSTQのtail
    logic violated;  // load順序違反
    logic fwd_hit;  // 自分より古いstoreにアドレスが一致するものがある
    stq_idx_t fwd_stq_idx;  // 暫定のforward元
    logic gone_to_wb;  // WBに進んだ
    preg_t rd;
    rob_idx_t rob_idx;
    brmask_t brmask;
  } ldq_entry_t;

  // STQのエントリ
  typedef struct packed {
    logic     valid;
    logic     addr_valid;
    addr_t    addr;
    logic     data_valid;
    word_t    data;
    logic     committed;
    logic     st_requested;  // D$に出した(返事はまだ)
    logic     stale;         // nackでなかったことになった
    logic     stored;        // D$がACKした
    rob_idx_t rob_idx;
  } stq_entry_t;

  // LDQからcontrollerへ
  typedef struct packed {
    logic     valid;
    logic     addr_valid;
    addr_t    addr;
    logic     mmio;
    logic     ld_requested;
    logic     stale;
    logic     gone_to_wb;
    logic     fwd_hit;
    stq_idx_t fwd_stq_idx;
    preg_t    rd;
    rob_idx_t rob_idx;
    brmask_t  brmask;
  } ldq_controller_t;

  // LDQからsearcherへ
  typedef struct packed {
    logic      valid;
    logic      addr_valid;
    addr_t     addr;
    logic      ld_requested;
    logic      gone_to_wb;
    stq_mask_t older_st_mask;
    stq_idx_t  tail_stq_idx;
    logic      fwd_hit;
    stq_idx_t  fwd_stq_idx;
  } ldq_searcher_t;

  // STQからcontrollerへ
  typedef struct packed {
    logic     valid;    // commit済みでまだD$に出していない
    stq_idx_t stq_idx;
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

  // STQからcontrollerへ
  typedef struct packed {
    logic  data_valid;
    word_t data;
  } stq_fwd_t;

  // controllerからLDQへ
  typedef struct packed {
    logic     valid;
    ldq_idx_t ldq_idx;
  } ldq_idx_with_valid_t;

  // controllerからSTQへ
  typedef struct packed {
    logic     valid;
    stq_idx_t stq_idx;
  } stq_idx_with_valid_t;

  // searcherからLDQへ
  typedef struct packed {
    logic     hit;
    stq_idx_t stq_idx;
  } ld_fwd_t;

  // forwardするloadの候補
  typedef struct packed {
    logic     valid;
    ldq_idx_t ldq_idx;
    stq_idx_t stq_idx;  // forward元
  } fwd_cand_t;

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
