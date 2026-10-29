package frontend;
  typedef struct packed {
    logic valid;
    types::addr_t target;
  } btb_resp_t;

  typedef struct packed {logic taken;} bpd_resp_t;

  typedef enum logic [1:0] {
    BR_NONE,
    BR_BRANCH,
    BR_JAL,
    BR_JALR
  } branch_type_t;

  typedef enum logic [1:0] {
    PCSRCF0_SEQ,
    PCSRCF0_FRD,
    PCSRCF0_BRD
  } pc_src_F0_t;

  typedef struct packed {branch_type_t btype;} ftq_bp_data_t;
  typedef struct packed {
    types::addr_t pc;
    ftq_bp_data_t bp_data;
  } ftq_data_t;

endpackage
