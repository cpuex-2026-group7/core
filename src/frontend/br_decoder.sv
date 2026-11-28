`timescale 1ns / 1ps
`default_nettype none

module br_decoder #(
    parameter int FETCH_W = 2,
    parameter int RA = 1
) (
    input wire isa::instr_t instr[FETCH_W],
    input wire types::pc_t pcs[FETCH_W],
    output frontend_pkg::brdec_resp_t brdec_resp
);

  // 32 bit PCを想定したものを上位ビットを切って16 bitにしている。効率化の余地があるかもしれない。
  always_comb begin
    brdec_resp.branch_types = '0;
    brdec_resp.target_pcs = '0;
    brdec_resp.call = '0;
    brdec_resp.ret = '0;
    for (int i = 0; i < FETCH_W; i++) begin
      case ({
        instr[i].op.unit, instr[i].op.eff, instr[i].op.imm
      })
        isa::BRANCH_OP5: begin
          brdec_resp.branch_types[i] = frontend_pkg::BR_BRANCH;
          brdec_resp.target_pcs[i]   = pcs[i] + types::pc_t'({{17{instr[i].rd[4]}}, instr[i].rd, instr[i].rest});
        end
        isa::JAL_OP5: begin
          brdec_resp.branch_types[i] = frontend_pkg::BR_JAL;
          brdec_resp.target_pcs[i]   = pcs[i] + types::pc_t'({{12{instr[i].rs1[4]}}, instr[i].rs1, instr[i].rs2, instr[i].rest});
          brdec_resp.call[i] = (instr[i].rd == types::reg_addr_t'(RA));
        end
        isa::JALR_OP5: begin
          brdec_resp.branch_types[i] = (instr[i].op.id == 2'b00) ? frontend_pkg::BR_JALR : frontend_pkg::BR_NONE;
          brdec_resp.target_pcs[i] = pcs[i] + types::pc_t'(1);  // unknown or sequential
          brdec_resp.call[i] = (instr[i].rd == types::reg_addr_t'(RA));
          brdec_resp.ret[i]  = (instr[i].rd != types::reg_addr_t'(RA)) && (instr[i].rs1 == types::reg_addr_t'(RA));
        end
        default: begin
          brdec_resp.branch_types[i] = frontend_pkg::BR_NONE;
          brdec_resp.target_pcs[i]   = pcs[i] + types::pc_t'(1);  // sequential
        end
      endcase
    end
  end
endmodule

`default_nettype wire
