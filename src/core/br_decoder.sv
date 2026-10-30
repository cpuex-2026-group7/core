`timescale 1ns / 1ps
`default_nettype none

module br_decoder (
    input wire isa::instr_t instr,
    input wire types::addr_t pc,
    output frontend_pkg::branch_type_t branch_type,
    output types::addr_t target_pc
);

  always_comb begin
    case ({instr.op.unit, instr.op.eff, instr.op.imm})
      isa::BRANCH_OP5: begin
        branch_type = frontend_pkg::BR_BRANCH;
        target_pc   = pc + {{17{instr.rd[4]}}, instr.rd, instr.rest};
      end
      isa::JAL_OP5: begin
        branch_type = frontend_pkg::BR_JAL;
        target_pc   = pc + {{12{instr.rs1[4]}}, instr.rs1, instr.rs2, instr.rest};
      end
      isa::JALR_OP5: begin
        branch_type = (instr.op.id == 2'b00) ? frontend_pkg::BR_JALR : frontend_pkg::BR_NONE;
        target_pc   = '0;  // unknown
      end
      default: begin
        branch_type = frontend_pkg::BR_NONE;
        target_pc   = '0;  // sequential
      end
    endcase
  end
endmodule

`default_nettype wire
