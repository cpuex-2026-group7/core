`timescale 1ns / 1ps
`default_nettype none

module bpd #(
    parameter int FETCH_W = 2
) (
    output frontend_pkg::bpd_resp_t resp[FETCH_W]
);

  always_comb begin
    for (int i = 0; i < FETCH_W; i++) begin
      resp[i] = 1'b1;
    end
  end

endmodule

`default_nettype wire
