`timescale 1ns / 1ps
`default_nettype none

// ex_top（EX 全体）のテストベンチ（Verilator の --binary --timing で動かす）
//
// 実行時オプション
//   +cycles=N  ランダムテストのサイクル数（既定 200000）
//   +seed=N    乱数の種（既定 1）
//
// 各 EU の中身は EU ごとのテストで見ているので、ここで確かめるのは ex_top で足したものと配線。
//   - 即値の符号拡張（extend_imm）が imm_type どおりに各 EU に渡っていること
//   - ALU と F短 の分岐の結果を 1 本の br_update_ff にまとめること（同じサイクルに 2 本来る場合も）
//   - その br_update_ff が全部の EU に戻って kill / ビット落としに使われること
//   - 各ポートが正しい EU に繋がっていること（to_wb / ex_lsu / バイパス / slow_wakeup / blocked）
//
// 演算器（fmul / itof / ftoi / fadd / fsqrt / fdiv）は test/eu_3_top/models/ と test/eu_4_top/models/ の
// 代わりを使う。値とサイクル数は eu_3_model_pkg / eu_4_model_pkg のもので、float の計算ではない。
//
// テストベンチは dispatch と IQ の代わりをする
//   - 命令ごとに年齢（プログラム順の番号）を持つ。分岐（条件分岐・JALR・fb*）は issue するときに
//     空いている tag を取り、その時点で一番若い年齢を付ける
//   - brmask は「自分より古い、割り当て中の分岐の tag」。だから同じサイクルに 2 本の分岐が来たら、
//     若い方の brmask に古い方の tag が入る
//   - br_update_ff で resolve された tag は空ける。mispredict のときは、その分岐と、それより若い分岐を
//     全部空け、それより若い年齢の命令はもう出さない。flush のときは全部空けて、それまでの年齢は全部捨てる
//   - rr_ex は RR で今の br_update を当てた後のものなので、brmask は今の kill_mask / resolve_mask と重ねない
//   - F超長 の FU i には、前のサイクルの blocked[i] が 0 で、前のサイクルに FU i に出していないときだけ出す
//   - rst は最初の 3 サイクルだけ（途中の rst は EU ごとのテストで見ている）
//
// negedge で次のサイクルの入力を入れ、1ns 待ってから出力を見る。
//
// テストの前提にしている仕様（rr_ex がサイクル t に来たとする）
//   - imm = imm_type で拡張した imm。A は {imm[19:0], 12'b0}、B は imm[19:0] の符号拡張、
//     C / D は imm[14:0] の符号拡張
//   - 書き込みのサイクル：ALU / MEM / F短 は t+1、F長 は t+LAT_FADD+1、F超長 は演算器の done のサイクル
//     （fsqrt と fdiv が同じサイクルに終わったら fdiv は次のサイクル）
//   - サイクル t の flush で消える。その後の各サイクル k で、k の flush か「その時点の brmask & k の
//     kill_mask」で消える。brmask は各サイクルの resolve_mask でビットを落とす
//   - 値：ALU は eu_0_top のテストと同じ。MEM は addr = rs1+imm、data = rs2。
//     F短 は FLI が imm、FCSIGN が imm[1:0] で符号を変えたもの、fb* は IEEE の比較で taken を決める。
//     F長 / F超長 は eu_3_model_pkg / eu_4_model_pkg の m_*
//   - br_update_ff（サイクル k+1）= k の rst か flush なら 0。そうでなければ、k に出た分岐の結果
//     （ALU と F短）について、mispredict なら kill_mask、当たりなら resolve_mask にその tag を立てる。
//     mispredict のうち一番古いもの（年齢で決める）の tag / taken / pc / target / rob_idx を復帰用に入れる
//   - バイパス（kill は当てない、そのサイクルまでに消えたものは出さない）
//       bypass_fpu_f[0]：t = k-1-LAT_FMUL の fmul
//       bypass_fpu_f[1]：t = k-1-LAT_ITOF の fmul と itof
//       bypass_fpu_i[0]：t = k-1-LAT_ITOF の ftoi
//   - slow_wakeup_fpu = {wb_fpu[2].valid, wb_fpu[2].rd, LAT_FAST}
//   - fsqrt_blocked / fdiv_blocked：t < k で、まだ書き込んでいない（待っている fdiv も含む）生きた命令がある

module tb_ex_top
  import types::*;
  import isa::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import iq_types::*;
  import rr_types::*;
  import ex_types::*;
  import eu_3_model_pkg::*;
  import eu_4_model_pkg::*;
