package frontend_pkg;

  localparam int FETCH_W = 2;
  localparam int BTB_ENTRY_SIZE = 128;
  localparam int BTB_TAG_WIDTH = 9;
  localparam int BIM_ENTRY_SIZE = 256;
  localparam int GSHARE_ENTRY_SIZE = 128;
  localparam int MAX_BR = 8;

  typedef logic [BTB_TAG_WIDTH-1:0] btb_tag_t;
  typedef logic [$clog2(BTB_ENTRY_SIZE)-1:0] btb_idx_t;
  typedef logic [$clog2(BIM_ENTRY_SIZE)-1:0] bim_idx_t;
  typedef logic [$clog2(GSHARE_ENTRY_SIZE)-1:0] gshare_idx_t;

  typedef enum logic [1:0] {
    BR_NONE,
    BR_BRANCH,
    BR_JAL,
    BR_JALR
  } branch_type_t;

  typedef enum logic [1:0] {
    PCSRCF0_SEQ,
    PCSRCF0_NLP,
    PCSRCF0_FRD,
    PCSRCF0_BRD
  } pc_src_F0_t;

  typedef enum logic [1:0] {
    PCSRC_SEQ = 2'b00,
    PCSRC_BTB = 2'b01,
    PCSRC_RAS = 2'b10,
    PCSRC_BER = 2'b11
  } pc_src_t;

  typedef struct packed {
    logic [$clog2(MAX_BR)-1:0] ghr_snap_idx;
    gshare_idx_t gshare_idx;
  } ftq_bp_data_t;
  typedef struct packed {
    types::pc_t   pc;
    ftq_bp_data_t bp_data;
  } ftq_data_t;

  typedef isa::instr_t [FETCH_W-1:0] instr_array_t;
  typedef ooo_types::brmask_t [FETCH_W-1:0] brmask_array_t;
  typedef ooo_types::br_tag_t [FETCH_W-1:0] brtag_array_t;
  typedef types::pc_t [FETCH_W-1:0] pc_array_t;
  typedef logic [FETCH_W-1:0] valid_array_t;

  typedef struct packed {
    instr_array_t instr;
    ooo_types::ftq_idx_t ftq_idx;
    brmask_array_t brmask;
    brtag_array_t brtag;
    types::pc_t pc_head;
    pc_array_t predict_pc;
    valid_array_t valid;
  } fetch_packet_t;

  typedef struct packed {
    btb_tag_t tag;
    logic valid;
    types::pc_t target;
  } btb_entry_t;

  typedef struct packed {
    types::pc_t pc;  // this should be the head pc of the fetch packet.
    logic valid;  // this is validness of the entry. not update itself.
    types::pc_t target;
  } btb_update_t;

  typedef struct packed {
    logic hit;
    btb_entry_t content;
  } btb_resp_t;

  // typedef logic [FETCH_W-1:0] bpd_resp_t;
  typedef struct packed {
    logic [FETCH_W-1:0] taken;
    gshare_idx_t gshare_idx;
  } bpd_resp_t;

  typedef struct packed {
    logic valid;  // 0 = btb miss
    logic taken;
    types::pc_t target;
    logic [$clog2(FETCH_W)-1:0] bidx;
  } nlp_resp_t;

  typedef struct packed {
    logic [$clog2(FETCH_W+1)-1:0] size;
    logic [FETCH_W-1:0] taken;
  } ghr_push_t;

  typedef struct packed {
    logic taken;
    pc_src_t pc_src;
  } brc_resp_t;

  typedef branch_type_t [FETCH_W-1:0] branch_types_t;
  typedef types::pc_t [FETCH_W-1:0] pcs_t;

  typedef struct packed {
    branch_types_t branch_types;
    pcs_t target_pcs;
    logic [FETCH_W-1:0] call;
    logic [FETCH_W-1:0] ret;
  } brdec_resp_t;
endpackage
