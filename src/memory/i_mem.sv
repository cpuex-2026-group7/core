`timescale 1ns / 1ps
`default_nettype none

module i_mem
  import types::*;
  import isa::*;
#(
    parameter int FETCH_W = 2
) (
    input wire logic clk,
    input wire logic en,
    input wire types::pc_t addr[FETCH_W],
    output instr_t instr[FETCH_W]
);

  types::pc_t addr_inner[FETCH_W];
  logic [9:0] r_addr[FETCH_W];
  word_t r_data[FETCH_W];

  always_comb begin
    for (int i = 0; i < FETCH_W; i++) r_addr[i] = addr_inner[i][9:0];
  end
  multi_port_ram #(
      .SIZE(1024),
      .ENTRY_WIDTH($bits(word_t)),
      .R(FETCH_W),
      .W(1),
      .INIT_FILE("fib.mem"),
      .INIT_FILE_PLUSARG("imem")
  ) u_ram (
      .clk(clk),
      .w_en('{1'b0}),
      .w_addr('{10'b0}),
      .w_data('{32'b0}),
      .r_addr(r_addr),
      .r_data(r_data)
  );

  always_ff @(posedge clk) begin
    for (int i = 0; i < FETCH_W; i++) begin
      if (en) begin
        addr_inner[i] <= addr[i];
        instr[i] <= instr_t'(r_data[i]);
      end
    end
  end

endmodule

`default_nettype wire
