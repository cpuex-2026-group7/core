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

  btb u_btb (TODO);

  bpd u_bpd (TODO);

  br_decoder u_br_decoder (TODO);

  br_checker u_br_checker (TODO);


endmodule

`default_nettype wire
