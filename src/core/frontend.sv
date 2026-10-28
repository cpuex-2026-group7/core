`timescale 1ns / 1ps
`default_nettype none

module frontend (
    input wire logic clk
);


  i_mem u_i_mem (
      .clk(clk),
      .en(TODO),
      .addr(TODO),
      .instr(TODO)
  );


endmodule

`default_nettype wire
