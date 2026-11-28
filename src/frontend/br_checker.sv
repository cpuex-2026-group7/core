`timescale 1ns / 1ps
`default_nettype none

// bidxが違くても奇跡的にtargetが同じ場合、もしかしたらpassさせてもいいかもしれない
// ひとまずfailさせておく。
module br_checker #(
    parameter int FETCH_W = 2
) (
    // input wire frontend_pkg::nlp_resp_t nlp_resp,
    // input wire frontend_pkg::bpd_resp_t bpd_resp,
    // input wire frontend_pkg::brdec_resp_t brdec_resp,

    // output logic [FETCH_W-1:0] instr_valid,  // apply bidx
    // output types::pc_t redirect_F_target,
    // output frontend_pkg::branch_type_t br_type_F3_actual  // bidxのbrtype

    input wire frontend_pkg::btb_resp_t btb_resp,
    input wire frontend_pkg::bpd_resp_t bpd_resp,
    input wire types::pc_t ras_target,
    input wire frontend_pkg::brdec_resp_t brdec_resp,
    input wire types::pc_t pc_seq,  // pc_head + FETCH_W

    output logic [FETCH_W-1:0] instr_valid,
    output types::pc_t target_pc,  // next fetch pc unless backend redirect
    output types::pc_t predict_pcs[FETCH_W],
    output frontend_pkg::branch_type_t br_type,  // bidxのbrtype
    output logic [FETCH_W-1:0] alive_branch_mask,
    output logic [$clog2(FETCH_W+1)-1:0] alive_branch_count,  // alive_branch_maskの1の数
    output logic [FETCH_W-1:0] takens, // alive_branch_maskのうちi番目のbranchがtakenかどうか
    output logic is_call,
    output logic is_ret
);

  logic [FETCH_W-1:0] do_branch;
  logic [FETCH_W-1:0] is_branch;
  logic [$clog2(FETCH_W)-1:0] bidx;

  assign instr_valid = '1 >> (FETCH_W - bidx - 1);

  always_comb begin : calc_do_branch
    for (int i = 0; i < FETCH_W; i++) begin
      unique case (brdec_resp.branch_types[i])
        frontend_pkg::BR_NONE: begin
          is_branch[i] = 1'b0;
          do_branch[i] = 1'b0;
        end
        frontend_pkg::BR_BRANCH: begin
          is_branch[i] = 1'b1;
          do_branch[i] = bpd_resp[i];
        end
        default: begin
          is_branch[i] = 1'b1;
          do_branch[i] = 1'b1;
        end
      endcase
    end
  end

  always_comb begin : calc_predict_pcs
    for (int i = 0; i < FETCH_W; i++) begin
      unique case (brdec_resp.branch_types[i])
        frontend_pkg::BR_NONE: predict_pcs[i] = pc_seq;
        frontend_pkg::BR_BRANCH: predict_pcs[i] = do_branch[i] ? brdec_resp.target_pcs[i] : pc_seq;
        frontend_pkg::BR_JAL: predict_pcs[i] = brdec_resp.target_pcs[i];
        frontend_pkg::BR_JALR:
        predict_pcs[i] = brdec_resp.ret[i] ? ras_target : btb_resp.content.target;
      endcase
    end
  end

  always_comb begin : calc_bidx
    bidx = $clog2(FETCH_W)'(FETCH_W - 1);
    for (int i = FETCH_W - 1; i >= 0; i--) begin
      if (do_branch[i]) bidx = $clog2(FETCH_W)'(i);
    end
  end

  always_comb begin : calc_target_pc
    unique case (brdec_resp.branch_types[bidx])
      frontend_pkg::BR_NONE: target_pc = pc_seq;
      frontend_pkg::BR_BRANCH: target_pc = brdec_resp.target_pcs[bidx];
      frontend_pkg::BR_JAL: target_pc = brdec_resp.target_pcs[bidx];
      frontend_pkg::BR_JALR:
      target_pc = brdec_resp.ret[bidx] ? ras_target : brdec_resp.target_pcs[bidx];
    endcase
  end

  always_comb begin : calc_alive_branch_count
    alive_branch_count = '0;
    for (int i = 0; i < FETCH_W; i++) begin
      if (alive_branch_mask[i]) alive_branch_count++;
    end
  end

  always_comb begin : calc_takens
    for (int i = 0; i < FETCH_W; i++) begin
      takens[i] = alive_branch_mask[i] ? do_branch[i] : 1'b0;
    end
  end

  assign br_type = brdec_resp.branch_types[bidx];
  assign alive_branch_mask = instr_valid & is_branch;
  assign is_call = brdec_resp.call[bidx];
  assign is_ret = brdec_resp.ret[bidx];

endmodule

`default_nettype wire
