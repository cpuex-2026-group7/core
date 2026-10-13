module stage_if
import types::*;
(
    output addr_t pc_plus_1_f,
    wb_if_if.cons wb_if,
    if_id_if.prod if_id
);

addr_t pc_plus_1;
assign pc_plus_1 = wb_if.data.pc + 1;

assign pc_plus_1_f = pc_plus_1;
assign if_id.data.pc_plus_1 = pc_plus_1;
assign if_id.data.pc = wb_if.data.pc;

i_mem imem (
    .addr (wb_if.data.pc),
    .instr(if_id.data.instr)
);

endmodule
