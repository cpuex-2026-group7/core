package frontend_pkg;

  localparam int FETCH_W = 2;

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
    PCSRCF0_BTB,
    PCSRCF0_FRD,
    PCSRCF0_BRD
  } pc_src_F0_t;

  typedef struct packed {
    branch_type_t btype;
    logic predict_taken;
    logic actually_taken;
    logic actually_taken_valid;
  } ftq_bp_data_t;
  typedef struct packed {
    types::addr_t pc;
    ftq_bp_data_t bp_data;
  } ftq_data_t;

  typedef struct packed {
    isa::instr_t instr[FETCH_W];
    ooo_types::ftq_idx_t ftq_idx[FETCH_W];
    logic [FETCH_W-1:0] ftq_idx_valid;
    ooo_types::brmask_t brmask[FETCH_W];
    ooo_types::br_tag_t brtag[FETCH_W];
    logic [FETCH_W-1:0] brtag_valid;
    types::pc_t pc_head;
    types::pc_t predict_pc[FETCH_W];
    logic [FETCH_W-1:0] predict_pc_valid;
  } fetch_packet_t;

endpackage
