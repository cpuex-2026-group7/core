
package types;
  typedef logic [31:0] word_t;
  typedef logic [31:0] addr_t;
  typedef logic [4:0] reg_addr_t;
  typedef logic [5:0] rf_idx_t;
endpackage

interface if_id_if;
  typedef struct packed {
    isa::instr_t instr;
    types::addr_t pc;
    types::addr_t pc_plus_1;
  } payload_t;

  payload_t data;

  modport prod (output data);
  modport cons (input data);
endinterface //if_id_if

interface id_ex_if;
  typedef struct packed {

  } payload_t;

  payload_t data;

  modport prod (output data);
  modport cons (input data);
endinterface //id_ex_if

interface ex_mem_if;
  typedef struct packed {
    logic reserved; // TODO: Replace with stage signals.
  } payload_t;

  payload_t data;

  modport prod (output data);
  modport cons (input data);
endinterface //ex_mem_if

interface mem_wb_if;
  typedef struct packed {
    logic reserved; // TODO: Replace with stage signals.
  } payload_t;

  payload_t data;

  modport prod (output data);
  modport cons (input data);
endinterface //mem_wb_if

interface wb_if_if;
  typedef struct packed {
    types::addr_t pc;
  } payload_t;

  payload_t data;

  modport prod (output data);
  modport cons (input data);
endinterface //wb_if_if
