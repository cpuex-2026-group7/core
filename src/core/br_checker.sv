`timescale 1ns / 1ps
`default_nettype none

module br_checker (
    input wire frontend::btb_resp_t btb_resp,
    input wire frontend::bpd_resp_t bpd_resp,
    input wire frontend::branch_type_t brdec_btype,
    input wire types::addr_t brdec_target_pc,
    input wire types::addr_t pc,
    output logic redirect_F
);

always_comb begin
    unique case (brdec_btype)
    BR_NONE:
        redirect_F = btb_resp.valid
    BR_JALR:
        redirect_F = 1'b0
    default:
        redirect_F = (btb_resp.valid ^ bpd_resp.taken) | (btb_resp.valid & brdec_target_pc != btb_resp.target)
    endcase
end

endmodule

`default_nettype wire
