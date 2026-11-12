`timescale 1ns / 1ps
`default_nettype none

// lsu_searcher の単体テストベンチ（Verilator の --binary --timing で動かす）
//
// 実行時オプション
//   +cycles=N  試す回数（既定 500000）
//   +seed=N    乱数の種（既定 1）
//
// searcher は組合せ回路だけなので、毎回 LDQ / STQ の状態をばらばらに作り、出力をモデルと比べる。
// モデルは store に回り込まない通し番号（seq）を振り、新旧を seq の大小で決める（RTL の tail からの距離は使わない）。
//
// 状態の作り方（LDQ / STQ が守っている形）
//   - STQ には seq が [H, H+n) の store が入っている。エントリの番号は seq % STQ_SIZE。範囲外のエントリはでたらめ
//   - load は dispatch 時の STQ の tail を seq で T として持つ。T は [H-3, H+n]（T < H は古い store が全部解放済み）
//     older_st_mask は seq が [H, T) のエントリ、tail_stq_idx は T % STQ_SIZE
//   - load の状態は「出していない」「ld_requested」「gone_to_wb」のどれか
//   - fwd_hit はどの状態でも立ちうる。forward 元の seq は [T-STQ_SIZE, T)
//   - AGU の store は seq が [H, H+n) のもの
//   - AGU の load は LDQ のエントリのどれか。LDQ の FF にはまだアドレスが入っていないので、
//     エントリの addr / addr_valid はでたらめ（前にそのエントリを使った load の値）
//
// 期待値
//   ld_fwd：load のアドレスが来たときだけ。その load より古い store（seq が [H, T)）で addr_valid かつ
//     アドレスが ex_lsu.addr と同じもののうち seq が最大のもの。MMIO_RX_ADDR の load は hit にしない
//   違反：AGU の store より新しい（S < T）、valid かつ addr_valid でアドレスが同じ load について
//     forward 元の seq が S より大きければ何も立てない。そうでなければ
//     gone_to_wb なら violation、そうでなければ stale（ld_requested では絞らない。絞るのは LDQ）

module tb_lsu_searcher
  import types::*;
  import ooo_types::*;
  import ex_types::*;
  import lsu_types::*;
