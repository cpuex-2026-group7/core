`timescale 1ns / 1ps
`default_nettype none

module stq
  import types::*;
  import ooo_types::*;
  import back_types::*;
  import ex_types::*;
  import rob_types::*;
  import lsu_types::*;
#(
  parameter int DISP_W   = 1,
  parameter int COMMIT_W = 1
) (
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush(ROBのFF)。commit済みは残す

  // dispatch
  input wire disp_stq_t disp_st[DISP_W],
  output stq_idx_t disp_stq_idx[DISP_W],
  output logic disp_full[DISP_W],
  // dispatch(branch)
  input wire logic disp_br_valid[DISP_W],
  input wire br_tag_t disp_br_tag[DISP_W],

  // LDQへ
  output older_st_t older_st[DISP_W],
  output stq_mask_t stq_release_mask,  // このサイクルに解放したエントリ

  // AGUから
  input wire ex_lsu_t ex_lsu,

  // controller
  input wire logic st_requested,  // stq_exec_headを進める
  input wire stq_idx_with_valid_t st_ack,
  input wire stq_idx_with_valid_t st_nack,  // stq_exec_headをそこまで戻す
  output stq_controller_t stq_controller,  // stq_exec_headのstore
  output stq_cnt_t stq_cnt,  // STQの中身の数

  // searcherへ
  output stq_searcher_t stq_searcher_ff[STQ_SIZE],

  // EXから
  input wire br_update_t br_update_ff,

  // ROB
  input wire logic commit_st[COMMIT_W],
  output complete_t complete_st,
  output logic stq_empty  // commit済みのstoreも全部D$に書き終わった(halt用)
);

  stq_ptr_t stq_head, stq_commit_head, stq_exec_head, stq_tail;
  stq_ptr_t stq_tail_snapshot[MAX_BR];
  stq_entry_t stq_ff[STQ_SIZE];

  always_comb begin
    for (int i = 0; i < STQ_SIZE; i++) begin
      stq_searcher_ff[i].addr_valid = stq_ff[i].addr_valid;
      stq_searcher_ff[i].addr = stq_ff[i].addr;
      stq_searcher_ff[i].data_valid = stq_ff[i].data_valid;
      stq_searcher_ff[i].data = stq_ff[i].data;
    end
  end

  // commit済みでまだ要求していないものがある
  assign stq_controller.valid = stq_exec_head != stq_commit_head && !stq_ff[stq_exec_head.stq_idx].st_requested;
  assign stq_controller.stq_idx = stq_exec_head.stq_idx;
  assign stq_controller.addr = stq_ff[stq_exec_head.stq_idx].addr;
  assign stq_controller.data = stq_ff[stq_exec_head.stq_idx].data;

  assign stq_cnt = stq_ptr_dist(stq_head, stq_tail);

  assign stq_empty = stq_head == stq_tail;

  // headがstoredなら解放
  always_comb begin
    stq_release_mask = '0;
    stq_release_mask[stq_head.stq_idx] = stq_ff[stq_head.stq_idx].stored;
  end

  // disp_tailとtail_snapshot
  stq_ptr_t disp_tail[DISP_W+1];
  stq_ptr_t n_stq_tail_snapshot[MAX_BR];
  always_comb begin
    for (int i = 0; i < MAX_BR; i++) begin
      n_stq_tail_snapshot[i] = stq_tail_snapshot[i];
    end
    disp_tail[0] = stq_tail;
    for (int i = 0; i < DISP_W; i++) begin
      disp_stq_idx[i] = disp_tail[i].stq_idx;
      disp_full[i] = stq_ptr_full(stq_head, disp_tail[i]);

      // olderを詰める
      older_st[i].tail_stq_idx = disp_tail[i].stq_idx;
      for (int j = 0; j < STQ_SIZE; j++) begin
        older_st[i].older_st_mask[j] = stq_in_range(j, stq_head, disp_tail[i]) && !stq_release_mask[j];
      end

      // snapshotを詰める
      if (disp_br_valid[i]) begin
        n_stq_tail_snapshot[disp_br_tag[i]] = disp_tail[i];
      end

      // 命令が入った場合disp_tailを進める
      if (disp_st[i].valid && !disp_full[i]) begin
        disp_tail[i+1] = stq_ptr_inc(disp_tail[i]);
      end else begin
        disp_tail[i+1] = disp_tail[i];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < MAX_BR; i++) begin
        stq_tail_snapshot[i] <= '0;
      end
    end else begin
      for (int i = 0; i < MAX_BR; i++) begin
        stq_tail_snapshot[i] <= n_stq_tail_snapshot[i];
      end
    end
  end

  // AGUからの入力
  logic ex_st_addr_valid, ex_st_data_valid;
  assign ex_st_addr_valid = ex_lsu.is_store && ex_lsu.addr_valid;
  assign ex_st_data_valid = ex_lsu.is_store && ex_lsu.data_valid;

  assign complete_st.valid = (ex_st_addr_valid || ex_st_data_valid)
      && (ex_st_addr_valid || stq_ff[ex_lsu.stq_idx].addr_valid)
      && (ex_st_data_valid || stq_ff[ex_lsu.stq_idx].data_valid);
  assign complete_st.rob_idx = stq_ff[ex_lsu.stq_idx].rob_idx;

  // D$の返事
  logic st_resp_idx_stale;
  stq_idx_t st_resp_idx;
  stq_ptr_t st_nack_ptr;
  assign st_resp_idx = st_nack.valid ? st_nack.stq_idx : st_ack.stq_idx;
  assign st_resp_idx_stale = (st_ack.valid || st_nack.valid) && stq_ff[st_resp_idx].stale;
  assign st_nack_ptr.wrap = st_nack.stq_idx >= stq_head.stq_idx ? stq_head.wrap : ~stq_head.wrap;
  assign st_nack_ptr.stq_idx = st_nack.stq_idx;

  // stq_ffとhead,tail
  stq_ptr_t n_stq_head, n_stq_commit_head, n_stq_exec_head, n_stq_tail;
  stq_entry_t n_stq_ff[STQ_SIZE];
  always_comb begin
    for (int i = 0; i < STQ_SIZE; i++) begin
      n_stq_ff[i] = stq_ff[i];
    end
    n_stq_head = stq_head;
    n_stq_commit_head = stq_commit_head;
    n_stq_exec_head = stq_exec_head;
    n_stq_tail = disp_tail[DISP_W];

    // dispatch
    if (!br_update_ff.mispredict && !flush) begin
      for (int i = 0; i < DISP_W; i++) begin
        if (disp_st[i].valid && !disp_full[i]) begin
          n_stq_ff[disp_stq_idx[i]].valid = 1'b1;
          n_stq_ff[disp_stq_idx[i]].addr_valid = 1'b0;
          n_stq_ff[disp_stq_idx[i]].data_valid = 1'b0;
          n_stq_ff[disp_stq_idx[i]].committed = 1'b0;
          n_stq_ff[disp_stq_idx[i]].st_requested = 1'b0;
          n_stq_ff[disp_stq_idx[i]].stale = 1'b0;
          n_stq_ff[disp_stq_idx[i]].stored = 1'b0;
          n_stq_ff[disp_stq_idx[i]].rob_idx = disp_st[i].rob_idx;
        end
      end
    end

    // AGUから
    if (ex_st_addr_valid) begin
      n_stq_ff[ex_lsu.stq_idx].addr_valid = 1'b1;
      n_stq_ff[ex_lsu.stq_idx].addr = ex_lsu.addr;
    end
    if (ex_st_data_valid) begin
      n_stq_ff[ex_lsu.stq_idx].data_valid = 1'b1;
      n_stq_ff[ex_lsu.stq_idx].data = ex_lsu.data;
    end

    // commitでcommit_headを進める
    for (int i = 0; i < COMMIT_W; i++) begin
      if (commit_st[i]) begin
        n_stq_ff[n_stq_commit_head.stq_idx].committed = 1'b1;
        n_stq_commit_head = stq_ptr_inc(n_stq_commit_head);
      end
    end

    // exec_headを進める
    if (st_requested) begin
      n_stq_ff[stq_exec_head.stq_idx].st_requested = 1'b1;
      n_stq_exec_head = stq_ptr_inc(stq_exec_head);
    end

    // ackとnack
    if (st_resp_idx_stale) begin
      // staleにしてたやつが帰ってきた
      n_stq_ff[st_resp_idx].st_requested = 1'b0;
      n_stq_ff[st_resp_idx].stale = 1'b0;
    end else if (st_ack.valid) begin
      // ackされたstoreはstoredにする
      n_stq_ff[st_ack.stq_idx].st_requested = 1'b0;
      n_stq_ff[st_ack.stq_idx].stored = 1'b1;
    end else if (st_nack.valid) begin
      // nackされたstoreからやりなおし
      for (int i = 0; i < STQ_SIZE; i++) begin
        if (stq_in_range(i, st_nack_ptr, n_stq_exec_head)) begin
          n_stq_ff[i].stored = 1'b0;
          n_stq_ff[i].stale  = n_stq_ff[i].st_requested;
        end
      end
      n_stq_ff[st_nack.stq_idx].st_requested = 1'b0;
      n_stq_ff[st_nack.stq_idx].stale = 1'b0;
      n_stq_exec_head = st_nack_ptr;
    end

    // headを進める
    if (stq_ff[stq_head.stq_idx].stored) begin
      n_stq_ff[stq_head.stq_idx].valid = 1'b0;
      n_stq_ff[stq_head.stq_idx].stored = 1'b0;
      n_stq_head = stq_ptr_inc(stq_head);
    end

    // 最後にflush確認
    if (flush) begin
      n_stq_tail = n_stq_commit_head;
    end else if (br_update_ff.mispredict) begin
      n_stq_tail = stq_tail_snapshot[br_update_ff.tag];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < STQ_SIZE; i++) begin
        stq_ff[i] <= '0;
      end
      stq_head <= '0;
      stq_commit_head <= '0;
      stq_exec_head <= '0;
      stq_tail <= '0;
    end else begin
      for (int i = 0; i < STQ_SIZE; i++) begin
        stq_ff[i] <= n_stq_ff[i];
      end
      stq_head <= n_stq_head;
      stq_commit_head <= n_stq_commit_head;
      stq_exec_head <= n_stq_exec_head;
      stq_tail <= n_stq_tail;
    end
  end

endmodule

`default_nettype wire
