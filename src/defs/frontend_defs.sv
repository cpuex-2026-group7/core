package frontend;
  typedef struct packed {
    logic valid;
    types::addr_t target;
  } btb_resp_t;

  typedef struct packed {logic taken;} bpredictor_resp_t;
endpackage
