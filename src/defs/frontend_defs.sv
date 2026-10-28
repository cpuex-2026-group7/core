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

  typedef struct packed {
    logic valid;
    types::addr_t pc_key;
    types::addr_t pc_value;
  } btb_update_req_t;
endpackage