();

  localparam int SN = STQ_SIZE;
  localparam int LN = LDQ_SIZE;
  localparam int MAX_ERRORS = 30;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  ldq_searcher_t ldq            [LN];
  ldq_mask_t     violation_mask;
  ldq_mask_t     stale_mask;
  stq_searcher_t stq            [SN];
  ex_lsu_t       ex_lsu;
  ld_fwd_t       ld_fwd;

  lsu_searcher dut (.*);

  // initial の中から DUT の入力を直接書くと Verilator 5.020 の --timing で
  // DUT の組合せ回路が評価し直されないことがあるので、立ち下がりで写す
  ldq_searcher_t t_ldq[LN];
  stq_searcher_t t_stq[SN];
  ex_lsu_t       t_ex_lsu;

  always @(negedge clk) begin
    ldq <= t_ldq;
    stq <= t_stq;
    ex_lsu <= t_ex_lsu;
  end

  // ---------------- 乱数 ----------------

  function automatic int rnd(int n);
    return int'($urandom_range(n - 1, 0));
  endfunction

  // アドレスは少なくして一致を多く作る。上位ビットだけ違うものも混ぜる
  function automatic addr_t rnd_addr();
    case (rnd(8))
      0: return 32'h8000_0001;
      1: return 32'h0001_0000;
      2: return MMIO_RX_ADDR;
      default: return addr_t'(rnd(3));
    endcase
  endfunction

  // ---------------- 集計 ----------------

  int unsigned cycles;
  int unsigned seed;
  int unsigned cyc;
  int errors;

  int n_ld_agu, n_fw_hit, n_fw_miss, n_fw_full, n_fw_mmio, n_fw_old_addr;
  int n_st_agu, n_viol, n_stale, n_saved, n_by_old_fw, n_younger_st;

  task automatic err(string msg);
    errors++;
    $display("[%0d 回目] %s", cyc, msg);
    if (errors >= MAX_ERRORS) begin
      $display("FAIL（%0d 件で打ち切り）", errors);
      $finish;
    end
  endtask

  // ---------------- 1 回 ----------------

  task automatic one_case();
    int H, n, S, best, k;
    int T[LN];
    int F[LN];
    bit st_agu, ld_agu;
    ldq_searcher_t l[LN];
    stq_searcher_t s[SN];
    ex_lsu_t ex;
    ldq_mask_t exp_viol, exp_stale;
    bit match;

    // ---- STQ ----
    H = 100 + rnd(1000);
    n = rnd(4) == 0 ? SN : rnd(SN + 1);
    for (int i = 0; i < SN; i++) begin
      s[i].addr_valid = rnd(2) == 1;
      s[i].addr = rnd_addr();
      s[i].data_valid = rnd(2) == 1;
      s[i].data = $urandom();
    end
    for (int q = H; q < H + n; q++) begin
      s[q%SN].addr_valid = rnd(4) != 0;
      s[q%SN].data_valid = rnd(4) != 0;
    end

    // ---- LDQ ----
    for (int i = 0; i < LN; i++) begin
      T[i] = H - 3 + rnd(n + 4);
      l[i] = '0;
      l[i].valid = rnd(8) != 0;
      l[i].addr_valid = rnd(5) != 0;
      l[i].addr = rnd_addr();
      l[i].tail_stq_idx = stq_idx_t'(T[i] % SN);
      for (int q = H; q < T[i]; q++) l[i].older_st_mask[q%SN] = 1'b1;
      case (rnd(3))
        0: ;
        1: l[i].ld_requested = 1'b1;
        default: l[i].gone_to_wb = 1'b1;
      endcase
      F[i] = -1;
      if (rnd(2) == 1) begin
        F[i] = T[i] - SN + rnd(SN);
        l[i].fwd_hit = 1'b1;
        l[i].fwd_stq_idx = stq_idx_t'(F[i] % SN);
      end else begin
        l[i].fwd_stq_idx = stq_idx_t'($urandom());
      end
    end

    // ---- AGU ----
    ex = '0;
    ex.addr = rnd_addr();
    ex.data = $urandom();
    ex.ldq_idx = ldq_idx_t'($urandom());
    ex.stq_idx = stq_idx_t'($urandom());
    st_agu = 1'b0;
    ld_agu = 1'b0;
    S = -1;
    k = int'(ex.ldq_idx);
    case (rnd(10))
      0, 1, 2, 3: begin
        if (n > 0) begin
          S = H + rnd(n);
          ex.is_store = 1'b1;
          ex.addr_valid = 1'b1;
          ex.data_valid = rnd(2) == 1;
          ex.stq_idx = stq_idx_t'(S % SN);
          st_agu = 1'b1;
        end
      end
      4, 5, 6, 7: begin
        ex.is_store = 1'b0;
        ex.addr_valid = 1'b1;
        ld_agu = 1'b1;
        // アドレスはこのサイクルに来る。エントリにはまだ入っていない
        l[k].addr_valid = 1'b0;
        l[k].gone_to_wb = 1'b0;
        l[k].ld_requested = 1'b0;
        l[k].fwd_hit = 1'b0;
      end
      8: begin
        // STD だけの store。何も出ないはず
        ex.is_store = 1'b1;
        ex.data_valid = 1'b1;
      end
      default: ;
    endcase

    t_ldq = l;
    t_stq = s;
    t_ex_lsu = ex;

    @(negedge clk);
    #1;

    // ---- forward 元 ----
    if (ld_agu) begin
      n_ld_agu++;
      best = -1;
      for (int q = H; q < T[k]; q++) begin
        if (s[q%SN].addr_valid && s[q%SN].addr == ex.addr) best = q;
      end
      if (T[k] - H == SN) n_fw_full++;
      if (ex.addr == MMIO_RX_ADDR) begin
        if (best >= 0) n_fw_mmio++;
        best = -1;
      end
      if (best < 0) begin
        n_fw_miss++;
        if (ld_fwd.hit)
          err($sformatf("ld_fwd：load %0d（addr %h）は当たらないはずなのに hit（stq_idx %0d、エントリの古い addr %h）", k,
                        ex.addr, ld_fwd.stq_idx, l[k].addr));
      end else begin
        n_fw_hit++;
        if (l[k].addr != ex.addr) n_fw_old_addr++;
        if (!ld_fwd.hit)
          err($sformatf("ld_fwd：load %0d（addr %h）は STQ %0d に当たるはずなのに hit=0（エントリの古い addr %h）", k,
                        ex.addr, best % SN, l[k].addr));
        else if (int'(ld_fwd.stq_idx) != best % SN)
          err($sformatf("ld_fwd：load %0d（tail %0d）の stq_idx = %0d、期待値 %0d（H %0d n %0d）", k, T[k] % SN,
                        ld_fwd.stq_idx, best % SN, H % SN, n));
      end
    end else begin
      if (ld_fwd.hit) err("ld_fwd：load のアドレスが来ていないのに hit");
    end

    // ---- 違反 ----
    exp_viol = '0;
    exp_stale = '0;
    if (st_agu) begin
      n_st_agu++;
      for (int i = 0; i < LN; i++) begin
        match = l[i].valid && l[i].addr_valid && l[i].addr == ex.addr;
        if (match && S >= T[i]) n_younger_st++;
        if (match && S < T[i]) begin
          if (F[i] > S) n_saved++;
          else begin
            if (F[i] >= 0) n_by_old_fw++;
            if (l[i].gone_to_wb) exp_viol[i] = 1'b1;
            else exp_stale[i] = 1'b1;
          end
        end
      end
    end
    for (int i = 0; i < LN; i++) begin
      if (violation_mask[i] != exp_viol[i])
        err($sformatf("violation_mask[%0d] = %0b、期待値 %0b（store seq %0d、load T %0d F %0d gone %0b fwd %0b）", i,
                      violation_mask[i], exp_viol[i], S - H, T[i] - H, F[i] - H, l[i].gone_to_wb, l[i].fwd_hit));
      if (stale_mask[i] != exp_stale[i])
        err($sformatf("stale_mask[%0d] = %0b、期待値 %0b（store seq %0d、load T %0d F %0d gone %0b fwd %0b）", i,
                      stale_mask[i], exp_stale[i], S - H, T[i] - H, F[i] - H, l[i].gone_to_wb, l[i].fwd_hit));
    end
    n_viol += $countones(exp_viol);
    n_stale += $countones(exp_stale);
  endtask

  // ---------------- 本体 ----------------

  initial begin
    if (!$value$plusargs("cycles=%d", cycles)) cycles = 500000;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    $display("lsu_searcher: seed=%0d cycles=%0d", seed, cycles);

    for (int i = 0; i < LN; i++) t_ldq[i] = '0;
    for (int i = 0; i < SN; i++) t_stq[i] = '0;
    t_ex_lsu = '0;
    repeat (2) @(negedge clk);
    #1;

    for (cyc = 0; cyc < cycles; cyc++) one_case();

    $display("load の AGU %0d：hit %0d（エントリの古い addr と違う %0d）、miss %0d（MMIO なので外した %0d）、STQ が満杯で dispatch された load %0d",
             n_ld_agu, n_fw_hit, n_fw_old_addr, n_fw_miss, n_fw_mmio, n_fw_full);
    $display("store の AGU %0d：violation %0d、stale %0d（うち古い forward 元を持っていた %0d）、新しい forward 元で免除 %0d",
             n_st_agu, n_viol, n_stale, n_by_old_fw, n_saved);
    $display("load より新しい store なので無視 %0d", n_younger_st);
    if (errors == 0) $display("PASS");
    else $display("FAIL（%0d 件）", errors);
    $finish;
  end

endmodule

`default_nettype wire
