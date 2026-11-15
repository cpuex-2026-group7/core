`timescale 1ns / 1ps
`default_nettype none

module one_hot_dec #(
    parameter int SIZE = 64
) (
    input wire logic [$clog2(SIZE)-1:0] num,
    output logic [SIZE-1:0] onehot
);

  always_comb begin
    onehot = '0;
    onehot[num] = 1'b1;
  end

endmodule

`default_nettype wire
