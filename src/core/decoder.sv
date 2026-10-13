`timescale 1ns / 1ps
`default_nettype none

module decoder
  import isa::*;
(
  input  wire opcode_t op,
  output ctrl_t        ctrl
);

  always_comb begin
    // opから確定しているもの
    ctrl.rd_is_f        = op.eff[1];
    ctrl.reg_we         = op.eff[0] ^ op.eff[1];
    ctrl.mem_we         = (op.eff == EFF_MEM);
    ctrl.fpu_op         = fpu_op_t'({op.eff[0], op.imm[0], op.id});

    // 初期値
    ctrl.rs1_is_f       = 1'b0;
    ctrl.rs2_is_f       = 1'b0;
    ctrl.alu_op         = ALU_ADD;
    ctrl.alu_src_is_imm = 1'b1;
    ctrl.pc_src         = PC_PLUS_ONE;
    ctrl.result_src     = RES_ALU;
    ctrl.halt           = 1'b0;

    unique case (op.unit)
      UNIT_ALU: begin
        unique case (op.eff)
          EFF_NONE: begin
            unique case (op.imm)
              IMM_D: begin  // beq,bne,blt,bge
                ctrl.alu_op         = alu_op_t'({1'b1, op.id});  // idをそのまま入れられる
                ctrl.alu_src_is_imm = 1'b0;
                ctrl.pc_src         = PC_BRANCH;
              end
              default: begin  // halt
                ctrl.halt = 1'b1;
              end
            endcase
          end
          EFF_WI: begin
            unique case (op.imm)
              IMM_B: begin  // jal
                ctrl.pc_src     = PC_JAL;
                ctrl.result_src = RES_PC_PLUS_ONE;
              end
              IMM_C: begin
                if (op.id == 2'b00) begin  // jalr
                  ctrl.pc_src     = PC_JALR;
                  ctrl.result_src = RES_PC_PLUS_ONE;
                end else if (op.id == 2'b01) begin  // addi
                  ctrl.result_src = RES_ALU;
                end else begin  // lw
                  ctrl.result_src = RES_MEM;
                end
              end
              default: begin  // add / sub
                ctrl.alu_op         = op.id[0] ? ALU_SUB : ALU_ADD;
                ctrl.alu_src_is_imm = 1'b0;
              end
            endcase
          end
          EFF_WF:  ctrl.result_src = RES_MEM;  // flw
          EFF_MEM: ctrl.rs2_is_f = op.id[0];  // sw,fsw
        endcase
      end
      UNIT_FPU: begin
        ctrl.rs1_is_f = !(op.eff == EFF_WF && op.imm == IMM_C && op.id == 2'b00);  // fcvt.s.wだけIレジスタ
        ctrl.rs2_is_f = 1'b1;
        unique case (op.imm)
          IMM_A:   ctrl.result_src = RES_IMM;  // fli.s
          IMM_B:   ctrl.result_src = RES_HARD_CODE;  // flim.s 即値はsignedとして拡張
          default: ctrl.result_src = RES_FPU;
        endcase
      end
    endcase
  end

endmodule

`default_nettype wire
