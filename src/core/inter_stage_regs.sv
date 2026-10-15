`timescale 1ns / 1ps
`default_nettype none

module if_id_reg (
  input wire logic clk,
  input wire logic en,
  input wire logic rst_n,
  input wire logic stall_D,
  input wire logic flush_D,
  if_id_if.cons d,
  if_id_if.prod q
);
  always_ff @(posedge clk) begin
    if (~rst_n) begin
      q.data <= '0;
    end else if (en) begin
      if (flush_D) q.data <= '0;
      else if (~stall_D) q.data <= d.data;
    end
  end

endmodule

module id_ex_reg (
  input wire logic clk,
  input wire logic en,
  input wire logic rst_n,
  input wire logic flush_E,
  id_ex_if.cons d,
  id_ex_if.prod q
);
  always_ff @(posedge clk) begin
    if (~rst_n) q.data <= '0;
    else if (en) begin
      if (flush_E) q.data <= '0;
      else q.data <= d.data;
    end
  end
endmodule

module ex_mem_reg (
  input wire logic clk,
  input wire logic en,
  input wire logic rst_n,
  ex_mem_if.cons d,
  ex_mem_if.prod q
);
  always_ff @(posedge clk) begin
    if (~rst_n) q.data <= '0;
    else if (en) q.data <= d.data;
  end
endmodule

module mem_wb_reg (
  input wire logic clk,
  input wire logic en,
  input wire logic rst_n,
  mem_wb_if.cons d,
  mem_wb_if.prod q
);
  always_ff @(posedge clk) begin
    if (~rst_n) q.data <= '0;
    else if (en) q.data <= d.data;
  end
endmodule

module wb_if_reg (
  input wire logic clk,
  input wire logic en,
  input wire logic rst_n,
  input wire logic stall_F,
  wb_if_if.cons d,
  wb_if_if.prod q
);
  always_ff @(posedge clk) begin
    if (~rst_n) q.data <= '0;
    else if (en) begin
      if (~stall_F) q.data <= d.data;
    end
  end
endmodule

`default_nettype wire
