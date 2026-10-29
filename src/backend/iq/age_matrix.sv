`timescale 1ns / 1ps
`default_nettype none

module age_matrix #(
  parameter int SIZE = 16,
  parameter int DISPATCH_W = 1
) (
  input wire logic clk,
  input wire logic lane_valid[DISPATCH_W],  // laneは小さい方が古い
  input wire logic [((SIZE>1)? $clog2(SIZE) : 1)-1:0] alloc_slot[DISPATCH_W],
  output logic [SIZE-1:0] older[SIZE]  // i older than j
);

  // 下三角
  logic lower  [SIZE][SIZE];
  logic n_lower[SIZE][SIZE];

  always_comb begin
    n_lower = lower;
    for (int d = 0; d < DISPATCH_W; d++) begin
      if (lane_valid[d]) begin
        for (int j = 0; j < SIZE; j++) begin
          if (j > int'(alloc_slot[d])) n_lower[j][alloc_slot[d]] = 1'b1;
          if (j < int'(alloc_slot[d])) n_lower[alloc_slot[d]][j] = 1'b0;
        end
      end
    end
  end

  always_ff @(posedge clk) lower <= n_lower;

  always_comb begin
    for (int i = 0; i < SIZE; i++) begin
      for (int j = 0; j < SIZE; j++) begin
        if (i > j) older[i][j] = lower[i][j];
        else if (i < j) older[i][j] = ~lower[j][i];
        else older[i][j] = 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
