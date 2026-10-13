package isa;
  import types::*;
  // ちなみにx0=0, f0=0の規約。
  // ワードアドレッシング

  // どっちのユニットを使うか?
  typedef enum logic {
    UNIT_ALU = 1'b0,  // ALUを使う
    UNIT_FPU = 1'b1   // FPUを使う
  } unit_t;

  // 作用
  typedef enum logic [1:0] {
    EFF_NONE = 2'b00,  // 書き込みなし
    EFF_WI   = 2'b01,  // Iレジスタに書く
    EFF_WF   = 2'b10,  // Fレジスタに書く
    EFF_MEM  = 2'b11   // メモリに書く
  } eff_t;

  // 即値形式
  typedef enum logic [1:0] {
    IMM_A = 2'b00,  // 引数1(float拡張)
    IMM_B = 2'b01,  // 引数1(imm20)
    IMM_C = 2'b10,  // 引数2(imm15)
    IMM_D = 2'b11   // 引数3(imm5+10)
  } imm_t;

  typedef struct packed {
    unit_t      unit;  // [31:31]
    eff_t       eff;   // [30:29]
    imm_t       imm;   // [28:27]
    logic [1:0] id;    // [26:25]
  } opcode_t;

  typedef struct packed {
    opcode_t    op;   // [31:25]
    reg_addr_t  rd;   // [24:20]
    reg_addr_t  rs1;  // [19:15]
    reg_addr_t  rs2;  // [14:10]
    logic [9:0] rest;  // [9:0]
  } instr_t;

  typedef enum logic [1:0] {
    PC_PLUS_ONE,  // pc+1
    PC_BRANCH,    // pc+1+imm (条件付き)
    PC_JAL,       // pc+1+imm
    PC_JALR       // rs1+imm
  } pc_src_t;

  typedef enum logic [2:0] {
    RES_ALU,
    RES_FPU,
    RES_MEM,
    RES_IMM,
    RES_HARD_CODE,
    RES_PC_PLUS_ONE
  } result_src_t;

  typedef enum logic [2:0] {
    ALU_ADD = 3'b000,
    ALU_SUB = 3'b001,
    ALU_EQ  = 3'b100,
    ALU_NE  = 3'b101,
    ALU_LT  = 3'b110,
    ALU_GE  = 3'b111
  } alu_op_t;

  // {eff[0], imm[0], id}
  typedef enum logic [3:0] {
    FPU_CVT_S_W = 4'b0000,
    FPU_SQRT    = 4'b0001,
    FPU_NEG     = 4'b0010,
    FPU_ABS     = 4'b0011,
    FPU_ADD     = 4'b0100,
    FPU_SUB     = 4'b0101,
    FPU_MUL     = 4'b0110,
    FPU_DIV     = 4'b0111,
    FPU_CVT_W_S = 4'b1000,
    FPU_EQ      = 4'b1100,
    FPU_LT      = 4'b1101
  } fpu_op_t;

  typedef struct packed {
    logic    rd_is_f;
    logic    rs1_is_f;
    logic    rs2_is_f;
    alu_op_t alu_op;
    fpu_op_t fpu_op;
    logic    alu_src_is_imm;
    logic    reg_we;
    logic    mem_we;
    pc_src_t pc_src;
    result_src_t result_src;
    logic    halt;
  } ctrl_t;

endpackage
