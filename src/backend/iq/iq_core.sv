`timescale 1ns / 1ps
`default_nettype none

module iq_core
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import iq_types::*;
#(
  parameter int SIZE = 16,
  parameter int DISPATCH_W = 1,
  parameter int ISSUE_W = 1,
  parameter dest_eu_t EU_BASE = '0,  // EU=EU_BASE+port
  parameter logic [ISSUE_W-1:0][FU_PER_EU-1:0] SLOW_WAKEUP_FU = '0,
  parameter logic [ISSUE_W-1:0][FU_PER_EU-1:0] BLOCKING_FU = '0,
  parameter int WAKEUP_W = 5,
  parameter int BR_UPDATE_W = 1,
  parameter int PAYLOAD_W = 64
) (
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush

  // wrapper
  input wire logic disp_valid[DISPATCH_W],
  input wire wrapper_ff_t disp_entry[DISPATCH_W],  // wrapper -> ff
  input wire logic [PAYLOAD_W-1:0] disp_payload[DISPATCH_W],
  output logic disp_full,

  // wakeup bus
  input wire wakeup_t coming_wakeup[WAKEUP_W],
  output wakeup_t sending_wakeup[ISSUE_W],

  // ALUレーンのWBから
  input wire br_update_t br_update[BR_UPDATE_W],

  // FU (fdiv,fsqrtのブロック用)
  input wire logic [ISSUE_W-1:0][FU_PER_EU-1:0] dest_fu_blocked,

  // to RR
  output iq_rr_t rr_ff[ISSUE_W],
  output logic [PAYLOAD_W-1:0] rr_payload[ISSUE_W]
);

  localparam int IDX_W  = (SIZE > 1) ? $clog2(SIZE) : 1;
  localparam int PORT_W = (ISSUE_W > 1) ? $clog2(ISSUE_W) : 1;

  function automatic logic [PORT_W-1:0] port_of(input dest_eu_t eu);
    port_of = PORT_W'(eu - EU_BASE);
  endfunction

  // one hotをidxに
  function automatic logic [IDX_W-1:0] onehot_to_idx(input logic [SIZE-1:0] onehot);
    onehot_to_idx = '0;
    for (int i = 0; i < SIZE; i++) begin
      if (onehot[i]) onehot_to_idx |= IDX_W'(i);
    end
  endfunction

  // エントリ本体
  wrapper_ff_t iq_ff[SIZE];
  wrapper_ff_t n_iq_ff[SIZE];

  // portごとの使用中ビット
  logic [SIZE-1:0] bitmaps[ISSUE_W];
  logic [SIZE-1:0] n_bitmaps[ISSUE_W];

  function automatic logic branch_kill_check(input brmask_t brmask, input br_update_t br_upd[BR_UPDATE_W]);
    branch_kill_check = 1'b0;
    for (int i = 0; i < BR_UPDATE_W; i++) branch_kill_check |= br_killed(brmask, br_upd[i]);
  endfunction

  function automatic brmask_t apply_br_update(input brmask_t brmask, input br_update_t br_upd[BR_UPDATE_W]);
    apply_br_update = brmask;
    for (int i = 0; i < BR_UPDATE_W; i++) apply_br_update = br_resolved(apply_br_update, br_upd[i]);
  endfunction

  // 分岐ミスで消されたやつを抜いたbitmap
  logic [SIZE-1:0] killed_bitmaps[ISSUE_W];
  always_comb begin
    for (int i = 0; i < ISSUE_W; i++) begin
      killed_bitmaps[i] = bitmaps[i];
      for (int j = 0; j < SIZE; j++) begin
        killed_bitmaps[i][j] &= !branch_kill_check(iq_ff[j].brmask, br_update);
      end
    end
  end

  logic [SIZE-1:0] or_bitmaps;
  always_comb begin
    or_bitmaps = '0;
    for (int i = 0; i < ISSUE_W; i++) or_bitmaps |= bitmaps[i];  // kill前使ってパス短縮
  end

  // 空きスロット探し
  logic empty_found[DISPATCH_W];
  logic [IDX_W-1:0] alloc_slot[DISPATCH_W];
  find_empty_slot #(
    .SIZE(SIZE),
    .FIND_NUM(DISPATCH_W)
  ) find_empty_slot (
    .bitmap(or_bitmaps),
    .found (empty_found),
    .slot  (alloc_slot)
  );

  assign disp_full = ~empty_found[DISPATCH_W-1];

  // 空きにミスった分岐由来でないやつを入れる
  logic alloc_valid[DISPATCH_W];
  always_comb begin
    for (int i = 0; i < DISPATCH_W; i++) begin
      alloc_valid[i] = disp_valid[i] && empty_found[i] && !branch_kill_check(disp_entry[i].brmask, br_update);
    end
  end

  // 入った順を覚える
  logic [SIZE-1:0] older[SIZE];  // i older than j
  age_matrix #(
    .SIZE(SIZE),
    .DISPATCH_W(DISPATCH_W)
  ) u_age_matrix (
    .clk(clk),
    .lane_valid(alloc_valid),
    .alloc_slot(alloc_slot),
    .older(older)
  );

  // 両方wakeup済みでカウントも終わってたらready
  logic [SIZE-1:0] ready;
  always_comb begin
    logic rs1_ready;
    logic rs2_ready;
    for (int i = 0; i < SIZE; i++) begin
      rs1_ready = iq_ff[i].rs1.st.counting && iq_ff[i].rs1.st.cnt == 0;
      rs2_ready = iq_ff[i].rs2.st.counting && iq_ff[i].rs2.st.cnt == 0;
      ready[i]  = rs1_ready && rs2_ready;
    end
  end


  // issueしてからFUがblockedを出すまで止めておく
  localparam int ISSUE_TO_FU = 2;  // issueからFUまでのレイテンシ
  logic [(ISSUE_TO_FU>0 ? ISSUE_TO_FU : 1)-1:0] busy_memo[ISSUE_W][FU_PER_EU];

  logic [FU_PER_EU-1:0] fu_blocked[ISSUE_W];
  always_comb begin
    for (int i = 0; i < ISSUE_W; i++) begin
      for (int f = 0; f < FU_PER_EU; f++) fu_blocked[i][f] = dest_fu_blocked[i][f] || |busy_memo[i][f];
    end
  end

  // ポートごとのreq 自分のFUが止まってるエントリは出さない
  logic [SIZE-1:0] req[ISSUE_W];
  always_comb begin
    for (int i = 0; i < ISSUE_W; i++) begin
      for (int j = 0; j < SIZE; j++) begin
        req[i][j] = killed_bitmaps[i][j] && ready[j] && !fu_blocked[i][iq_ff[j].dest_fu];
      end
    end
  end

  logic [SIZE-1:0] grant[ISSUE_W];
  logic [IDX_W-1:0] issued_slot[ISSUE_W];
  logic issued[ISSUE_W];
  dest_fu_t issued_dest_fu[ISSUE_W];
  generate
    for (genvar i = 0; i < ISSUE_W; i++) begin : g_issue
      // 一番古いのを選ぶ
      selector #(
        .SIZE(SIZE)
      ) u_selector (
        .req  (req[i]),
        .older(older),
        .grant(grant[i])  // one hot
      );
      assign issued[i] = |grant[i] && !rst && !flush;
      assign issued_slot[i] = onehot_to_idx(grant[i]);
    end
  endgenerate

  always_comb begin
    for (int i = 0; i < ISSUE_W; i++) begin
      issued_dest_fu[i] = iq_ff[issued_slot[i]].dest_fu;
    end
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      for (int i = 0; i < ISSUE_W; i++) begin
        for (int f = 0; f < FU_PER_EU; f++) busy_memo[i][f] <= '0;
      end
    end else begin
      for (int i = 0; i < ISSUE_W; i++) begin
        for (int f = 0; f < FU_PER_EU; f++) begin
          busy_memo[i][f] <= (ISSUE_TO_FU)'({
            busy_memo[i][f][ISSUE_TO_FU-1:0], issued[i] && issued_dest_fu[i] == dest_fu_t'(f) && BLOCKING_FU[i][f]
          });
        end
      end
    end
  end

  // bitmap更新 dispatchで立ててissueで落とす
  always_comb begin
    for (int i = 0; i < ISSUE_W; i++) begin
      n_bitmaps[i] = killed_bitmaps[i];
    end

    for (int i = 0; i < DISPATCH_W; i++) begin
      if (alloc_valid[i]) n_bitmaps[port_of(disp_entry[i].dest_eu)][alloc_slot[i]] = 1'b1;
    end
    for (int i = 0; i < ISSUE_W; i++) begin
      if (issued[i]) n_bitmaps[i][issued_slot[i]] = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      for (int i = 0; i < ISSUE_W; i++) bitmaps[i] <= '0;
    end else begin
      for (int i = 0; i < ISSUE_W; i++) bitmaps[i] <= n_bitmaps[i];
    end
  end

  // まだwakeupされてないソースにだけ当てる
  function automatic src_reg_t apply_wakeup(input src_reg_t r, input wakeup_t w[WAKEUP_W]);
    src_reg_t ret = r;
    for (int i = 0; i < WAKEUP_W; i++) begin
      if (w[i].valid && !r.st.counting && w[i].preg == r.preg) begin
        ret.st.counting = 1'b1;
        ret.st.cnt      = w[i].latency;
      end
    end
    return ret;
  endfunction

  always_comb begin
    // カウントダウンしてからwakeup
    n_iq_ff = iq_ff;
    for (int i = 0; i < SIZE; i++) begin
      if (iq_ff[i].rs1.st.counting && iq_ff[i].rs1.st.cnt > 0) n_iq_ff[i].rs1.st.cnt = iq_ff[i].rs1.st.cnt - 1;
      if (iq_ff[i].rs2.st.counting && iq_ff[i].rs2.st.cnt > 0) n_iq_ff[i].rs2.st.cnt = iq_ff[i].rs2.st.cnt - 1;
      n_iq_ff[i].rs1 = apply_wakeup(n_iq_ff[i].rs1, coming_wakeup);
      n_iq_ff[i].rs2 = apply_wakeup(n_iq_ff[i].rs2, coming_wakeup);
      n_iq_ff[i].brmask = apply_br_update(iq_ff[i].brmask, br_update);
    end

    // dispatch 同じサイクルのwakeupと分岐も当てる
    for (int i = 0; i < DISPATCH_W; i++) begin
      if (alloc_valid[i]) begin
        // disp_entryにもcnt-1をあてる
        n_iq_ff[alloc_slot[i]] = disp_entry[i];
        if (disp_entry[i].rs1.st.counting && disp_entry[i].rs1.st.cnt > 0)
          n_iq_ff[alloc_slot[i]].rs1.st.cnt = disp_entry[i].rs1.st.cnt - 1;
        if (disp_entry[i].rs2.st.counting && disp_entry[i].rs2.st.cnt > 0)
          n_iq_ff[alloc_slot[i]].rs2.st.cnt = disp_entry[i].rs2.st.cnt - 1;
        n_iq_ff[alloc_slot[i]].rs1 = apply_wakeup(n_iq_ff[alloc_slot[i]].rs1, coming_wakeup);
        n_iq_ff[alloc_slot[i]].rs2 = apply_wakeup(n_iq_ff[alloc_slot[i]].rs2, coming_wakeup);
        n_iq_ff[alloc_slot[i]].brmask = apply_br_update(disp_entry[i].brmask, br_update);
      end
    end
  end

  always_ff @(posedge clk) begin
    for (int i = 0; i < SIZE; i++) iq_ff[i] <= n_iq_ff[i];
  end

  // slowなFUとrdなしは出さない
  always_comb begin
    for (int i = 0; i < ISSUE_W; i++) begin
      sending_wakeup[i].valid = issued[i] && !SLOW_WAKEUP_FU[i][issued_dest_fu[i]] && iq_ff[issued_slot[i]].rd.typ != PREG_TYPE_NONE;
      sending_wakeup[i].preg = iq_ff[issued_slot[i]].rd;
      sending_wakeup[i].latency = iq_ff[issued_slot[i]].lat;
    end
  end

  // payload
  logic [PAYLOAD_W-1:0] iq_payload[ISSUE_W];
  multi_port_ram #(
    .SIZE(SIZE),
    .ENTRY_WIDTH(PAYLOAD_W),
    .R(ISSUE_W),
    .W(DISPATCH_W)
  ) payload_ram (
    .clk   (clk),
    .w_en  (alloc_valid),
    .w_addr(alloc_slot),
    .w_data(disp_payload),
    .r_addr(issued_slot),
    .r_data(iq_payload)
  );

  // RRのためのFFに入れる
  always_ff @(posedge clk) begin
    if (rst || flush) begin
      for (int i = 0; i < ISSUE_W; i++) begin
        rr_ff[i] <= '0;
        rr_payload[i] <= '0;
      end
    end else begin
      for (int i = 0; i < ISSUE_W; i++) begin
        rr_payload[i] <= iq_payload[i];
        rr_ff[i].valid <= issued[i];
        rr_ff[i].rd    <= iq_ff[issued_slot[i]].rd;
        rr_ff[i].rs1   <= iq_ff[issued_slot[i]].rs1.preg;
        rr_ff[i].rs2   <= iq_ff[issued_slot[i]].rs2.preg;
        rr_ff[i].dest_fu <= iq_ff[issued_slot[i]].dest_fu;
        rr_ff[i].brmask  <= apply_br_update(iq_ff[issued_slot[i]].brmask, br_update);
      end
    end
  end

endmodule

`default_nettype wire
