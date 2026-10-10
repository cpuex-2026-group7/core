module if_id_reg (
    input logic clk,
    input logic rst_n,
    input if_id_t d,
    output if_id_t q
);
endmodule

module id_ex_reg (
    input logic clk,
    input logic rst_n,
    input id_ex_t d,
    output id_ex_t q
);
endmodule

module ex_mem_reg (
    input logic clk,
    input logic rst_n,
    input ex_mem_t d,
    output ex_mem_t q
);
endmodule

module mem_wb_reg (
    input logic clk,
    input logic rst_n,
    input mem_wb_t d,
    output mem_wb_t q
);
endmodule

module wb_if_reg (
    input logic clk,
    input logic rst_n,
    input wb_if_t d,
    output wb_if_t q
);
endmodule
