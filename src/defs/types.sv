`timescale 1ns / 1ps
`default_nettype none

package types;
  typedef logic [31:0] word_t;
  typedef logic [31:0] addr_t;
  typedef logic [4:0] reg_addr_t;
  typedef logic [5:0] rf_idx_t;
  typedef logic [15:0] pc_t;
endpackage

`default_nettype wire
