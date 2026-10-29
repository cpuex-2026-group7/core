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
    grant = req;
    for (int i = 0; i < SIZE; i++) begin
      if (req[i]) grant &= ~older[i];
    end
  end

endmodule

`default_nettype wire
