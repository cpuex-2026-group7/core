`timescale 1ns / 1ps
`default_nettype none

module iq_top
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import iq_types::*;
#(
  parameter int I_PREG_NUM = 64,
  parameter int F_PREG_NUM = 64,
  parameter int SIZE_INT = 16,
  parameter int SIZE_MEM = 16,
  parameter int SIZE_FPU = 16,
  parameter int DISPATCH_W_INT = 1,
  parameter int DISPATCH_W_MEM = 1,
  parameter int DISPATCH_W_FPU = 1
) (
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush

  // dispatch
  input wire logic disp_valid_int[DISPATCH_W_INT],
  input wire disp_uop_t disp_uop_int[DISPATCH_W_INT],
  output logic disp_full_int,

  input wire logic disp_valid_mem[DISPATCH_W_MEM],
  input wire disp_uop_t disp_uop_mem[DISPATCH_W_MEM],
  output logic disp_full_mem,

  input wire logic disp_valid_fpu[DISPATCH_W_FPU],
  input wire disp_uop_t disp_uop_fpu[DISPATCH_W_FPU],
  output logic disp_full_fpu,

  // slow wakeup
  input wire wakeup_t slow_wakeup_mem,
  input wire wakeup_t slow_wakeup_fpu,

  // ex_topのFFから
  input wire br_update_t br_update_ff,

  // fdiv,fsqrtから
  input wire fdiv_blocked,
  input wire fsqrt_blocked,

  // to RR
  output iq_rr_t rr_int_ff[1],
  output int_payload_t rr_payload_int_ff[1],

  output iq_rr_t rr_mem_ff[1],
  output mem_payload_t rr_payload_mem_ff[1],
  output logic [1:0] rr_issue_part_mem_ff[1],

  output iq_rr_t rr_fpu_ff[3],
  output float_payload_t rr_payload_fpu_ff[3]
);

  // MEMとF超長はissue時にwakeupを出さない(slow_wakeupで来る)
  wakeup_t int_wakeup[1];
  wakeup_t fpu_wakeup[3];  // {F短, F長, F超長}

  // ALUはI、F短とfdiv,fsqrtはFにしかならないのでそのまま入れる
  localparam int I_WAKEUP_W = 3;
  localparam int F_WAKEUP_W = 4;
  wakeup_t i_wakeup[I_WAKEUP_W];
  wakeup_t f_wakeup[F_WAKEUP_W];

  function automatic wakeup_t type_check(input wakeup_t w, input preg_type_t typ);
    type_check = w;
    type_check.valid = w.valid && w.preg.typ == typ;
  endfunction

  wakeup_t fpu_long_wakeup_ff;  // cnt-1して1サイクルずらす (タイミングの都合)
  always_ff @(posedge clk) begin
    if (rst || flush) fpu_long_wakeup_ff <= '0;
    else begin
      fpu_long_wakeup_ff <= type_check(fpu_wakeup[1], PREG_TYPE_F);
      fpu_long_wakeup_ff.latency <= fpu_wakeup[1].latency - 1;
    end
  end

  always_comb begin
    i_wakeup[0] = int_wakeup[0];
    i_wakeup[1] = type_check(slow_wakeup_mem, PREG_TYPE_I);
    i_wakeup[2] = type_check(fpu_long_wakeup_ff, PREG_TYPE_I);

    f_wakeup[0] = type_check(slow_wakeup_mem, PREG_TYPE_F);
    f_wakeup[1] = fpu_wakeup[0];
    f_wakeup[2] = type_check(fpu_long_wakeup_ff, PREG_TYPE_F);
    f_wakeup[3] = slow_wakeup_fpu;
  end

  src_state_t i_preg_state  [I_PREG_NUM];
  src_state_t f_preg_state  [F_PREG_NUM];

  src_state_t n_i_preg_state[I_PREG_NUM];
  src_state_t n_f_preg_state[F_PREG_NUM];

  always_comb begin
    // I PREG
    for (int i = 0; i < I_PREG_NUM; i++) begin
      n_i_preg_state[i] = i_preg_state[i];
      if (i_preg_state[i].counting) begin
        if (i_preg_state[i].cnt > 0) begin
          n_i_preg_state[i].cnt = i_preg_state[i].cnt - 1;
        end
      end else begin
        // wakeupが来たらカウント開始
        // !countingのときはcnt=0の前提
        for (int j = 0; j < I_WAKEUP_W; j++) begin
          if (i_wakeup[j].valid && i_wakeup[j].preg.idx == preg_idx_t'(i)) begin
            n_i_preg_state[i].counting |= 1'b1;
            n_i_preg_state[i].cnt |= i_wakeup[j].latency;
          end
        end
      end
      // dispatchのrdを結果待ちでマーク
      for (int j = 0; j < DISPATCH_W_INT; j++) begin
        if (disp_valid_int[j] && disp_uop_int[j].rd.typ == PREG_TYPE_I && disp_uop_int[j].rd.idx == preg_idx_t'(i)) begin
          n_i_preg_state[i].counting = 1'b0;
          n_i_preg_state[i].cnt = '0;
        end
      end
      for (int j = 0; j < DISPATCH_W_MEM; j++) begin
        if (disp_valid_mem[j] && disp_uop_mem[j].rd.typ == PREG_TYPE_I && disp_uop_mem[j].rd.idx == preg_idx_t'(i)) begin
          n_i_preg_state[i].counting = 1'b0;
          n_i_preg_state[i].cnt = '0;
        end
      end
      for (int j = 0; j < DISPATCH_W_FPU; j++) begin
        if (disp_valid_fpu[j] && disp_uop_fpu[j].rd.typ == PREG_TYPE_I && disp_uop_fpu[j].rd.idx == preg_idx_t'(i)) begin
          n_i_preg_state[i].counting = 1'b0;
          n_i_preg_state[i].cnt = '0;
        end
      end
    end
    // F PREG
    for (int i = 0; i < F_PREG_NUM; i++) begin
      n_f_preg_state[i] = f_preg_state[i];
      if (f_preg_state[i].counting) begin
        if (f_preg_state[i].cnt > 0) begin
          n_f_preg_state[i].cnt = f_preg_state[i].cnt - 1;
        end
      end else begin
        // !countingのときはcnt=0の前提
        for (int j = 0; j < F_WAKEUP_W; j++) begin
          if (f_wakeup[j].valid && f_wakeup[j].preg.idx == preg_idx_t'(i)) begin
            n_f_preg_state[i].counting |= 1'b1;
            n_f_preg_state[i].cnt |= f_wakeup[j].latency;
          end
        end
      end
      for (int j = 0; j < DISPATCH_W_INT; j++) begin
        if (disp_valid_int[j] && disp_uop_int[j].rd.typ == PREG_TYPE_F && disp_uop_int[j].rd.idx == preg_idx_t'(i)) begin
          n_f_preg_state[i].counting = 1'b0;
          n_f_preg_state[i].cnt = '0;
        end
      end
      for (int j = 0; j < DISPATCH_W_MEM; j++) begin
        if (disp_valid_mem[j] && disp_uop_mem[j].rd.typ == PREG_TYPE_F && disp_uop_mem[j].rd.idx == preg_idx_t'(i)) begin
          n_f_preg_state[i].counting = 1'b0;
          n_f_preg_state[i].cnt = '0;
        end
      end
      for (int j = 0; j < DISPATCH_W_FPU; j++) begin
        if (disp_valid_fpu[j] && disp_uop_fpu[j].rd.typ == PREG_TYPE_F && disp_uop_fpu[j].rd.idx == preg_idx_t'(i)) begin
          n_f_preg_state[i].counting = 1'b0;
          n_f_preg_state[i].cnt = '0;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    for (int i = 0; i < I_PREG_NUM; i++) begin
      if (rst || flush) begin
        i_preg_state[i].counting <= 1'b1;
        i_preg_state[i].cnt <= '0;
      end else begin
        i_preg_state[i] <= n_i_preg_state[i];
      end
    end
    for (int i = 0; i < F_PREG_NUM; i++) begin
      if (rst || flush) begin
        f_preg_state[i].counting <= 1'b1;
        f_preg_state[i].cnt <= '0;
      end else begin
        f_preg_state[i] <= n_f_preg_state[i];
      end
    end
  end

  function automatic src_state_t get_preg_state(input preg_t preg);
    if (preg.typ == PREG_TYPE_I) return i_preg_state[preg.idx];
    else if (preg.typ == PREG_TYPE_F) return f_preg_state[preg.idx];
    else return '{counting: 1'b1, cnt: '0};
  endfunction

  // 同じサイクルにdispatchされたrdとrsの依存を検知
  function automatic logic block_dispatched_rd(input preg_t p);
    logic found = 1'b0;
    for (int i = 0; i < DISPATCH_W_INT; i++) begin
      if (disp_valid_int[i] && disp_uop_int[i].rd == p) found = 1'b1;
    end
    for (int i = 0; i < DISPATCH_W_MEM; i++) begin
      if (disp_valid_mem[i] && disp_uop_mem[i].rd == p) found = 1'b1;
    end
    for (int i = 0; i < DISPATCH_W_FPU; i++) begin
      if (disp_valid_fpu[i] && disp_uop_fpu[i].rd == p) found = 1'b1;
    end
    return p.typ != PREG_TYPE_NONE && found;
  endfunction

  src_state_t disp_rs1_st_int[DISPATCH_W_INT];
  src_state_t disp_rs2_st_int[DISPATCH_W_INT];
  src_state_t disp_rs1_st_mem[DISPATCH_W_MEM];
  src_state_t disp_rs2_st_mem[DISPATCH_W_MEM];
  src_state_t disp_rs1_st_fpu[DISPATCH_W_FPU];
  src_state_t disp_rs2_st_fpu[DISPATCH_W_FPU];

  always_comb begin
    for (int i = 0; i < DISPATCH_W_INT; i++) begin
      disp_rs1_st_int[i] = get_preg_state(disp_uop_int[i].rs1);
      if (block_dispatched_rd(disp_uop_int[i].rs1)) disp_rs1_st_int[i] = '{counting: 1'b0, cnt: '0};
      disp_rs2_st_int[i] = get_preg_state(disp_uop_int[i].rs2);
      if (block_dispatched_rd(disp_uop_int[i].rs2)) disp_rs2_st_int[i] = '{counting: 1'b0, cnt: '0};
    end
    for (int i = 0; i < DISPATCH_W_MEM; i++) begin
      disp_rs1_st_mem[i] = get_preg_state(disp_uop_mem[i].rs1);
      if (block_dispatched_rd(disp_uop_mem[i].rs1)) disp_rs1_st_mem[i] = '{counting: 1'b0, cnt: '0};
      disp_rs2_st_mem[i] = get_preg_state(disp_uop_mem[i].rs2);
      if (block_dispatched_rd(disp_uop_mem[i].rs2)) disp_rs2_st_mem[i] = '{counting: 1'b0, cnt: '0};
    end
    for (int i = 0; i < DISPATCH_W_FPU; i++) begin
      disp_rs1_st_fpu[i] = get_preg_state(disp_uop_fpu[i].rs1);
      if (block_dispatched_rd(disp_uop_fpu[i].rs1)) disp_rs1_st_fpu[i] = '{counting: 1'b0, cnt: '0};
      disp_rs2_st_fpu[i] = get_preg_state(disp_uop_fpu[i].rs2);
      if (block_dispatched_rd(disp_uop_fpu[i].rs2)) disp_rs2_st_fpu[i] = '{counting: 1'b0, cnt: '0};
    end
  end

  iq_int #(
    .SIZE(SIZE_INT),
    .DISPATCH_W(DISPATCH_W_INT),
    .I_WAKEUP_W(I_WAKEUP_W),
    .F_WAKEUP_W(F_WAKEUP_W)
  ) u_iq_int (
    .clk  (clk),
    .rst  (rst),
    .flush(flush),

    // dispatch
    .disp_valid(disp_valid_int),
    .disp_uop(disp_uop_int),
    .disp_rs1_st(disp_rs1_st_int),
    .disp_rs2_st(disp_rs2_st_int),
    .disp_full(disp_full_int),

    // wakeup bus
    .coming_i_wakeup(i_wakeup),
    .coming_f_wakeup(f_wakeup),
    .sending_wakeup (int_wakeup),

    // ex_topのFFから
    .br_update_ff(br_update_ff),

    // to RR
    .rr_ff(rr_int_ff),
    .rr_payload_ff(rr_payload_int_ff)
  );

  iq_mem #(
    .SIZE(SIZE_MEM),
    .DISPATCH_W(DISPATCH_W_MEM),
    .I_WAKEUP_W(I_WAKEUP_W),
    .F_WAKEUP_W(F_WAKEUP_W)
  ) u_iq_mem (
    .clk  (clk),
    .rst  (rst),
    .flush(flush),

    // dispatch
    .disp_valid(disp_valid_mem),
    .disp_uop(disp_uop_mem),
    .disp_rs1_st(disp_rs1_st_mem),
    .disp_rs2_st(disp_rs2_st_mem),
    .disp_full(disp_full_mem),

    // wakeup bus
    .coming_i_wakeup(i_wakeup),
    .coming_f_wakeup(f_wakeup),
    .sending_wakeup (),

    // ex_topのFFから
    .br_update_ff(br_update_ff),

    // to RR
    .rr_ff(rr_mem_ff),
    .rr_payload_ff(rr_payload_mem_ff),
    .rr_issue_part_ff(rr_issue_part_mem_ff)
  );

  iq_float #(
    .SIZE(SIZE_FPU),
    .DISPATCH_W(DISPATCH_W_FPU),
    .I_WAKEUP_W(I_WAKEUP_W),
    .F_WAKEUP_W(F_WAKEUP_W)
  ) u_iq_float (
    .clk  (clk),
    .rst  (rst),
    .flush(flush),

    // dispatch
    .disp_valid(disp_valid_fpu),
    .disp_uop(disp_uop_fpu),
    .disp_rs1_st(disp_rs1_st_fpu),
    .disp_rs2_st(disp_rs2_st_fpu),
    .disp_full(disp_full_fpu),

    // wakeup bus
    .coming_i_wakeup(i_wakeup),
    .coming_f_wakeup(f_wakeup),
    .sending_wakeup (fpu_wakeup),

    // ex_topのFFから
    .br_update_ff(br_update_ff),

    // fdiv,fsqrtから
    .fdiv_blocked (fdiv_blocked),
    .fsqrt_blocked(fsqrt_blocked),

    // to RR
    .rr_ff(rr_fpu_ff),
    .rr_payload_ff(rr_payload_fpu_ff)
  );

endmodule

`default_nettype wire
