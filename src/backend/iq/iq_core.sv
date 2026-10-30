`timescale 1ns / 1ps
`default_nettype none

module iq_core
  import types::*;
  import back_types::*;
  import iq_types::*;
#(
  parameter int SIZE = 16,
  parameter int DISPATCH_W = 1,
  parameter int ISSUE_W = 1,
  parameter int DEST_FU_NUM = 1,
  parameter logic [DEST_FU_NUM-1:0][ISSUE_W-1:0] FU_LISTEN_PORT = '0, // このFUはこのPORTからの入力を受け付けますか
  // FU_LISTEN_PORT = '{ 3'b100,   // FU_F_SQRT
  //               3'b100,   // FU_F_DIV
  //               3'b010,   // FU_F_LONG
  //               3'b001 }; // FU_F_SHORT
  parameter logic [DEST_FU_NUM-1:0] SLOW_WAKEUP_FU = '0,
  parameter logic [DEST_FU_NUM-1:0] BLOCKING_FU = '0,
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
  input wire logic dest_fu_blocked[DEST_FU_NUM],
  output logic fired[ISSUE_W],
  output dest_fu_t fired_dest_fu[ISSUE_W],

  // to RR
  output iq_rr_t rr_ff[ISSUE_W],
  output logic [PAYLOAD_W-1:0] rr_payload[ISSUE_W]
);

  localparam int IDX_W = (SIZE > 1) ? $clog2(SIZE) : 1;

  function automatic logic [IDX_W-1:0] onehot_to_idx(input logic [SIZE-1:0] onehot);
    onehot_to_idx = '0;
    for (int i = 0; i < SIZE; i++) begin
      if (onehot[i]) onehot_to_idx |= IDX_W'(i);
    end
  endfunction

  logic [SIZE-1:0] bitmaps[DEST_FU_NUM];
  logic [SIZE-1:0] n_bitmaps[DEST_FU_NUM];
  logic empty_found[DISPATCH_W];
  logic [IDX_W-1:0] alloc_slot[DISPATCH_W];

  logic [SIZE-1:0] or_bitmaps;
  always_comb begin
    or_bitmaps = '0;
    for (int i = 0; i < DEST_FU_NUM; i++) or_bitmaps |= bitmaps[i];
  end

  // empty slot
  find_empty_slot #(
    .SIZE(SIZE),
    .FIND_NUM(DISPATCH_W)
  ) find_empty_slot (
    .bitmap(or_bitmaps),
    .found (empty_found),
    .slot  (alloc_slot)
  );

  assign disp_full = ~empty_found[DISPATCH_W-1];

  logic alloc_valid[DISPATCH_W];
  logic [IDX_W-1:0] issued_slot[ISSUE_W];

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

  logic [SIZE-1:0] ready;  // combは下の方
  logic [SIZE-1:0] req[ISSUE_W];

  localparam int FIRE_TO_FU = 2;  // issueからFUまでのレイテンシ
  logic [FIRE_TO_FU-1:0] busy_memo[DEST_FU_NUM];
  always_comb begin
    for (int i = 0; i < ISSUE_W; i++) begin
      req[i] = '0;
      for (int j = 0; j < DEST_FU_NUM; j++) begin
        if (FU_LISTEN_PORT[j][i] && !dest_fu_blocked[j] && !busy_memo[j]) req[i] |= bitmaps[j];
      end
      req[i] &= ready;
    end
  end

  logic [SIZE-1:0] grant[ISSUE_W];
  generate
    for (genvar i = 0; i < ISSUE_W; i++) begin : g_issue
      // issue slot
      selector #(
        .SIZE(SIZE)
      ) u_selector (
        .req  (req[i]),
        .older(older),
        .grant(grant[i])  // one hot
      );
      assign fired[i] = |grant[i];
      assign issued_slot[i] = onehot_to_idx(grant[i]);
    end
  endgenerate

  logic fired_fu[DEST_FU_NUM];
  always_comb begin
    for (int i = 0; i < ISSUE_W; i++) begin
      if (fired[i]) fired_fu[fired_dest_fu[i]] = 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      for (int i = 0; i < DEST_FU_NUM; i++) busy_memo[i] <= '0;
    end else begin
      for (int i = 0; i < DEST_FU_NUM; i++) begin
        busy_memo[i] <= {busy_memo[i][FIRE_TO_FU-2:0], fired_fu[i] && BLOCKING_FU[fired_fu[i]]};
      end
    end
  end

  // selectの処理
  always_comb begin
    for (int i = 0; i < DISPATCH_W; i++) begin
      alloc_valid[i] = disp_valid[i] && empty_found[i];
    end

    // bitmap更新
    for (int i = 0; i < DEST_FU_NUM; i++) begin
      n_bitmaps[i] = bitmaps[i];
    end

    for (int i = 0; i < DISPATCH_W; i++) begin
      if (alloc_valid[i]) n_bitmaps[disp_entry[i].dest_fu][alloc_slot[i]] = 1'b1;
    end
    for (int i = 0; i < ISSUE_W; i++) begin
      if (fired[i]) n_bitmaps[fired_dest_fu[i]][issued_slot[i]] = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      for (int i = 0; i < DEST_FU_NUM; i++) bitmaps[i] <= '0;
    end else begin
      for (int i = 0; i < DEST_FU_NUM; i++) bitmaps[i] <= n_bitmaps[i];
    end
  end

  logic [PAYLOAD_W-1:0] iq_payload[ISSUE_W];

  // payload
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

  // FF
  wrapper_ff_t iq_ff  [SIZE];
  wrapper_ff_t n_iq_ff[SIZE];

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
        rr_ff[i].valid <= fired[i];
        rr_ff[i].rd    <= iq_ff[issued_slot[i]].rd;
        rr_ff[i].rs1   <= iq_ff[issued_slot[i]].rs1.preg;
        rr_ff[i].rs2   <= iq_ff[issued_slot[i]].rs2.preg;
        rr_ff[i].dest_fu <= iq_ff[issued_slot[i]].dest_fu;
        rr_ff[i].brmask  <= iq_ff[issued_slot[i]].brmask;
      end
    end
  end

  always_comb begin
    for (int i = 0; i < ISSUE_W; i++) begin
      fired_dest_fu[i] = iq_ff[issued_slot[i]].dest_fu;
    end
  end

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
    // ff更新
    n_iq_ff = iq_ff;
    for (int i = 0; i < SIZE; i++) begin
      if (iq_ff[i].rs1.st.counting && iq_ff[i].rs1.st.cnt > 0) n_iq_ff[i].rs1.st.cnt = iq_ff[i].rs1.st.cnt - 1;
      if (iq_ff[i].rs2.st.counting && iq_ff[i].rs2.st.cnt > 0) n_iq_ff[i].rs2.st.cnt = iq_ff[i].rs2.st.cnt - 1;
      n_iq_ff[i].rs1 = apply_wakeup(n_iq_ff[i].rs1, coming_wakeup);
      n_iq_ff[i].rs2 = apply_wakeup(n_iq_ff[i].rs2, coming_wakeup);
    end

    // dispatch
    for (int i = 0; i < DISPATCH_W; i++) begin
      if (alloc_valid[i]) begin
        n_iq_ff[alloc_slot[i]] = disp_entry[i];
        n_iq_ff[alloc_slot[i]].rs1 = apply_wakeup(disp_entry[i].rs1, coming_wakeup);
        n_iq_ff[alloc_slot[i]].rs2 = apply_wakeup(disp_entry[i].rs2, coming_wakeup);
      end
    end
  end

  always_comb begin
    for (int i = 0; i < ISSUE_W; i++) begin
      sending_wakeup[i].valid = fired[i] && !flush && !SLOW_WAKEUP_FU[fired_dest_fu[i]] && iq_ff[issued_slot[i]].rd.type != PREG_TYPE_NONE;
      sending_wakeup[i].preg = iq_ff[issued_slot[i]].rd;
      sending_wakeup[i].latency = iq_ff[issued_slot[i]].lat;
    end
  end



  always_comb begin
    logic rs1_ready;
    logic rs2_ready;
    for (int i = 0; i < SIZE; i++) begin
      rs1_ready = iq_ff[i].rs1.st.counting && iq_ff[i].rs1.st.cnt == 0;
      rs2_ready = iq_ff[i].rs2.st.counting && iq_ff[i].rs2.st.cnt == 0;
      ready[i]  = rs1_ready && rs2_ready;
    end
  end

  always_ff @(posedge clk) begin
    for (int i = 0; i < SIZE; i++) iq_ff[i] <= n_iq_ff[i];
  end

endmodule

`default_nettype wire
