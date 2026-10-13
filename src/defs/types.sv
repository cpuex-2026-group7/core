
package types;
  typedef logic [31:0] word_t;
  typedef logic [31:0] addr_t;
  typedef logic [4:0] reg_addr_t;
  typedef logic [5:0] rf_idx_t;
endpackage

interface if_id_if;
  typedef struct packed {
    isa::instr_t  instr_D;
    types::addr_t pc_D;
    types::addr_t pc_plus_1_D;
  } payload_t;

  payload_t data;

  modport prod(output data);
  modport cons(input data);
endinterface  //if_id_if

interface id_ex_if;
  typedef struct packed {
    isa::ctrl_t ctrl_E;
    types::word_t rdata1_E;
    types::word_t rdata2_E;
    types::rf_idx_t rs1_E;
    types::rf_idx_t rs2_E;
    types::rf_idx_t rd_E;
    wtypes::word_t ext_imm_E;
    types::addr_t pc_E;
    types::addr_t pc_plus_1_E;
  } payload_t;

  payload_t data;

  modport prod(output data);
  modport cons(input data);
endinterface  //id_ex_if

interface ex_mem_if;
  typedef struct packed {
    isa::ctrl_t ctrl_F;
    types::word_t alu_result_F;
    types::word_t fpu_result_F;
    types::word_t wdata_F;
    types::rf_idx_t rd_F;
    types::word_t ext_imm_F;
    types::word_t hard_code_F;
    types::addr_t pc_plus_1_F;
  } payload_t;

  payload_t data;

  modport prod(output data);
  modport cons(input data);
endinterface  //ex_mem_if

interface mem_wb_if;
  typedef struct packed {
    logic reserved;  // TODO: Replace with stage signals.
  } payload_t;

  payload_t data;

  modport prod(output data);
  modport cons(input data);
endinterface  //mem_wb_if

interface wb_if_if;
  typedef struct packed {types::addr_t pc;} payload_t;

  payload_t data;

  modport prod(output data);
  modport cons(input data);
endinterface  //wb_if_if
