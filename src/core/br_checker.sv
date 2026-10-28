`timescale 1ns / 1ps
`default_nettype none

module br_checker (
    input wire frontend::btb_resp_t btb_resp,
    input wire frontend::bpd_resp_t bpd_resp,
    input wire frontend::branch_type_t brdec_btype,
    input wire types::addr_t brdec_target_pc,
    input wire types::addr_t pc,
    output btb_update_req_t btb_update_req
);



endmodule

`default_nettype wire
