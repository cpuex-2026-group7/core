`timescale 1ns / 1ps
`default_nettype none

module eu_3_top
  import types::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import rr_types::*;
  import ex_types::*;
(
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush

  // RRから
  input wire rr_ex_float_t rr_ex,

  // EXから
  input wire br_update_t br_update_ff,

  // RFへ
  output ex_wb_t to_wb,

  // RRへ
  output ex_wb_t bypass_f[2],
  output ex_wb_t bypass_i[1]
);

  // 入口のFFから結果が出るまでのFFの段数
  localparam int FMUL_STAGES = LAT_FMUL + 1;
  localparam int FCVT_STAGES = LAT_ITOF + 1;
  localparam int FADD_STAGES = LAT_FADD + 1;
  localparam int STAGES      = FADD_STAGES;

  typedef struct packed {
    logic     valid;
    dest_fu_t dest_fu;
    preg_t    rd;
    brmask_t  brmask;
    rob_idx_t rob_idx;
  } meta_t;

  // STAGES段分のmeta
  meta_t meta_ff[STAGES];
  // 短いFUの書き込みを揃える
  word_t fmul_delay_ff[STAGES-FMUL_STAGES];
  word_t fcvt_delay_ff[STAGES-FCVT_STAGES];

  word_t fu_0_result;
  word_t fu_1_result;
  word_t fu_2_result;

  eu_3_fu_0_top u_fu_0 (
    .clk(clk),
    .rs1_val(rr_ex.common.rs1_val),
    .rs2_val(rr_ex.common.rs2_val),
    .result(fu_0_result)
  );

  eu_3_fu_1_top u_fu_1 (
    .clk(clk),
    .rs1_val(rr_ex.common.rs1_val),
    .fu_op(rr_ex.payload.fu_op),
    .result(fu_1_result)
  );

  eu_3_fu_2_top u_fu_2 (
    .clk(clk),
    .rs1_val(rr_ex.common.rs1_val),
    .rs2_val(rr_ex.common.rs2_val),
    .fu_op(rr_ex.payload.fu_op),
    .result(fu_2_result)
  );

  // 今FFにあるbr_updateとflushを当てたmeta
  meta_t n_meta[STAGES];

  always_comb begin
    for (int i = 0; i < STAGES; i++) begin
      n_meta[i]        = meta_ff[i];
      n_meta[i].valid  = meta_ff[i].valid & !flush & !br_kill_check(meta_ff[i].brmask, br_update_ff);
      n_meta[i].brmask = apply_br_resolve(meta_ff[i].brmask, br_update_ff);
    end
  end

  always_comb begin
    case (n_meta[STAGES-1].dest_fu)
      FU_FMUL: to_wb.value = fmul_delay_ff[STAGES-FMUL_STAGES-1];
      FU_FCVT: to_wb.value = fcvt_delay_ff[STAGES-FCVT_STAGES-1];
      default: to_wb.value = fu_2_result;
    endcase
  end

  assign to_wb.valid = n_meta[STAGES-1].valid;
  assign to_wb.rd = n_meta[STAGES-1].rd;
  assign to_wb.rob_idx = n_meta[STAGES-1].rob_idx;

  localparam int BYPASS_STAGE_0 = LAT_FMUL;
  localparam int BYPASS_STAGE_1 = BYPASS_STAGE_0 + 1;

  // バイパス(killは当てない)
  assign bypass_f[0] = ex_wb_t'{
      valid: meta_ff[BYPASS_STAGE_0].valid & (meta_ff[BYPASS_STAGE_0].dest_fu == FU_FMUL),
      rd: meta_ff[BYPASS_STAGE_0].rd,
      value: fu_0_result,
      rob_idx: meta_ff[BYPASS_STAGE_0].rob_idx
    };

  logic bypass_stage_1_itof;
  assign bypass_stage_1_itof = (meta_ff[BYPASS_STAGE_1].dest_fu == FU_FCVT) & (meta_ff[BYPASS_STAGE_1].rd.typ == PREG_TYPE_F);
  assign bypass_f[1] = ex_wb_t'{
      valid: meta_ff[BYPASS_STAGE_1].valid & ((meta_ff[BYPASS_STAGE_1].dest_fu == FU_FMUL) | bypass_stage_1_itof),
      rd: meta_ff[BYPASS_STAGE_1].rd,
      value: (meta_ff[BYPASS_STAGE_1].dest_fu == FU_FMUL) ? fmul_delay_ff[BYPASS_STAGE_1] : fu_1_result,
      rob_idx: meta_ff[BYPASS_STAGE_1].rob_idx
    };

  logic bypass_stage_1_ftoi;
  assign bypass_stage_1_ftoi = (meta_ff[BYPASS_STAGE_1].dest_fu == FU_FCVT) & (meta_ff[BYPASS_STAGE_1].rd.typ == PREG_TYPE_I);
  assign bypass_i[0] = ex_wb_t'{
      valid: meta_ff[BYPASS_STAGE_1].valid & bypass_stage_1_ftoi,
      rd: meta_ff[BYPASS_STAGE_1].rd,
      value: fu_1_result,
      rob_idx: meta_ff[BYPASS_STAGE_1].rob_idx
    };

  // meta_ffとdelay_ffの更新
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < STAGES; i++) meta_ff[i].valid <= 1'b0;
    end else begin
      for (int i = 0; i < STAGES; i++) begin
        if (i == 0) begin
          meta_ff[0].valid   <= !flush & rr_ex.common.valid;
          meta_ff[0].dest_fu <= rr_ex.common.dest_fu;
          meta_ff[0].rd      <= rr_ex.common.rd;
          meta_ff[0].brmask  <= rr_ex.common.brmask;
          meta_ff[0].rob_idx <= rr_ex.payload.rob_idx;
        end else begin
          meta_ff[i] <= n_meta[i-1];
        end
      end
    end

    fmul_delay_ff[0] <= fu_0_result;
    for (int i = 1; i < STAGES - FMUL_STAGES; i++) fmul_delay_ff[i] <= fmul_delay_ff[i-1];
    fcvt_delay_ff[0] <= fu_1_result;
    for (int i = 1; i < STAGES - FCVT_STAGES; i++) fcvt_delay_ff[i] <= fcvt_delay_ff[i-1];
  end

endmodule

`default_nettype wire
