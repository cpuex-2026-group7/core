`timescale 1ns/1ps
`default_nettype none

// TODO restart from resolving Spec-[P1]-1.

module rob
#(
    parameter int DISPATCH_W = 1,
    parameter int WB_W = 2
)(
    input wire logic clk,
    input wire logic rst,

    input wire ooo_types::br_update_t br_update,

    // check the br_update_t usage (mispredict/resolve)

    // when the load instruction comes to the oldest instruction
    // in ROB, then fire flush signals.
    output logic flush, // assert on LD violation; fire when violating LD inst comes to the head of ROB(the oldest uncommitted inst.)

    output logic ready,
    output logic valid, // this may be unnecessary

    // disp stage uses this row information.
    // disp stage adds lane information and send that to later stages.
    output ooo_types::rob_row_t rob_tail_o,

    // for now, disp_uop_t is used both in ROB and IQ
    // I/F. I suppose this type is originally made for IQ.
    // There is also the option of creating a new type for
    // ROB because ROB requires input of ldst, stale_pdst
    // , which disp_uop_t does not have.
    input wire logic [DISPATCH_W-1:0] dis_mask,
    input wire uop_types::disp_uop_t dis_uops[DISPATCH_W],
    output logic [DISPATCH_W-1:0] com_mask,
    output uop_types::disp_uop_t com_uops[DISPATCH_W],

    input wire rob_types::complete_t wb_comp[WB_W],

    // the following 4 kind of signals may be included in
    // a type like disp_uop_t. We could also create a new
    // type for this like `rob_uop_t`.
    input wire types::rf_idx_t dis_ldst[DISPATCH_W],
    input wire ooo_types::preg_t dis_stale_pdst[DISPATCH_W],
    output types::rf_idx_t com_ldst[DISPATCH_W],
    output ooo_types::preg_t com_stale_pdst[DISPATCH_W],

    input wire rob_types::load_violation_t load_violation
);

ooo_types::rob_row_t rob_head, rob_head_next;
ooo_types::rob_row_t rob_tail, rob_tail_next;

rob_types::rob_entry_t entries[DISPATCH_W][ooo_types::ROB_SIZE];
types::pc_t pcs[ooo_types::ROB_SIZE];

assign rob_tail_o = rob_tail;

assign rob_head_next = rob_head + ooo_types::rob_row_t'(1);
assign rob_tail_next = rob_tail + ooo_types::rob_row_t'(1);

assign ready = !(rob_head == rob_tail_next); //!full
assign valid = !(rob_head == rob_tail); //!empty

logic [DISPATCH_W-1:0] head_valids;

for (genvar i = 0; i < DISPATCH_W; i++) begin : gen_head_valids
    assign head_valids[i] = entries[i][rob_head].valid;
end

always_comb begin : detect_head_exception
    logic found;
    found = 1'b0;
    flush = 1'b0;

    if (valid) begin // do not flush when rob is empty.
        for(int i = 0; i < DISPATCH_W; i++) begin
            if (!found && entries[i][rob_head].valid) begin
                flush = entries[i][rob_head].excp;
                found = 1'b1;
            end
        end
    end
end

// commitability is judged PER INSTRUCTION; not per row.
// This means 0x200 is commited when 0x200(bsy=0) and 0x201(bsy=1)
// even if 0x200 and 0x201 are in the same fetch packet.
always_ff @(posedge clk) begin : entry_manipulation
    if (rst || flush) begin
        rob_head <= '0;
        rob_tail <= '0;
        for(int i = 0 ; i < ooo_types::ROB_SIZE; i++) begin
            pcs[i] <= '0;
            for(int j = 0; j < DISPATCH_W; j++) begin
                entries[j][i].valid <= 1'b0;
            end
        end
    end else if (|br_update.kill_mask) begin
        rob_tail <= br_update.rob_idx.row + ooo_types::rob_row_t'(1);
        for(int i = 0; i < ooo_types::ROB_SIZE; i++) begin
            for(int j = 0; j < DISPATCH_W; j++) begin
                if(|(entries[j][i].brmask & br_update.kill_mask)) begin
                    entries[j][i].valid <= 1'b0;
                    entries[j][i].excp <= 1'b0;
                end
                entries[j][i].brmask <= entries[j][i].brmask & ~br_update.resolve_mask;
            end
        end

        for (int i = 0; i < WB_W; i++) begin
            if (wb_comp[i].valid)
                entries[wb_comp[i].rob_idx.bank][wb_comp[i].rob_idx.row].busy <= 1'b0;
        end

        if (load_violation.valid)
            entries[load_violation.rob_idx.bank][load_violation.rob_idx.row].excp <= 1'b1;
    end else begin

        for (int i = 0; i < ooo_types::ROB_SIZE; i++) begin : apply_br_resolve
            for(int j = 0; j < DISPATCH_W; j++) begin
                entries[j][i].brmask <= entries[j][i].brmask & ~br_update.resolve_mask;
            end
        end

        pcs[rob_tail] <= dis_uops[0].pc;
        for(int i = 0; i < DISPATCH_W; i++) begin : push_and_pop

            // make it invalid on commit.
            entries[i][rob_head].valid <= !com_mask[i] & entries[i][rob_head].valid;

            entries[i][rob_tail].valid <= dis_mask[i];
            entries[i][rob_tail].busy <= 1'b1;
            entries[i][rob_tail].excp <= 1'b0;
            entries[i][rob_tail].brmask <= dis_uops[i].brmask;
            entries[i][rob_tail].ldst <= dis_ldst[i];
            entries[i][rob_tail].stale_pdst <= dis_stale_pdst[i];
            entries[i][rob_tail].uop <= dis_uops[i]; // brmask is included in dis_uops. there should be a room for improvements.
        end
        rob_tail <= dis_mask == '0 ? rob_tail : rob_tail_next;
        rob_head <= ((|com_mask) && (com_mask == head_valids))
            ? rob_head_next
            : rob_head;

        for (int i = 0; i < WB_W; i++) begin : clr_bsy_on_comp
            if (wb_comp[i].valid)
                entries[wb_comp[i].rob_idx.bank][wb_comp[i].rob_idx.row].busy <= 1'b0;
        end
        if (load_violation.valid)
            entries[load_violation.rob_idx.bank][load_violation.rob_idx.row].excp <= 1'b1;
    end
end

always_comb begin : commit_flags
    logic found;
    found = 1'b0; // assert if valid & (bsy | excp)
    for (int i = 0 ; i < DISPATCH_W; i++) begin
        if(entries[i][rob_head].valid && (entries[i][rob_head].busy || entries[i][rob_head].excp))
            found = 1'b1;
        if (rst || flush || (|br_update.kill_mask)) 
            com_mask[i] = 1'b0;
        else
            com_mask[i] = !found & entries[i][rob_head].valid;
        com_uops[i] = entries[i][rob_head].uop; 
        com_ldst[i] = entries[i][rob_head].ldst;
        com_stale_pdst[i] = entries[i][rob_head].stale_pdst;
    end
end


endmodule

`default_nettype wire