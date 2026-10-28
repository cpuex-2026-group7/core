`timescale 1ns / 1ps
`default_nettype none

module br_decoder (
    input wire types::instr_t instr,
    input wire types::addr_t pc,
    output frontend::branch_type_t branch_type,
    output types::addr_t target_pc
);

  always_comb begin
    case (instr[31:27])
      isa::BRANCH_OP5: begin
        branch_type = BR_BRANCH;
        target_pc   = pc + {{22{instr[9]}}, instr[9:0]};
      end
      isa::JAL_OP5: begin
        branch_type = BR_JAL;
        target_pc   = pc + {{12{instr[19]}}, instr[19:0]};
      end
      isa::JALR_OP5: begin
        branch_type = BR_JALR;
        target_pc   = '0;  // unknown
      end
      default: begin
        branch_type = BR_NONE;
        target_pc   = '0;  // sequential
      end
    endcase
  end
endmodule

`default_nettype wire
