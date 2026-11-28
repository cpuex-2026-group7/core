`timescale 1ns / 1ps
`default_nettype none

// priority is
// comm_recov > snap_recov > (push)
// snap idxは外から渡すのではなく内部管理で、外に払いだすようにした方がよさそう
module ghr #(
    parameter int GHR_ENTRY = 16,
    parameter int MAX_BR = 8
) (
    input wire logic clk,
    input wire logic rst,

    output logic [GHR_ENTRY-1:0] ghr,

    input wire frontend_pkg::ghr_push_t ghr_push_spec,
    input wire frontend_pkg::ghr_push_t ghr_push_comm,

    input  wire logic                      snap_push,
    // next index to push snapshot. 0 on reset, incremented on snap_push. (wraps around MAX_BR)
    output logic      [$clog2(MAX_BR)-1:0] snap_push_idx,

    input wire logic                      snap_recov,
    input wire logic [$clog2(MAX_BR)-1:0] snap_recov_idx,

    input wire logic comm_recov
);

  logic [GHR_ENTRY-1:0] ghr_snapshot [MAX_BR];
  logic [GHR_ENTRY-1:0] ghr_commited;

  function automatic logic [GHR_ENTRY-1:0] push(input logic [GHR_ENTRY-1:0] ghr,
                                                input frontend_pkg::ghr_push_t push_info);

    return (ghr << push_info.size) | GHR_ENTRY'(push_info.taken);

  endfunction

  always_ff @(posedge clk) begin : snap_push_idx_update
    if (rst) begin
      snap_push_idx <= '0;
    end else if (snap_push) begin
      snap_push_idx <= snap_push_idx + $clog2(MAX_BR)'(1);
    end
  end

  always_ff @(posedge clk) begin : update_ghr
    if (rst) begin
      ghr <= '0;
    end else if (comm_recov) begin
      ghr <= ghr_commited;
    end else if (snap_recov) begin
      ghr <= ghr_snapshot[snap_recov_idx];
    end else begin
      ghr <= push(ghr, ghr_push_spec);
    end
  end

  always_ff @(posedge clk) begin : update_snapshot
    if (rst) begin
      for (int i = 0; i < MAX_BR; i++) begin
        ghr_snapshot[i] <= '0;
      end
    end else if (snap_push) begin
      ghr_snapshot[snap_push_idx] <= ghr;
    end
  end

  always_ff @(posedge clk) begin : update_commit
    if (rst) begin
      ghr_commited <= '0;
    end else begin
      ghr_commited <= push(ghr_commited, ghr_push_comm);
    end
  end

endmodule
`default_nettype wire
