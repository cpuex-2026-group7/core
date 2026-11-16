`timescale 1ns / 1ps
`default_nettype none

module rf_top
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import iq_types::*;
  import rr_types::*;
  import ex_types::*;
  import rob_types::*;
#(
  parameter int I_PREG_NUM = 64,
  parameter int F_PREG_NUM = 64
) (
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush

  // from IQ
  input wire iq_rr_t rr_int_ff[1],
  input wire int_payload_t rr_payload_int_ff[1],

  input wire iq_rr_t rr_mem_ff[1],
  input wire mem_payload_t rr_payload_mem_ff[1],
  input wire logic [1:0] rr_issue_part_mem_ff[1],

  input wire iq_rr_t rr_fpu_ff[3],
  input wire float_payload_t rr_payload_fpu_ff[3],

  // to EX
  output rr_ex_int_t   rr_ex_int[1],
  output rr_ex_mem_t   rr_ex_mem[1],
  output rr_ex_float_t rr_ex_fpu[3],

  // WB input
  input wire ex_wb_t wb_alu[1],
  input wire ex_wb_t wb_mem[1],
  input wire ex_wb_t wb_fpu[3],

  // F長の書き込み段より前からのバイパス
  input wire bypass_t bypass_fpu_f[2],
  input wire bypass_t bypass_fpu_i[1],

  // to ROB
  output complete_t complete_idx[5],

  // ex_topのFFから
  input wire br_update_t br_update_ff
);

  localparam int ENTRY_WIDTH_INT = 32;
  localparam int R_INT = 5;
  localparam int W_INT = 3;

  localparam int ENTRY_WIDTH_FLOAT = 32;
  localparam int R_FLOAT = 7;
  localparam int W_FLOAT = 4;

  // 書き込みをI/Fに分ける
  ex_wb_t wb_i[  W_INT];
  ex_wb_t wb_f[W_FLOAT];

  function automatic ex_wb_t type_check(input ex_wb_t w, input preg_type_t typ);
    type_check = w;
    type_check.valid = w.valid && w.rd.typ == typ;
  endfunction

  always_comb begin
    wb_i[0] = type_check(wb_alu[0], PREG_TYPE_I);
    wb_i[1] = type_check(wb_mem[0], PREG_TYPE_I);
    wb_i[2] = type_check(wb_fpu[1], PREG_TYPE_I);

    wb_f[0] = type_check(wb_mem[0], PREG_TYPE_F);
    wb_f[1] = type_check(wb_fpu[0], PREG_TYPE_F);
    wb_f[2] = type_check(wb_fpu[1], PREG_TYPE_F);
    wb_f[3] = wb_fpu[2];
  end

  word_t r_data_int[R_INT];
  // INT
  multi_port_ram #(
    .SIZE(I_PREG_NUM),
    .ENTRY_WIDTH(ENTRY_WIDTH_INT),
    .R(R_INT),
    .W(W_INT)
  ) u_rf_int (
    .clk(clk),
    .w_en('{wb_i[0].valid, wb_i[1].valid, wb_i[2].valid}),
    .w_addr('{wb_i[0].rd.idx, wb_i[1].rd.idx, wb_i[2].rd.idx}),
    .w_data('{wb_i[0].value, wb_i[1].value, wb_i[2].value}),
    .r_addr(
    '{rr_int_ff[0].rs1.idx, rr_int_ff[0].rs2.idx, rr_mem_ff[0].rs1.idx, rr_mem_ff[0].rs2.idx, rr_fpu_ff[1].rs1.idx}
    ),
    .r_data(r_data_int)
  );

  word_t r_data_float[R_FLOAT];
  // FLOAT
  multi_port_ram #(
    .SIZE(F_PREG_NUM),
    .ENTRY_WIDTH(ENTRY_WIDTH_FLOAT),
    .R(R_FLOAT),
    .W(W_FLOAT)
  ) u_rf_float (
    .clk(clk),
    .w_en('{wb_f[0].valid, wb_f[1].valid, wb_f[2].valid, wb_f[3].valid}),
    .w_addr('{wb_f[0].rd.idx, wb_f[1].rd.idx, wb_f[2].rd.idx, wb_f[3].rd.idx}),
    .w_data('{wb_f[0].value, wb_f[1].value, wb_f[2].value, wb_f[3].value}),
    .r_addr(
    '{
      rr_mem_ff[0].rs2.idx,
      rr_fpu_ff[0].rs1.idx,
      rr_fpu_ff[0].rs2.idx,
      rr_fpu_ff[1].rs1.idx,
      rr_fpu_ff[1].rs2.idx,
      rr_fpu_ff[2].rs1.idx,
      rr_fpu_ff[2].rs2.idx
    }
    ),
    .r_data(r_data_float)
  );

  // WBとEXからのバイパス
  function automatic word_t apply_bypass_i(preg_idx_t idx, word_t val);
    // 書き込みから
    for (int i = 0; i < W_INT; i++) begin
      if (wb_i[i].valid && wb_i[i].rd.idx == idx) begin
        return wb_i[i].value;
      end
    end
    // EXから
    if (bypass_fpu_i[0].valid && bypass_fpu_i[0].rd.idx == idx) begin
      return bypass_fpu_i[0].value;
    end
    return val;
  endfunction

  function automatic word_t apply_bypass_f(preg_idx_t idx, word_t val);
    // 書き込みから
    for (int i = 0; i < W_FLOAT; i++) begin
      if (wb_f[i].valid && wb_f[i].rd.idx == idx) begin
        return wb_f[i].value;
      end
    end
    // EXから
    for (int i = 0; i < 2; i++) begin
      if (bypass_fpu_f[i].valid && bypass_fpu_f[i].rd.idx == idx) begin
        return bypass_fpu_f[i].value;
      end
    end
    return val;
  endfunction

  function automatic word_t get_val_i(preg_t preg, word_t val);
    return preg.typ == PREG_TYPE_NONE ? '0 : apply_bypass_i(preg.idx, val);
  endfunction

  function automatic word_t get_val_f(preg_t preg, word_t val);
    return preg.typ == PREG_TYPE_NONE ? '0 : apply_bypass_f(preg.idx, val);
  endfunction

  function automatic word_t get_val_i_or_f(preg_t preg, word_t i_val, word_t f_val);
    case (preg.typ)
      PREG_TYPE_I: return apply_bypass_i(preg.idx, i_val);
      PREG_TYPE_F: return apply_bypass_f(preg.idx, f_val);
      default: return '0;  // PREG_TYPE_NONE
    endcase
  endfunction

  always_comb begin
    // INT
    rr_ex_int[0].common.valid = !rst & !flush & rr_int_ff[0].valid & !br_kill_check(rr_int_ff[0].brmask, br_update_ff);
    rr_ex_int[0].common.rd = rr_int_ff[0].rd;
    rr_ex_int[0].common.rs1 = rr_int_ff[0].rs1;
    rr_ex_int[0].common.rs2 = rr_int_ff[0].rs2;
    rr_ex_int[0].common.rs1_val = get_val_i(rr_int_ff[0].rs1, r_data_int[0]);
    rr_ex_int[0].common.rs2_val = get_val_i(rr_int_ff[0].rs2, r_data_int[1]);
    rr_ex_int[0].common.dest_fu = rr_int_ff[0].dest_fu;
    rr_ex_int[0].common.brmask = apply_br_resolve(rr_int_ff[0].brmask, br_update_ff);
    rr_ex_int[0].payload = rr_payload_int_ff[0];

    // MEM
    rr_ex_mem[0].common.valid = !rst & !flush & rr_mem_ff[0].valid & !br_kill_check(rr_mem_ff[0].brmask, br_update_ff);
    rr_ex_mem[0].common.rd = rr_mem_ff[0].rd;
    rr_ex_mem[0].common.rs1 = rr_mem_ff[0].rs1;
    rr_ex_mem[0].common.rs2 = rr_mem_ff[0].rs2;
    rr_ex_mem[0].common.rs1_val = get_val_i(rr_mem_ff[0].rs1, r_data_int[2]);
    rr_ex_mem[0].common.rs2_val = get_val_i_or_f(rr_mem_ff[0].rs2, r_data_int[3], r_data_float[0]);
    rr_ex_mem[0].common.dest_fu = rr_mem_ff[0].dest_fu;
    rr_ex_mem[0].common.brmask = apply_br_resolve(rr_mem_ff[0].brmask, br_update_ff);
    rr_ex_mem[0].payload = rr_payload_mem_ff[0];
    rr_ex_mem[0].issue_part = rr_issue_part_mem_ff[0];

    // FPU短
    rr_ex_fpu[0].common.valid = !rst & !flush & rr_fpu_ff[0].valid & !br_kill_check(rr_fpu_ff[0].brmask, br_update_ff);
    rr_ex_fpu[0].common.rd = rr_fpu_ff[0].rd;
    rr_ex_fpu[0].common.rs1 = rr_fpu_ff[0].rs1;
    rr_ex_fpu[0].common.rs2 = rr_fpu_ff[0].rs2;
    rr_ex_fpu[0].common.rs1_val = get_val_f(rr_fpu_ff[0].rs1, r_data_float[1]);
    rr_ex_fpu[0].common.rs2_val = get_val_f(rr_fpu_ff[0].rs2, r_data_float[2]);
    rr_ex_fpu[0].common.dest_fu = rr_fpu_ff[0].dest_fu;
    rr_ex_fpu[0].common.brmask = apply_br_resolve(rr_fpu_ff[0].brmask, br_update_ff);
    rr_ex_fpu[0].payload = rr_payload_fpu_ff[0];

    // FPU長
    rr_ex_fpu[1].common.valid = !rst & !flush & rr_fpu_ff[1].valid & !br_kill_check(rr_fpu_ff[1].brmask, br_update_ff);
    rr_ex_fpu[1].common.rd = rr_fpu_ff[1].rd;
    rr_ex_fpu[1].common.rs1 = rr_fpu_ff[1].rs1;
    rr_ex_fpu[1].common.rs2 = rr_fpu_ff[1].rs2;
    rr_ex_fpu[1].common.rs1_val = get_val_i_or_f(rr_fpu_ff[1].rs1, r_data_int[4], r_data_float[3]);
    rr_ex_fpu[1].common.rs2_val = get_val_f(rr_fpu_ff[1].rs2, r_data_float[4]);
    rr_ex_fpu[1].common.dest_fu = rr_fpu_ff[1].dest_fu;
    rr_ex_fpu[1].common.brmask = apply_br_resolve(rr_fpu_ff[1].brmask, br_update_ff);
    rr_ex_fpu[1].payload = rr_payload_fpu_ff[1];

    // FPU超長
    rr_ex_fpu[2].common.valid = !rst & !flush & rr_fpu_ff[2].valid & !br_kill_check(rr_fpu_ff[2].brmask, br_update_ff);
    rr_ex_fpu[2].common.rd = rr_fpu_ff[2].rd;
    rr_ex_fpu[2].common.rs1 = rr_fpu_ff[2].rs1;
    rr_ex_fpu[2].common.rs2 = rr_fpu_ff[2].rs2;
    rr_ex_fpu[2].common.rs1_val = get_val_f(rr_fpu_ff[2].rs1, r_data_float[5]);
    rr_ex_fpu[2].common.rs2_val = get_val_f(rr_fpu_ff[2].rs2, r_data_float[6]);
    rr_ex_fpu[2].common.dest_fu = rr_fpu_ff[2].dest_fu;
    rr_ex_fpu[2].common.brmask = apply_br_resolve(rr_fpu_ff[2].brmask, br_update_ff);
    rr_ex_fpu[2].payload = rr_payload_fpu_ff[2];
  end

  always_comb begin
    // EXで分岐ミスkillできていれば復帰より前に書き込まれてok
    complete_idx[0].valid   = wb_alu[0].valid;
    complete_idx[0].rob_idx = wb_alu[0].rob_idx;
    complete_idx[1].valid   = wb_mem[0].valid;  // loadはここ
    complete_idx[1].rob_idx = wb_mem[0].rob_idx;
    complete_idx[2].valid   = wb_fpu[0].valid;
    complete_idx[2].rob_idx = wb_fpu[0].rob_idx;
    complete_idx[3].valid   = wb_fpu[1].valid;
    complete_idx[3].rob_idx = wb_fpu[1].rob_idx;
    complete_idx[4].valid   = wb_fpu[2].valid;
    complete_idx[4].rob_idx = wb_fpu[2].rob_idx;
  end

endmodule

`default_nettype wire
