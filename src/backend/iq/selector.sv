`timescale 1ns / 1ps
`default_nettype none

module selector #(
  parameter int SIZE = 16
) (
  input wire logic [SIZE-1:0] req,
  input wire logic [SIZE-1:0] older[SIZE],  // i older than j
  output logic [SIZE-1:0] grant  // one hot(なければ0)
);

  always_comb begin
    for (int i = 0; i < SIZE; i++) begin
      logic not_this_one;
      not_this_one = 1'b0;
      for (int j = 0; j < SIZE; j++) begin
        not_this_one |= req[j] & older[j][i];
      end
      grant[i] = req[i] & ~not_this_one;
    end
  end

endmodule

`default_nettype wire
