module if_id_reg (
  input logic clk,
  input logic rst_n,
  if_id_if.cons d,
  if_id_if.prod q
);

  always_ff @(posedge clk) begin
    if (~rst_n) begin
      q.data <= '0;
    end else begin
      q.data <= d.data;
    end
  end

endmodule

module id_ex_reg (
  input logic clk,
  input logic rst_n,
  id_ex_if.cons d,
  id_ex_if.prod q
);
  always_ff @(posedge clk) begin
    if (~rst_n) q.data <= '0;
    else q.data <= d.data;
  end
endmodule

module ex_mem_reg (
  input logic clk,
  input logic rst_n,
  ex_mem_if.cons d,
  ex_mem_if.prod q
);
  always_ff @(posedge clk) begin
    if (~rst_n) q.data <= '0;
    else q.data <= d.data;
  end
endmodule

module mem_wb_reg (
  input logic clk,
  input logic rst_n,
  mem_wb_if.cons d,
  mem_wb_if.prod q
);
  always_ff @(posedge clk) begin
    if (~rst_n) q.data <= '0;
    else q.data <= d.data;
  end
endmodule

module wb_if_reg (
  input logic clk,
  input logic rst_n,
  wb_if_if.cons d,
  wb_if_if.prod q
);
  always_ff @(posedge clk) begin
    if (~rst_n) q.data <= '0;
    else q.data <= d.data;
  end
endmodule