();

  localparam int MAX_ERRORS = 30;
  localparam int AGE_WINDOW = 16;  // 分岐でない命令の年齢は、一番若い年齢からこの範囲で選ぶ

  // レーン（= ex_top のポート）
  localparam int L_ALU = 0;
  localparam int L_MEM = 1;
  localparam int L_FS  = 2;
  localparam int L_FL  = 3;
  localparam int L_FVL = 4;
  localparam int NLANE = 5;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic         rst;
  logic         flush;
  rr_ex_int_t   rr_ex_int[1];
  rr_ex_mem_t   rr_ex_mem[1];
  rr_ex_float_t rr_ex_fpu[3];

  // always の中から unpacked 配列の要素に直接書くと、Verilator 5.020 の --timing で DUT の中の
  // それを読む組合せ回路（ex_top の extend_imm）が評価し直されないので、packed の信号から assign で入れる
  rr_ex_int_t   in_int;
  rr_ex_mem_t   in_mem;
  rr_ex_float_t in_fpu0;
  rr_ex_float_t in_fpu1;
  rr_ex_float_t in_fpu2;
  assign rr_ex_int[0] = in_int;
  assign rr_ex_mem[0] = in_mem;
  assign rr_ex_fpu[0] = in_fpu0;
  assign rr_ex_fpu[1] = in_fpu1;
  assign rr_ex_fpu[2] = in_fpu2;
  ex_wb_t       wb_alu[1];
  ex_wb_t       wb_fpu[3];
  bypass_t      bypass_fpu_f[2];
  bypass_t      bypass_fpu_i[1];
  ex_lsu_t      ex_lsu[1];
  br_update_t   br_update_ff;
  wakeup_t      slow_wakeup_fpu;
  logic         fdiv_blocked;
  logic         fsqrt_blocked;

  ex_top dut (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .rr_ex_int(rr_ex_int),
    .rr_ex_mem(rr_ex_mem),
    .rr_ex_fpu(rr_ex_fpu),
    .wb_alu(wb_alu),
    .wb_fpu(wb_fpu),
    .bypass_fpu_f(bypass_fpu_f),
    .bypass_fpu_i(bypass_fpu_i),
    .ex_lsu(ex_lsu),
    .br_update_ff(br_update_ff),
    .slow_wakeup_fpu(slow_wakeup_fpu),
    .fdiv_blocked(fdiv_blocked),
    .fsqrt_blocked(fsqrt_blocked)
  );

  // ---------------- 乱数 ----------------

  function automatic int unsigned rnd(int unsigned n);
    return $urandom_range(n - 1, 0);
  endfunction

  function automatic word_t rnd_word();
    case (rnd(8))
      0: return 32'h0000_0000;
      1: return 32'hffff_ffff;
      2: return 32'h8000_0000;
      3: return 32'h7fff_ffff;
      4: return word_t'(rnd(16));
      5: return -word_t'(rnd(16) + 1);
      default: return $urandom();
    endcase
  endfunction

  // NaN 以外の float。±0、±inf、±1 を多めに出す
  function automatic word_t rnd_float();
    word_t f;
    case (rnd(8))
      0: return 32'h0000_0000;
      1: return 32'h8000_0000;
      2: return 32'h7f80_0000;
      3: return 32'h3f80_0000;
      4: return 32'hbf80_0000;
      default: begin
        f = $urandom();
        if (f[30:23] == 8'hff) f[30:23] = 8'hfe;
        return f;
      end
    endcase
  endfunction

  function automatic word_t rnd_float_near(word_t a);
    case (rnd(4))
      0: return a;
      1: return {~a[31], a[30:0]};
      default: return rnd_float();
    endcase
  endfunction

  function automatic pc_t rnd_pc();
    case (rnd(6))
      0: return 16'h0000;
      1: return 16'hffff;
      default: return pc_t'($urandom());
    endcase
  endfunction

  // imm の生の値。上の方のビットは使われない形式でもでたらめに入れておく
  function automatic imm_raw_t rnd_imm_raw();
    imm_raw_t r;
    r = imm_raw_t'($urandom());
    case (rnd(6))
      0: r[14:0] = 15'h0000;
      1: r[14:0] = 15'h7fff;
      2: r[14:0] = 15'h4000;
      3: r[14:0] = 15'(rnd(64)) - 15'd32;
      default: ;
    endcase
    return r;
  endfunction

  function automatic preg_t rnd_preg(preg_type_t typ);
    return preg_t'{typ: typ, idx: preg_idx_t'(rnd(64))};
  endfunction

  // ---------------- 参照モデル（DUT とは別の書き方で計算する） ----------------

  function automatic word_t ref_ext(imm_t typ, imm_raw_t raw);
    int v;
    case (typ)
      IMM_A: return word_t'(raw) * 32'd4096;
      IMM_B: begin
        v = int'(raw);
        if (raw[19]) v -= (1 << 20);
        return word_t'(v);
      end
      default: begin
        v = int'(raw[14:0]);
        if (raw[14]) v -= (1 << 15);
        return word_t'(v);
      end
    endcase
  endfunction

  function automatic word_t ref_sra(word_t x, logic [5:0] sh);
    word_t r;
    int    s;
    s = sh[5] ? int'(sh) - 64 : int'(sh);
    for (int i = 0; i < 32; i++) begin
      if (s >= 0) r[i] = (i + s > 31) ? x[31] : x[i+s];
      else r[i] = (i + s < 0) ? 1'b0 : x[i+s];
    end
    return r;
  endfunction

  function automatic logic is_zero(word_t a);
    return a[30:0] == 31'd0;
  endfunction

  function automatic logic ref_feq(word_t a, word_t b);
    if (is_zero(a) && is_zero(b)) return 1'b1;
    return a == b;
  endfunction

  function automatic logic ref_flt(word_t a, word_t b);
    if (is_zero(a) && is_zero(b)) return 1'b0;
    if (a[31] != b[31]) return a[31];
    if (!a[31]) return a[30:0] < b[30:0];
    return a[30:0] > b[30:0];
  endfunction

  function automatic logic alu_is_br(fu_op_t op);
    return op == FU_OP_BEQ || op == FU_OP_BNE || op == FU_OP_BLT || op == FU_OP_BGE || op == FU_OP_JALR;
  endfunction

  function automatic logic alu_is_cond(fu_op_t op);
    return op == FU_OP_BEQ || op == FU_OP_BNE || op == FU_OP_BLT || op == FU_OP_BGE;
  endfunction

  function automatic logic fs_is_br(fu_op_t op);
    return op == FU_OP_FBEQ || op == FU_OP_FBNE || op == FU_OP_FBLT || op == FU_OP_FBGE;
  endfunction

  function automatic logic alu_taken(fu_op_t op, word_t a, word_t b);
    case (op)
      FU_OP_BEQ: return a == b;
      FU_OP_BNE: return a != b;
      FU_OP_BLT: return $signed(a) < $signed(b);
      FU_OP_BGE: return $signed(a) >= $signed(b);
      default:   return 1'b1;  // JAL / JALR
    endcase
  endfunction

  function automatic logic fs_taken(fu_op_t op, word_t a, word_t b);
    case (op)
      FU_OP_FBEQ: return ref_feq(a, b);
      FU_OP_FBNE: return !ref_feq(a, b);
      FU_OP_FBLT: return ref_flt(a, b);
      default:    return !ref_flt(a, b);  // FBGE
    endcase
  endfunction

  // ---------------- 命令のモデル ----------------

  typedef struct packed {
    int         lane;
    int         t_in;      // rr_ex に出したサイクル
    int         t_wb;      // 書き込むサイクル（F超長 は done のサイクル）
    int         age;
    logic       held;      // F超長：fsqrt と同時に終わって待っている fdiv
    brmask_t    brmask;
    dest_fu_t   fu;
    fu_op_t     op;
    preg_t      rd;
    rob_idx_t   rob_idx;
    word_t      value;
    // 分岐
    logic       is_br;
    br_tag_t    tag;
    logic       taken;
    pc_t        pc;
    pc_t        target;
    logic       mispredict;
    // MEM
    logic [1:0] part;
    logic       is_store;
    addr_t      addr;
    word_t      data;
    ldq_idx_t   ldq_idx;
    stq_idx_t   stq_idx;
  } ent_t;

  ent_t q[$];

  // 分岐の tag の割り当て
  logic alloc[MAX_BR];
  int   tag_age[MAX_BR];
  int   newest_age;
  // もう出さない年齢の範囲 (dead_lo, dead_hi]
  int   dead_lo[$];
  int   dead_hi[$];

  function automatic logic is_dead_age(int a);
    foreach (dead_lo[i]) if (a > dead_lo[i] && a <= dead_hi[i]) return 1'b1;
    return 1'b0;
  endfunction

  function automatic brmask_t mask_older(int a);
    brmask_t m;
    m = '0;
    for (int i = 0; i < MAX_BR; i++) if (alloc[i] && tag_age[i] < a) m[i] = 1'b1;
    return m;
  endfunction

  // 分岐でない命令の年齢
  function automatic int pick_age();
    int a;
    for (int n = 0; n < 8; n++) begin
      a = newest_age - int'(rnd(AGE_WINDOW + 1));
      if (a >= 0 && !is_dead_age(a)) return a;
    end
    newest_age++;
    return newest_age;
  endfunction

  // 空いている tag を取る。無ければ -1
  function automatic int alloc_tag();
    int free[$];
    free.delete();
    for (int i = 0; i < MAX_BR; i++) if (!alloc[i]) free.push_back(i);
    if (free.size() == 0) return -1;
    return free[rnd(free.size())];
  endfunction

  // ---------------- 実行と照合 ----------------

  int unsigned cycles;
  int unsigned seed;
  int          cyc;
  int          errors;

  br_update_t  exp_upd;        // 今のサイクルの br_update_ff の期待値
  logic        prev_blocked[2];
  logic        prev_issued[2];

  // 何を確かめたかの数
  int n_wb[NLANE];
  int n_killed[NLANE];
  int n_imm[4];
  int n_br[2];               // ALU / F短 の分岐の結果
  int n_mis[2];
  int n_two_br;              // 同じサイクルに 2 本
  int n_two_mis;             // 同じサイクルに 2 本とも mispredict
  int n_oldest_fs;           // 2 本の mispredict で F短 の方が古かった
  int n_hold;
  int n_bypass[3];
  int n_flush;

  task automatic fail(string msg);
    errors++;
    if (errors <= MAX_ERRORS) $display("[cycle %0d] NG: %s", cyc, msg);
  endtask

  function automatic string ent_str(ent_t e);
    return $sformatf("lane %0d t_in=%0d age=%0d op=%b fu=%0d rd=%h rob=%0d", e.lane, e.t_in, e.age, e.op, e.fu, e.rd,
                     e.rob_idx);
  endfunction

  // br_update_ff で tag の割り当てを直す
  task automatic apply_upd_to_table(br_update_t u);
    int a;
    if (u.mispredict) begin
      if (!alloc[u.tag]) begin
        fail($sformatf("br_update の mispredict の tag %0d が割り当てられていない", u.tag));
      end else begin
        a = tag_age[u.tag];
        for (int i = 0; i < MAX_BR; i++) if (alloc[i] && tag_age[i] >= a) alloc[i] = 1'b0;
        dead_lo.push_back(a);
        dead_hi.push_back(newest_age);
      end
    end
    for (int i = 0; i < MAX_BR; i++) if (u.resolve_mask[i] || u.kill_mask[i]) alloc[i] = 1'b0;
  endtask

  task automatic check_upd();
    if (br_update_ff.resolve_mask !== exp_upd.resolve_mask || br_update_ff.kill_mask !== exp_upd.kill_mask
        || br_update_ff.mispredict !== exp_upd.mispredict) begin
      fail($sformatf("br_update_ff resolve=%b kill=%b mispredict=%b 期待 resolve=%b kill=%b mispredict=%b",
                     br_update_ff.resolve_mask, br_update_ff.kill_mask, br_update_ff.mispredict,
                     exp_upd.resolve_mask, exp_upd.kill_mask, exp_upd.mispredict));
      return;
    end
    if (!exp_upd.mispredict) return;
    if (br_update_ff.tag !== exp_upd.tag || br_update_ff.taken !== exp_upd.taken || br_update_ff.pc !== exp_upd.pc
        || br_update_ff.target !== exp_upd.target || br_update_ff.rob_idx !== exp_upd.rob_idx)
      fail($sformatf("br_update_ff 復帰用 tag=%0d taken=%b pc=%h target=%h rob=%0d 期待 %0d %b %h %h %0d",
                     br_update_ff.tag, br_update_ff.taken, br_update_ff.pc, br_update_ff.target, br_update_ff.rob_idx,
                     exp_upd.tag, exp_upd.taken, exp_upd.pc, exp_upd.target, exp_upd.rob_idx));
  endtask

  // 年齢を付けて、brmask を割り当ての表から作る
  function automatic logic set_age(ref ent_t e, input logic want_br);
    int tg;
    if (want_br) begin
      tg = alloc_tag();
      if (tg < 0) return 1'b0;
      newest_age++;
      e.age = newest_age;
      e.brmask = mask_older(e.age);
      e.tag = br_tag_t'(tg);
      alloc[tg] = 1'b1;
      tag_age[tg] = e.age;
      e.is_br = 1'b1;
    end else begin
      e.age = pick_age();
      e.brmask = mask_older(e.age);
      e.tag = br_tag_t'(rnd(MAX_BR));
      e.is_br = 1'b0;
    end
    return 1'b1;
  endfunction

  localparam int NALU = 10;
  fu_op_t alu_ops[NALU] = '{FU_OP_BEQ, FU_OP_BNE, FU_OP_BLT, FU_OP_BGE, FU_OP_JAL, FU_OP_JALR,
                            FU_OP_ADD, FU_OP_ADDI, FU_OP_SUB, FU_OP_SRA};
  localparam int NFS = 6;
  fu_op_t fs_ops[NFS] = '{FU_OP_FBEQ, FU_OP_FBNE, FU_OP_FBLT, FU_OP_FBGE, FU_OP_FLI, FU_OP_FCSIGN};

  // ALU の命令を作る。valid でなければ 0
  task automatic gen_alu(output rr_ex_int_t r, output ent_t e, output logic v);
    fu_op_t op;
    word_t  im;
    r = '0;
    e = '0;
    v = rnd(4) != 0;
    if (!v) return;
    op = alu_ops[rnd(NALU)];
    if (!set_age(e, alu_is_br(op))) begin
      op = FU_OP_ADD;
      void'(set_age(e, 1'b0));
    end
    r.common.valid = 1'b1;
    r.common.rs1_val = rnd_word();
    r.common.rs2_val = (rnd(4) == 0) ? r.common.rs1_val : rnd_word();
    r.common.dest_fu = FU_INT;
    r.common.brmask = e.brmask;
    r.common.rd = alu_is_cond(op) ? preg_t'{typ: PREG_TYPE_NONE, idx: '0} : rnd_preg(PREG_TYPE_I);
    r.payload.fu_op = op;
    case (op)
      FU_OP_JAL: r.payload.imm_type = IMM_B;
      FU_OP_JALR: r.payload.imm_type = IMM_C;
      FU_OP_ADDI: r.payload.imm_type = imm_t'(rnd(4));  // 拡張を全部の形式で見る
      default: r.payload.imm_type = IMM_D;
    endcase
    r.payload.imm = rnd_imm_raw();
    r.payload.pc = rnd_pc();
    r.payload.ftq_idx = ftq_idx_t'(rnd(32));
    r.payload.rob_idx = rob_idx_t'(rnd(ROB_SIZE));
    r.payload.br_tag = e.tag;
    im = ref_ext(r.payload.imm_type, r.payload.imm);

    e.lane = L_ALU;
    e.op = op;
    e.rd = r.common.rd;
    e.rob_idx = r.payload.rob_idx;
    e.pc = r.payload.pc;
    case (op)
      FU_OP_ADD:  e.value = r.common.rs1_val + r.common.rs2_val;
      FU_OP_ADDI: e.value = r.common.rs1_val + im;
      FU_OP_SUB:  e.value = r.common.rs1_val - r.common.rs2_val;
      FU_OP_SRA:  e.value = ref_sra(r.common.rs1_val, im[5:0]);
      default:    e.value = 32'(pc_t'(r.payload.pc + 16'd1));
    endcase
    e.taken = alu_taken(op, r.common.rs1_val, r.common.rs2_val);
    if (!e.taken) e.target = r.payload.pc + 16'd1;
    else if (op == FU_OP_JALR) e.target = pc_t'(r.common.rs1_val + im);
    else e.target = pc_t'(32'(r.payload.pc) + im);
    r.payload.predict_pc = (rnd(2) == 0) ? e.target : rnd_pc();
    e.mispredict = e.target != r.payload.predict_pc;
    if (op == FU_OP_ADDI) n_imm[r.payload.imm_type]++;
  endtask

  task automatic gen_mem(output rr_ex_mem_t r, output ent_t e, output logic v);
    word_t im;
    r = '0;
    e = '0;
    v = rnd(3) != 0;
    if (!v) return;
    void'(set_age(e, 1'b0));
    r.common.valid = 1'b1;
    r.common.rs1_val = rnd_word();
    r.common.rs2_val = rnd_word();
    r.common.dest_fu = FU_MEM;
    r.common.brmask = e.brmask;
    r.payload.is_store = rnd(2) == 0;
    r.common.rd = r.payload.is_store ? preg_t'{typ: PREG_TYPE_NONE, idx: '0} : rnd_preg(preg_type_t'(rnd(2)));
    r.payload.imm_type = imm_t'(rnd(4));
    r.payload.imm = rnd_imm_raw();
    r.payload.rob_idx = rob_idx_t'(rnd(ROB_SIZE));
    r.payload.ldq_idx = ldq_idx_t'(rnd(LDQ_SIZE));
    r.payload.stq_idx = stq_idx_t'(rnd(STQ_SIZE));
    r.issue_part = r.payload.is_store ? 2'(rnd(3) + 1) : 2'b01;
    im = ref_ext(r.payload.imm_type, r.payload.imm);

    e.lane = L_MEM;
    e.part = r.issue_part;
    e.is_store = r.payload.is_store;
    e.addr = r.common.rs1_val + im;
    e.data = r.common.rs2_val;
    e.ldq_idx = r.payload.ldq_idx;
    e.stq_idx = r.payload.stq_idx;
    n_imm[r.payload.imm_type]++;
  endtask

  task automatic gen_fs(output rr_ex_float_t r, output ent_t e, output logic v);
    fu_op_t op;
    word_t  im;
    word_t  a;
    r = '0;
    e = '0;
    v = rnd(4) != 0;
    if (!v) return;
    op = fs_ops[rnd(NFS)];
    if (!set_age(e, fs_is_br(op))) begin
      op = FU_OP_FLI;
      void'(set_age(e, 1'b0));
    end
    r.common.valid = 1'b1;
    r.common.rs1_val = rnd_float();
    r.common.rs2_val = rnd_float_near(r.common.rs1_val);
    r.common.dest_fu = FU_F_SHORT;
    r.common.brmask = e.brmask;
    r.common.rd = fs_is_br(op) ? preg_t'{typ: PREG_TYPE_NONE, idx: '0} : rnd_preg(PREG_TYPE_F);
    r.payload.fu_op = op;
    case (op)
      FU_OP_FLI: r.payload.imm_type = IMM_A;
      FU_OP_FCSIGN: r.payload.imm_type = IMM_C;
      default: r.payload.imm_type = IMM_D;
    endcase
    r.payload.imm = rnd_imm_raw();
    r.payload.pc = rnd_pc();
    r.payload.ftq_idx = ftq_idx_t'(rnd(32));
    r.payload.rob_idx = rob_idx_t'(rnd(ROB_SIZE));
    r.payload.br_tag = e.tag;
    im = ref_ext(r.payload.imm_type, r.payload.imm);
    a = r.common.rs1_val;

    e.lane = L_FS;
    e.op = op;
    e.rd = r.common.rd;
    e.rob_idx = r.payload.rob_idx;
    e.pc = r.payload.pc;
    if (op == FU_OP_FLI) begin
      e.value = im;
    end else begin
      case (im[1:0])
        2'b00:   e.value = a;
        2'b01:   e.value = {~a[31], a[30:0]};
        2'b10:   e.value = {1'b0, a[30:0]};
        default: e.value = {1'b1, a[30:0]};
      endcase
    end
    if (fs_is_br(op)) begin
      e.taken = fs_taken(op, r.common.rs1_val, r.common.rs2_val);
      e.target = e.taken ? pc_t'(32'(r.payload.pc) + im) : r.payload.pc + 16'd1;
      r.payload.predict_pc = (rnd(2) == 0) ? e.target : rnd_pc();
      e.mispredict = e.target != r.payload.predict_pc;
    end else begin
      r.payload.predict_pc = rnd_pc();
    end
  endtask

  task automatic gen_fl(output rr_ex_float_t r, output ent_t e, output logic v);
    r = '0;
    e = '0;
    v = rnd(3) != 0;
    if (!v) return;
    void'(set_age(e, 1'b0));
    r.common.valid = 1'b1;
    r.common.rs1_val = rnd_word();
    r.common.rs2_val = rnd_word();
    r.common.brmask = e.brmask;
    case (rnd(3))
      0: begin
        r.common.dest_fu = FU_FMUL;
        r.payload.fu_op = FU_OP_FMUL;
        r.common.rd = rnd_preg(PREG_TYPE_F);
        e.value = m_fmul(r.common.rs1_val, r.common.rs2_val);
      end
      1: begin
        r.common.dest_fu = FU_FCVT;
        if (rnd(2) == 0) begin
          r.payload.fu_op = FU_OP_ITOF;
          r.common.rd = rnd_preg(PREG_TYPE_F);
          e.value = m_itof(r.common.rs1_val);
        end else begin
          r.payload.fu_op = FU_OP_FTOI;
          r.common.rd = rnd_preg(PREG_TYPE_I);
          e.value = m_ftoi(r.common.rs1_val);
        end
      end
      default: begin
        r.common.dest_fu = FU_FADD;
        r.payload.fu_op = (rnd(2) == 0) ? FU_OP_FADD : FU_OP_FSUB;
        r.common.rd = rnd_preg(PREG_TYPE_F);
        e.value = m_fadd(r.common.rs1_val, r.common.rs2_val, r.payload.fu_op[0]);
      end
    endcase
    r.payload.imm_type = IMM_C;
    r.payload.imm = rnd_imm_raw();
    r.payload.rob_idx = rob_idx_t'(rnd(ROB_SIZE));

    e.lane = L_FL;
    e.fu = r.common.dest_fu;
    e.op = r.payload.fu_op;
    e.rd = r.common.rd;
    e.rob_idx = r.payload.rob_idx;
  endtask

  task automatic gen_fvl(output rr_ex_float_t r, output ent_t e, output logic v);
    logic can[2];
    int   fu;
    r = '0;
    e = '0;
    can[0] = !prev_blocked[0] && !prev_issued[0];
    can[1] = !prev_blocked[1] && !prev_issued[1];
    v = (can[0] || can[1]) && rnd(2) == 0;
    if (!v) return;
    if (can[0] && can[1]) fu = int'(rnd(2));
    else fu = can[0] ? 0 : 1;
    void'(set_age(e, 1'b0));
    r.common.valid = 1'b1;
    r.common.rs1_val = rnd_word();
    r.common.rs2_val = rnd_word();
    r.common.brmask = e.brmask;
    r.common.dest_fu = dest_fu_t'(fu);
    r.common.rd = rnd_preg(PREG_TYPE_F);
    r.payload.fu_op = (fu == 0) ? FU_OP_FSQRT : FU_OP_FDIV;
    r.payload.imm_type = IMM_C;
    r.payload.imm = rnd_imm_raw();
    r.payload.rob_idx = rob_idx_t'(rnd(ROB_SIZE));

    e.lane = L_FVL;
    e.fu = r.common.dest_fu;
    e.op = r.payload.fu_op;
    e.rd = r.common.rd;
    e.rob_idx = r.payload.rob_idx;
    if (fu == FU_FSQRT) e.value = m_fsqrt(r.common.rs1_val);
    else e.value = m_fdiv(r.common.rs1_val, r.common.rs2_val);
  endtask

  // バイパスの期待値
  task automatic check_bypass(string name, bypass_t got, int t_in, logic want_fmul, logic want_itof,
                              logic want_ftoi, int idx);
    ent_t e;
    logic hit;
    hit = 1'b0;
    foreach (q[i]) begin
      if (q[i].lane != L_FL || q[i].t_in != t_in) continue;
      if ((want_fmul && q[i].fu == FU_FMUL) || (want_itof && q[i].fu == FU_FCVT && q[i].op == FU_OP_ITOF)
          || (want_ftoi && q[i].fu == FU_FCVT && q[i].op == FU_OP_FTOI)) begin
        hit = 1'b1;
        e = q[i];
      end
    end
    if (got.valid !== hit) begin
      fail($sformatf("%s.valid=%b 期待 %b", name, got.valid, hit));
      return;
    end
    if (!hit) return;
    n_bypass[idx]++;
    if (got.rd !== e.rd || got.value !== e.value)
      fail($sformatf("%s rd=%h value=%h 期待 rd=%h value=%h（%s）", name, got.rd, got.value, e.rd, e.value, ent_str(e)));
  endtask

  task automatic check_wb(string name, ex_wb_t got, logic hit, ent_t e, logic see_value);
    if (got.valid !== hit) begin
      if (hit) fail($sformatf("%s.valid=0 期待 1（%s）", name, ent_str(e)));
      else fail($sformatf("%s.valid=1 期待 0（rd=%h rob=%0d）", name, got.rd, got.rob_idx));
      return;
    end
    if (!hit) return;
    if (got.rd !== e.rd) fail($sformatf("%s.rd=%h 期待 %h（%s）", name, got.rd, e.rd, ent_str(e)));
    if (got.rob_idx !== e.rob_idx)
      fail($sformatf("%s.rob_idx=%0d 期待 %0d（%s）", name, got.rob_idx, e.rob_idx, ent_str(e)));
    if (see_value && got.value !== e.value)
      fail($sformatf("%s.value=%h 期待 %h（%s）", name, got.value, e.value, ent_str(e)));
  endtask

  // サイクル k の出力を見て、次のサイクルの br_update_ff の期待値を作る
  task automatic check_cycle(int k, logic rst_k, logic flush_k);
    logic   exp_blk[2];
    ent_t   e;
    logic   hit[NLANE];
    ent_t   w[NLANE];
    int     hold_i;
    int     fresh_i[2];
    ent_t   brs[$];
    br_update_t nu;
    int     oldest;

    // タスクのローカル変数が呼ぶたびに初期化されないことがある（Verilator 5.020）ので、全部ここで入れる
    brs.delete();
    e = '0;
    for (int l = 0; l < NLANE; l++) begin
      hit[l] = 1'b0;
      w[l] = '0;
    end

    // バイパスと blocked（このサイクルの kill の前）
    check_bypass("bypass_fpu_f[0]", bypass_fpu_f[0], k - 1 - int'(LAT_FMUL), 1'b1, 1'b0, 1'b0, 0);
    check_bypass("bypass_fpu_f[1]", bypass_fpu_f[1], k - 1 - int'(LAT_ITOF), 1'b1, 1'b1, 1'b0, 1);
    check_bypass("bypass_fpu_i[0]", bypass_fpu_i[0], k - 1 - int'(LAT_ITOF), 1'b0, 1'b0, 1'b1, 2);
    exp_blk[0] = 1'b0;
    exp_blk[1] = 1'b0;
    foreach (q[i]) if (q[i].lane == L_FVL && q[i].t_in < k) exp_blk[q[i].fu] = 1'b1;
    if (fsqrt_blocked !== exp_blk[FU_FSQRT])
      fail($sformatf("fsqrt_blocked=%b 期待 %b", fsqrt_blocked, exp_blk[FU_FSQRT]));
    if (fdiv_blocked !== exp_blk[FU_FDIV]) fail($sformatf("fdiv_blocked=%b 期待 %b", fdiv_blocked, exp_blk[FU_FDIV]));

    // このサイクルの kill / flush とビット落とし
    for (int i = q.size() - 1; i >= 0; i--) begin
      if (flush_k || |(q[i].brmask & exp_upd.kill_mask)) begin
        n_killed[q[i].lane]++;
        q.delete(i);
      end else begin
        q[i].brmask &= ~exp_upd.resolve_mask;
      end
    end

    // 固定レイテンシのレーン
    for (int l = 0; l < NLANE; l++) hit[l] = 1'b0;
    for (int i = q.size() - 1; i >= 0; i--) begin
      if (q[i].lane == L_FVL || q[i].t_wb != k) continue;
      if (hit[q[i].lane]) fail($sformatf("同じサイクルに 2 つ書き込む（テストの誤り）：%s", ent_str(q[i])));
      hit[q[i].lane] = 1'b1;
      w[q[i].lane] = q[i];
      q.delete(i);
    end

    // F超長：待っている fdiv が先、次に fsqrt、最後に fdiv
    hold_i = -1;
    fresh_i[0] = -1;
    fresh_i[1] = -1;
    foreach (q[i]) begin
      if (q[i].lane != L_FVL) continue;
      if (q[i].held) hold_i = i;
      else if (q[i].t_wb == k) fresh_i[q[i].fu] = i;
      else if (q[i].t_wb < k) fail($sformatf("F超長 が書き込まれないまま残っている：%s", ent_str(q[i])));
    end
    if (hold_i >= 0) begin
      if (fresh_i[0] >= 0 || fresh_i[1] >= 0) fail("待っている fdiv があるサイクルに別の演算が終わった（テストの前提が崩れた）");
      hit[L_FVL] = 1'b1;
      w[L_FVL] = q[hold_i];
      q.delete(hold_i);
    end else if (fresh_i[FU_FSQRT] >= 0) begin
      hit[L_FVL] = 1'b1;
      w[L_FVL] = q[fresh_i[FU_FSQRT]];
      if (fresh_i[FU_FDIV] >= 0) begin
        q[fresh_i[FU_FDIV]].held = 1'b1;
        n_hold++;
      end
      q.delete(fresh_i[FU_FSQRT]);
    end else if (fresh_i[FU_FDIV] >= 0) begin
      hit[L_FVL] = 1'b1;
      w[L_FVL] = q[fresh_i[FU_FDIV]];
      q.delete(fresh_i[FU_FDIV]);
    end
    for (int i = q.size() - 1; i >= 0; i--) begin
      if (q[i].lane == L_FVL && !q[i].held && q[i].t_wb < k) q.delete(i);
    end

    for (int l = 0; l < NLANE; l++) if (hit[l]) n_wb[l]++;

    check_wb("wb_alu[0]", wb_alu[0], hit[L_ALU], w[L_ALU], !alu_is_cond(w[L_ALU].op));
    check_wb("wb_fpu[0]", wb_fpu[0], hit[L_FS], w[L_FS], !fs_is_br(w[L_FS].op));
    check_wb("wb_fpu[1]", wb_fpu[1], hit[L_FL], w[L_FL], 1'b1);
    check_wb("wb_fpu[2]", wb_fpu[2], hit[L_FVL], w[L_FVL], 1'b1);

    if (slow_wakeup_fpu.valid !== wb_fpu[2].valid || (wb_fpu[2].valid && (slow_wakeup_fpu.preg !== wb_fpu[2].rd
        || slow_wakeup_fpu.latency !== LAT_FAST)))
      fail($sformatf("slow_wakeup_fpu=%b/%h/%0d 期待 %b/%h/%0d", slow_wakeup_fpu.valid, slow_wakeup_fpu.preg,
                     slow_wakeup_fpu.latency, wb_fpu[2].valid, wb_fpu[2].rd, LAT_FAST));

    // MEM
    e = w[L_MEM];
    if (ex_lsu[0].addr_valid !== (hit[L_MEM] && e.part[0]) || ex_lsu[0].data_valid !== (hit[L_MEM] && e.part[1])) begin
      fail($sformatf("ex_lsu addr_valid=%b data_valid=%b 期待 %b %b", ex_lsu[0].addr_valid, ex_lsu[0].data_valid,
                     hit[L_MEM] && e.part[0], hit[L_MEM] && e.part[1]));
    end else if (hit[L_MEM]) begin
      if (e.part[0] && ex_lsu[0].addr !== e.addr) fail($sformatf("ex_lsu.addr=%h 期待 %h", ex_lsu[0].addr, e.addr));
      if (e.part[1] && ex_lsu[0].data !== e.data) fail($sformatf("ex_lsu.data=%h 期待 %h", ex_lsu[0].data, e.data));
      if (ex_lsu[0].is_store !== e.is_store || ex_lsu[0].ldq_idx !== e.ldq_idx || ex_lsu[0].stq_idx !== e.stq_idx)
        fail($sformatf("ex_lsu is_store=%b ldq=%0d stq=%0d 期待 %b %0d %0d", ex_lsu[0].is_store, ex_lsu[0].ldq_idx,
                       ex_lsu[0].stq_idx, e.is_store, e.ldq_idx, e.stq_idx));
    end

    // 次のサイクルの br_update_ff
    if (hit[L_ALU] && w[L_ALU].is_br) begin
      brs.push_back(w[L_ALU]);
      n_br[0]++;
    end
    if (hit[L_FS] && w[L_FS].is_br) begin
      brs.push_back(w[L_FS]);
      n_br[1]++;
    end
    if (brs.size() == 2) n_two_br++;
    nu = '0;
    oldest = -1;
    foreach (brs[i]) begin
      if (brs[i].mispredict) begin
        nu.kill_mask[brs[i].tag] = 1'b1;
        n_mis[brs[i].lane == L_FS]++;
        if (oldest < 0 || brs[i].age < brs[oldest].age) oldest = i;
      end else begin
        nu.resolve_mask[brs[i].tag] = 1'b1;
      end
    end
    if (brs.size() == 2 && brs[0].mispredict && brs[1].mispredict) begin
      n_two_mis++;
      if (brs[oldest].lane == L_FS) n_oldest_fs++;
    end
    if (oldest >= 0) begin
      nu.mispredict = 1'b1;
      nu.tag = brs[oldest].tag;
      nu.taken = brs[oldest].taken;
      nu.pc = brs[oldest].pc;
      nu.target = brs[oldest].target;
      nu.rob_idx = brs[oldest].rob_idx;
    end
    exp_upd = (rst_k || flush_k) ? br_update_t'('0) : nu;
  endtask

  initial begin
    if (!$value$plusargs("cycles=%d", cycles)) cycles = 200000;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    $display("ex_top: seed=%0d cycles=%0d", seed, cycles);
    rst = 1'b1;
    flush = 1'b0;
    in_int = '0;
    in_mem = '0;
    in_fpu0 = '0;
    in_fpu1 = '0;
    in_fpu2 = '0;
    cyc = 0;
    errors = 0;
    exp_upd = '0;
    newest_age = 0;
    for (int i = 0; i < MAX_BR; i++) alloc[i] = 1'b0;
    prev_blocked = '{1'b0, 1'b0};
    prev_issued = '{1'b0, 1'b0};
  end

  // initial から直接 DUT の入力を書くと Verilator 5.020 の --timing で組み合わせ回路が
  // 評価し直されないことがあるので、always の中で入れる
  always @(negedge clk) begin
    logic         r_k;
    logic         f_k;
    rr_ex_int_t   ri;
    rr_ex_mem_t   rm;
    rr_ex_float_t rf[3];
    ent_t         e[NLANE];
    logic         v[NLANE];
    logic         alu_first;

    // 今のサイクルの br_update_ff
    if (cyc > 0) check_upd();
    apply_upd_to_table(exp_upd);

    // 入力を作る
    r_k = cyc < 3;
    f_k = !r_k && rnd(60) == 0;
    for (int l = 0; l < NLANE; l++) v[l] = 1'b0;
    ri = '0;
    rm = '0;
    for (int i = 0; i < 3; i++) rf[i] = '0;
    if (!r_k) begin
      // 同じサイクルの 2 本の分岐のどちらが古いかを入れ替える
      alu_first = rnd(2) == 0;
      if (alu_first) begin
        gen_alu(ri, e[L_ALU], v[L_ALU]);
        gen_fs(rf[0], e[L_FS], v[L_FS]);
      end else begin
        gen_fs(rf[0], e[L_FS], v[L_FS]);
        gen_alu(ri, e[L_ALU], v[L_ALU]);
      end
      gen_mem(rm, e[L_MEM], v[L_MEM]);
      gen_fl(rf[1], e[L_FL], v[L_FL]);
      gen_fvl(rf[2], e[L_FVL], v[L_FVL]);
    end
    rst = r_k;
    flush = f_k;
    in_int = ri;
    in_mem = rm;
    in_fpu0 = rf[0];
    in_fpu1 = rf[1];
    in_fpu2 = rf[2];
    #1;

    check_cycle(cyc, r_k, f_k);

    // flush なら分岐の割り当てを全部空けて、それまでの年齢を捨てる
    if (r_k || f_k) begin
      for (int i = 0; i < MAX_BR; i++) alloc[i] = 1'b0;
      dead_lo.push_back(-1);
      dead_hi.push_back(newest_age);
      if (f_k) n_flush++;
    end
    // 古い dead の範囲を捨てる
    for (int i = dead_lo.size() - 1; i >= 0; i--) begin
      if (dead_hi[i] < newest_age - AGE_WINDOW - 1) begin
        dead_lo.delete(i);
        dead_hi.delete(i);
      end
    end

    // 今のサイクルに入れた命令を覚える（flush で入口で消えるものは入れない）
    prev_issued[0] = v[L_FVL] && e[L_FVL].fu == FU_FSQRT;
    prev_issued[1] = v[L_FVL] && e[L_FVL].fu == FU_FDIV;
    prev_blocked[0] = fsqrt_blocked;
    prev_blocked[1] = fdiv_blocked;
    if (!r_k && !f_k) begin
      for (int l = 0; l < NLANE; l++) begin
        if (!v[l]) continue;
        e[l].t_in = cyc;
        case (l)
          L_FL: e[l].t_wb = cyc + 1 + int'(LAT_FADD);
          L_FVL: e[l].t_wb = cyc + ((e[l].fu == FU_FSQRT) ? lat_fsqrt(rf[2].common.rs1_val)
                                                          : lat_fdiv(rf[2].common.rs1_val, rf[2].common.rs2_val));
          default: e[l].t_wb = cyc + 1;
        endcase
        q.push_back(e[l]);
      end
    end

    cyc++;
    if (cyc >= cycles) begin
      if (dut.u_eu_4_top.u_fu_0.u_fsqrt.n_protocol_error != 0 || dut.u_eu_4_top.u_fu_1.u_fdiv.n_protocol_error != 0)
        fail("F超長 の演算器に演算中の issued が来た");
      $display("書き込み ALU %0d / MEM %0d / F短 %0d / F長 %0d / F超長 %0d", n_wb[L_ALU], n_wb[L_MEM], n_wb[L_FS],
               n_wb[L_FL], n_wb[L_FVL]);
      $display("途中で kill / flush ALU %0d / MEM %0d / F短 %0d / F長 %0d / F超長 %0d（flush %0d 回）", n_killed[L_ALU],
               n_killed[L_MEM], n_killed[L_FS], n_killed[L_FL], n_killed[L_FVL], n_flush);
      $display("即値の形式（ADDI と MEM） A %0d / B %0d / C %0d / D %0d", n_imm[IMM_A], n_imm[IMM_B], n_imm[IMM_C],
               n_imm[IMM_D]);
      $display("分岐の結果 ALU %0d（mispredict %0d）/ F短 %0d（mispredict %0d）", n_br[0], n_mis[0], n_br[1], n_mis[1]);
      $display("  同じサイクルに 2 本 %0d、2 本とも mispredict %0d（F短 の方が古い %0d）", n_two_br, n_two_mis,
               n_oldest_fs);
      $display("バイパス f[0] %0d / f[1] %0d / i[0] %0d、fdiv を待たせた %0d", n_bypass[0], n_bypass[1], n_bypass[2],
               n_hold);
      if (errors == 0) $display("PASS");
      else $display("FAIL（%0d 件）", errors);
      $finish;
    end
  end

endmodule

`default_nettype wire
