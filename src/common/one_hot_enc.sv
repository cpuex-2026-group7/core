`timescale 1ns / 1ps
`default_nettype none

module one_hot_enc #(
    parameter int SIZE = 64
) (
    input wire logic [SIZE-1:0] onehot,
    output logic [$clog2(SIZE)-1:0] num
);

  always_comb begin
    num = '0;
    for (int i = 0; i < SIZE; i++) begin
      num |= {$clog2(SIZE) {onehot[i]}} & $clog2(SIZE)'(i);
    end
  end

endmodule

`default_nettype wire
