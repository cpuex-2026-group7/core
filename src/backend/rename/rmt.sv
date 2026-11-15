`timescale 1ns / 1ps
`default_nettype none


// Rename Map Table
// RMT stores the map from logical register number
// to physical register number

// 0 clock read(LUTRAM)
// multi-port read (3 * W ports required)
// multi-port write ()

// TODO snapshot support

module rmt #(
    parameter int LREG_COUNT = 64,
    parameter int DISPATCH_W = 2
) (
    input wire logic clk,

    input wire types::rf_idx_t rd_reqr [DISPATCH_W],
    input wire types::rf_idx_t rs1_reqr[DISPATCH_W],
    input wire types::rf_idx_t rs2_reqr[DISPATCH_W],

    output types::preg_t rd_respr [DISPATCH_W],
    output types::preg_t rs1_respr[DISPATCH_W],
    output types::preg_t rs2_respr[DISPATCH_W],

    input wire types::rf_idx_t key_reqw  [DISPATCH_W],
    input wire types::preg_t   value_reqw[DISPATCH_W],
    input wire logic           valid_reqw[DISPATCH_W]
);

  types::rf_idx_t req_read [3 * DISPATCH_W];
  types::preg_t   resp_read[3 * DISPATCH_W];
  always_comb begin : assign_req_read
    for (int i = 0; i < DISPATCH_W; i++) begin
      req_read[3*i]   = rd_reqr[i];
      req_read[3*i+1] = rs1_reqr[i];
      req_read[3*i+2] = rs2_reqr[i];
    end
  end

  always_comb begin : assign_resp_read
    for (int i = 0; i < DISPATCH_W; i++) begin
      rd_respr[i]  = resp_read[3*i];
      rs1_respr[i] = resp_read[3*i+1];
      rs2_respr[i] = resp_read[3*i+2];
    end
  end

  // Should be LUTRAM. async read, sync write.n
  multi_port_ram #(
      .SIZE(LREG_COUNT),
      .ENTRY_WIDTH($bits(preg_t)),
      .R(3 * DISPATCH_W),
      .W(DISPATCH_W)
  ) u_rmt (
      .clk(clk),
      .w_en(valid_reqw),
      .w_addr(key_reqw),
      .w_data(value_reqw),
      .r_addr(req_read),
      .r_data(resp_read)
  );

endmodule

`default_nettype wire
