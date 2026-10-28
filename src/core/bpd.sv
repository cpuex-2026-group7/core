`timescale 1ns / 1ps
`default_nettype none

module bpd (
    output frontend::bpd_resp_t resp
);

  assign resp.taken = 1'b1;

endmodule

`default_nettype wire
