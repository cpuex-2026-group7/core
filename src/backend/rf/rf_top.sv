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
  parameter int I_PREG_NUM  = 64,
  parameter int F_PREG_NUM  = 64,
  parameter int BR_UPDATE_W = 1
) (
  input wire logic clk,
  input wire logic rst,
  input wire logic flush, // loadの順序違反でflush

  // from IQ
  input wire iq_rr_t rr_ff_int[1],
  input wire int_payload_t rr_payload_int[1],

  input wire iq_rr_t rr_ff_mem[1],
  input wire mem_payload_t rr_payload_mem[1],
  input wire logic [1:0] rr_issue_part_mem[1],

  input wire iq_rr_t rr_ff_fpu[3],
  input wire float_payload_t rr_payload_fpu[3],

  // to EX
  output rr_ex_int_t   ex_ff_int[1],
  output rr_ex_mem_t   ex_ff_mem[1],
  output rr_ex_float_t ex_ff_fpu[3],

  // WB input
  input wire ex_wb_t wb_alu[1],
  input wire ex_wb_t wb_mem[1],
  input wire ex_wb_t wb_fpu[3],

  // to ROB
  output complete_t complete_idx[5],

  // ALUレーンのWBから
  input wire br_update_t br_update[BR_UPDATE_W]
);

  localparam int ENTRY_WIDTH_INT = 32;
  localparam int R_INT = 5;
  localparam int W_INT = 3;

  word_t r_data_int[R_INT];
  // INT
  multi_port_ram #(
    .SIZE(I_PREG_NUM),
    .ENTRY_WIDTH(ENTRY_WIDTH_INT),
    .R(R_INT),
    .W(W_INT)
  ) u_rf_int (
    .clk(clk),
    .w_en(
    '{
      wb_alu[0].valid & wb_alu[0].rd.typ == PREG_TYPE_I,
      wb_mem[0].valid & wb_mem[0].rd.typ == PREG_TYPE_I,
      wb_fpu[1].valid & wb_fpu[1].rd.typ == PREG_TYPE_I
    }
    ),
    .w_addr('{wb_alu[0].rd.idx, wb_mem[0].rd.idx, wb_fpu[1].rd.idx}),
    .w_data('{wb_alu[0].value, wb_mem[0].value, wb_fpu[1].value}),
    .r_addr(
    '{rr_ff_int[0].rs1.idx, rr_ff_int[0].rs2.idx, rr_ff_mem[0].rs1.idx, rr_ff_mem[0].rs2.idx, rr_ff_fpu[1].rs1.idx}
    ),
    .r_data(r_data_int)
  );

  localparam int ENTRY_WIDTH_FLOAT = 32;
  localparam int R_FLOAT = 7;
  localparam int W_FLOAT = 4;

  word_t r_data_float[R_FLOAT];
  // FLOAT
  multi_port_ram #(
    .SIZE(F_PREG_NUM),
    .ENTRY_WIDTH(ENTRY_WIDTH_FLOAT),
    .R(R_FLOAT),
    .W(W_FLOAT)
  ) u_rf_float (
    .clk(clk),
    .w_en(
    '{
      wb_mem[0].valid & wb_mem[0].rd.typ == PREG_TYPE_F,
      wb_fpu[0].valid & wb_fpu[0].rd.typ == PREG_TYPE_F,
      wb_fpu[1].valid & wb_fpu[1].rd.typ == PREG_TYPE_F,
      wb_fpu[2].valid & wb_fpu[2].rd.typ == PREG_TYPE_F
    }
    ),
    .w_addr('{wb_mem[0].rd.idx, wb_fpu[0].rd.idx, wb_fpu[1].rd.idx, wb_fpu[2].rd.idx}),
    .w_data('{wb_mem[0].value, wb_fpu[0].value, wb_fpu[1].value, wb_fpu[2].value}),
    .r_addr(
    '{
      rr_ff_mem[0].rs2.idx,
      rr_ff_fpu[0].rs1.idx,
      rr_ff_fpu[0].rs2.idx,
      rr_ff_fpu[1].rs1.idx,
      rr_ff_fpu[1].rs2.idx,
      rr_ff_fpu[2].rs1.idx,
      rr_ff_fpu[2].rs2.idx
    }
    ),
    .r_data(r_data_float)
  );

  function automatic logic branch_kill_check(input brmask_t brmask, input br_update_t br_upd[BR_UPDATE_W]);
    branch_kill_check = 1'b0;
    for (int i = 0; i < BR_UPDATE_W; i++) branch_kill_check |= br_killed(brmask, br_upd[i]);
  endfunction

  function automatic brmask_t apply_br_update(input brmask_t brmask, input br_update_t br_upd[BR_UPDATE_W]);
    apply_br_update = brmask;
    for (int i = 0; i < BR_UPDATE_W; i++) apply_br_update = br_resolved(apply_br_update, br_upd[i]);
  endfunction

  // WBで書いている値からバイパス
  ex_wb_t wb_all[5];
  assign wb_all = '{wb_alu[0], wb_mem[0], wb_fpu[0], wb_fpu[1], wb_fpu[2]};

  function automatic word_t apply_type_none_and_bypass(preg_t preg, word_t val);
    if (preg.typ == PREG_TYPE_NONE) begin
      return '0;
    end else begin
      for (int i = 0; i < 5; i++) begin
        if (wb_all[i].valid && wb_all[i].rd == preg) begin
          return wb_all[i].value;
        end
      end
      return val;
    end
  endfunction

  always_comb begin
    // INT
    ex_ff_int[0].common.valid = !rst & !flush & rr_ff_int[0].valid & !branch_kill_check(
      rr_ff_int[0].brmask, br_update
    );
    ex_ff_int[0].common.rd = rr_ff_int[0].rd;
    ex_ff_int[0].common.rs1 = rr_ff_int[0].rs1;
    ex_ff_int[0].common.rs2 = rr_ff_int[0].rs2;
    ex_ff_int[0].common.rs1_val = apply_type_none_and_bypass(rr_ff_int[0].rs1, r_data_int[0]);
    ex_ff_int[0].common.rs2_val = apply_type_none_and_bypass(rr_ff_int[0].rs2, r_data_int[1]);
    ex_ff_int[0].common.dest_fu = rr_ff_int[0].dest_fu;
    ex_ff_int[0].common.brmask = apply_br_update(rr_ff_int[0].brmask, br_update);
    ex_ff_int[0].payload = rr_payload_int[0];

    // MEM
    ex_ff_mem[0].common.valid = !rst & !flush & rr_ff_mem[0].valid & !branch_kill_check(
      rr_ff_mem[0].brmask, br_update
    );
    ex_ff_mem[0].common.rd = rr_ff_mem[0].rd;
    ex_ff_mem[0].common.rs1 = rr_ff_mem[0].rs1;
    ex_ff_mem[0].common.rs2 = rr_ff_mem[0].rs2;
    ex_ff_mem[0].common.rs1_val = apply_type_none_and_bypass(rr_ff_mem[0].rs1, r_data_int[2]);
    ex_ff_mem[0].common.rs2_val = apply_type_none_and_bypass(
      rr_ff_mem[0].rs2, rr_ff_mem[0].rs2.typ == PREG_TYPE_F ? r_data_float[0] : r_data_int[3]
    );
    ex_ff_mem[0].common.dest_fu = rr_ff_mem[0].dest_fu;
    ex_ff_mem[0].common.brmask = apply_br_update(rr_ff_mem[0].brmask, br_update);
    ex_ff_mem[0].payload = rr_payload_mem[0];
    ex_ff_mem[0].issue_part = rr_issue_part_mem[0];

    // FPU短
    ex_ff_fpu[0].common.valid = !rst & !flush & rr_ff_fpu[0].valid & !branch_kill_check(
      rr_ff_fpu[0].brmask, br_update
    );
    ex_ff_fpu[0].common.rd = rr_ff_fpu[0].rd;
    ex_ff_fpu[0].common.rs1 = rr_ff_fpu[0].rs1;
    ex_ff_fpu[0].common.rs2 = rr_ff_fpu[0].rs2;
    ex_ff_fpu[0].common.rs1_val = apply_type_none_and_bypass(rr_ff_fpu[0].rs1, r_data_float[1]);
    ex_ff_fpu[0].common.rs2_val = apply_type_none_and_bypass(rr_ff_fpu[0].rs2, r_data_float[2]);
    ex_ff_fpu[0].common.dest_fu = rr_ff_fpu[0].dest_fu;
    ex_ff_fpu[0].common.brmask = apply_br_update(rr_ff_fpu[0].brmask, br_update);
    ex_ff_fpu[0].payload = rr_payload_fpu[0];

    // FPU長
    ex_ff_fpu[1].common.valid = !rst & !flush & rr_ff_fpu[1].valid & !branch_kill_check(
      rr_ff_fpu[1].brmask, br_update
    );
    ex_ff_fpu[1].common.rd = rr_ff_fpu[1].rd;
    ex_ff_fpu[1].common.rs1 = rr_ff_fpu[1].rs1;
    ex_ff_fpu[1].common.rs2 = rr_ff_fpu[1].rs2;
    ex_ff_fpu[1].common.rs1_val = apply_type_none_and_bypass(
      rr_ff_fpu[1].rs1, rr_ff_fpu[1].rs1.typ == PREG_TYPE_F ? r_data_float[3] : r_data_int[4]
    );
    ex_ff_fpu[1].common.rs2_val = apply_type_none_and_bypass(rr_ff_fpu[1].rs2, r_data_float[4]);
    ex_ff_fpu[1].common.dest_fu = rr_ff_fpu[1].dest_fu;
    ex_ff_fpu[1].common.brmask = apply_br_update(rr_ff_fpu[1].brmask, br_update);
    ex_ff_fpu[1].payload = rr_payload_fpu[1];

    // FPU超長
    ex_ff_fpu[2].common.valid = !rst & !flush & rr_ff_fpu[2].valid & !branch_kill_check(
      rr_ff_fpu[2].brmask, br_update
    );
    ex_ff_fpu[2].common.rd = rr_ff_fpu[2].rd;
    ex_ff_fpu[2].common.rs1 = rr_ff_fpu[2].rs1;
    ex_ff_fpu[2].common.rs2 = rr_ff_fpu[2].rs2;
    ex_ff_fpu[2].common.rs1_val = apply_type_none_and_bypass(rr_ff_fpu[2].rs1, r_data_float[5]);
    ex_ff_fpu[2].common.rs2_val = apply_type_none_and_bypass(rr_ff_fpu[2].rs2, r_data_float[6]);
    ex_ff_fpu[2].common.dest_fu = rr_ff_fpu[2].dest_fu;
    ex_ff_fpu[2].common.brmask = apply_br_update(rr_ff_fpu[2].brmask, br_update);
    ex_ff_fpu[2].payload = rr_payload_fpu[2];
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
