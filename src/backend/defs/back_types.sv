`timescale 1ns / 1ps
`default_nettype none

package back_types;
  typedef enum logic [1:0] {
    REG_TYPE_INT  = 2'b00,
    REG_TYPE_FP   = 2'b01,
    REG_TYPE_NONE = 2'b10
  } reg_type_t;
endpackage

`default_nettype wire
