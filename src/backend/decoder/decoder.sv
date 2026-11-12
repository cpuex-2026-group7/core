`timescale 1ns/1ps
`default_nettype none

// NOP, HALTのことを考えた実装はしていない。問題があれば直す。
module decoder #(
    parameter int FETCH_W = 2
)
(
    input fetch_packet_t fetch_packet,
    output dec_uop_t dec_uop[FETCH_W]
);

// disp_uopの情報生成の責務

// fetch packetの情報からdecoderが構成する情報
// - pc
// - predict_pc
// - ftq_idx
// - brmask? (frontend does not support brtag management for now 11/12.)
// - br_tag? (frontend does not support brtag management for now 11/12.)

// decoderが構成する情報
// - imm_type
// - imm
// - is_store
// - dest_eu
// - dest_fu
// - fu_op
// - lat

// 別の場所で構成される情報
// - rd(on rename)
// - rs1(on rename)
// - rs2(on rename)
// - rob_idx (on dispatch)
// - ldq_idx (assigned in LSU and applied in dispatch)
// - stq_idx (assigned in LSU and applied in dispatch)

always_comb begin : imm
    for(int i = 0; i < FETCH_W; i++) begin
        dec_uop[i].imm_type = fetch_packet.instr[i][27:26];
        unique case (dec_uop[i].imm_type)
            isa::IMM_A: dec_uop[i].imm = fetch_packet.instr[i][19:0];
            isa::IMM_B: dec_uop[i].imm = fetch_packet.instr[i][19:0];
            isa::IMM_C: dec_uop[i].imm = {5'd0,fetch_packet.instr[i][14:0]};
            isa::IMM_D: dec_uop[i].imm = {5'd0,fetch_packet.instr[i][24:20],fetch_packet.instr[i][9:0]};
        endcase
    end
end

always_comb begin : is_store
    for(int i = 0 ; i < FETCH_W ; i++) begin
        dec_uop[i].is_store = (fetch_packet.instr[i][31:29] == 3'b011);
    end
end

// golf time!
always_comb begin : lat_dest_eu
    for(int i = 0 ; i < FETCH_W; i++) begin
        logic is_mem, is_vlong, is_long, id_is_10, tmp;
        is_mem =
            (fetch_packet.instr[i][31:25] == 7'b0011010) ||
            (fetch_packet.instr[i][31:25] == 7'b0101000) ||
            (fetch_packet.instr[i][31:27] == 5'b01111);

        is_vlong =
            (fetch_packet.instr[i][31:25] == 7'b1101010) ||
            (fetch_packet.instr[i][31:25] == 7'b1101111);

        is_long =
            (fetch_packet.instr[i][31:27] == 5'b10110)   ||
            (fetch_packet.instr[i][31:25] == 7'b1101000) ||
            (fetch_packet.instr[i][31:26] == 6'b110110)  ||
            (fetch_packet.instr[i][31:25] == 7'b1101110);

        dec_uop[i].dest_eu = {
            is_vlong,
            fetch_packet.instr[i][31] & ~is_vlong,
            is_mem | is_long
        };

        dec_uop[i].lat = {
            is_long & (fetch_packet.instr[i][26:25] != 2'b10),
            is_long & (fetch_packet.instr[i][30:27] == 4'b1011)
        };
    end
end

// golf time! 2
always_comb begin : dest_fu
    for(int i = 0 ; i < FETCH_W ; i++) begin
        dec_uop[i].dest_fu = {
            instr[31] & (fetch_packet.instr[i][30:26] == 5'b10110),
            instr[31] & (fetch_packet.instr[i][30:29] == 2'b01
                        || fetch_packet.instr[i][30:25] == 6'b101000
                        || fetch_packet.instr[i][30:25] == 6'b101111)
        }
    end
end

endmodule

`default_nettype wire
