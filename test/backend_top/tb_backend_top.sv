`timescale 1ns / 1ps
`default_nettype none

// backend_top（IQ / RR / EX / WB / LSU）のテストベンチ（Verilator の --binary --timing で動かす）
//
// 実行時オプション
//   +cycles=N  ランダムテストのサイクル数（既定 200000）
//   +seed=N    乱数の種（既定 1）
//
// 各モジュールの中身はそれぞれのテストで見ているので、ここで確かめるのは繋いだときの振る舞い。
//   - wakeup の lat と、実際に値が RR に届くサイクル（WB からのバイパス、F長 の途中からのバイパス、PRF）が合っていること
//     （定型テストで、依存する 2 命令の書き込みの間隔を決め打ちで見る）
//   - 依存のある命令列を流したとき、全部の結果が正しいこと（ランダムテスト。値は dispatch の時点でテスト側が計算する）
//   - 分岐の mispredict と flush で、消えるべき命令が消え、残るべき命令が残ること
//   - br_update_ff の中身（resolve / kill の mask と、一番古い mispredict の復帰用の情報）
//   - 止まらないこと（どの命令も一定サイクル以内に終わる）
//
// LSU（ldq / stq / lsu_controller / lsu_searcher）はまだポートだけなので、load の値は返ってこない。
// MEM の命令は EX から LSU に渡す ex_lsu（dut.ex_lsu）で終わったことにする。load の rd は NONE にしておく
// （値が返らないので、rd を持たせると待っている命令が永遠に止まる）。dispatch から LSU への入力と D$ の入力は 0 のまま。
//
// 演算器（fmul / itof / ftoi / fadd / fsqrt / fdiv）は test/eu_3_top/models/ と test/eu_4_top/models/ の代わりを使う。
//
// テストベンチは rename / dispatch / ROB の代わりをする
//   - 物理レジスタは I / F それぞれ 64 本を自分で割り当てる（rename はしない）。rd には空いているものを取り、
//     読み手がもういなくなった書き込み済みのものを空ける。ソースは書き込み済みか、生きている命令が書く予定のものから選ぶ
//   - 命令はプログラム順に、1 サイクルに各 IQ に 1 つまで出す。出せない命令が来たらそのサイクルはそこで止める
//   - rob_idx / br_tag / ldq_idx / stq_idx は生きている命令の中で重ならないように割り当てる
//   - brmask は「自分より古い、まだ解決していない分岐の tag」
//   - 空けたもの（tag / rob_idx / 物理レジスタなど）は次のサイクルから使う
//   - 分岐（条件分岐 / jalr / fb*）は、正しい飛び先を predict_pc に入れるか、わざと外す
//   - flush はランダムに入れる。そのサイクルには dispatch しない
//
// negedge で次のサイクルの入力を入れ、1ns 待ってから出力を見る。
//
// テストの前提にしている仕様
//   - 書き込み（WB）：ALU は wb_alu[0]、F短 / F長 / F超長 は wb_fpu[0..2]。complete_idx[0, 2, 3, 4] は同じ valid と rob_idx
//   - 分岐の結果は WB の次のサイクルの br_update_ff に出る。mispredict なら kill_mask、当たりなら resolve_mask
//   - br_update_ff の kill_mask が見えたサイクルから、それより若い命令は WB にも ex_lsu にも出ない
//   - flush のサイクルから、それまでに出した命令は WB にも ex_lsu にも出ない
//   - 値：ALU / F短 は ex_top のテストと同じ。F長 / F超長 は eu_3_model_pkg / eu_4_model_pkg の m_*
//     jal / jalr の rd は 16bit で計算した pc+1 をゼロ拡張したもの
//   - 定型テストの間隔（issue を i とすると、ALU / MEM / F短 は i+2、F長 は i+5 に書く。
//     固定レイテンシの wakeup は issue のサイクルに lat で出て、消費側は i+1+lat に issue できる。
//     F超長 は書き込みのサイクルに lat=0 で出す）
//       addi→addi 1、fli→fcsign 1、fmul→fmul 2、itof→fadd 3、fadd→fmul 4、fmul→fcsign -1、ftoi→addi 0、
//       addi→itof 4、fmul→ftoi 2、ftoi→itof 3、addi→beq 1、fadd→fbeq 1、
//       addi→sw（アドレス）1、fli→fsw（データ）1、fmul→fsw（データ）-1、ftoi→sw（データ）0、
//       addi→lw（アドレス）1、ftoi→lw（アドレス）0、fsqrt→fadd 6、fdiv→fcsign 3、fsqrt→fsw（データ）3

module tb_backend_top
  import types::*;
  import isa::*;
  import ooo_types::*;
  import uop_types::*;
  import back_types::*;
  import iq_types::*;
  import rr_types::*;
  import ex_types::*;
  import rob_types::*;
  import lsu_types::*;
  import eu_3_model_pkg::*;
  import eu_4_model_pkg::*;
();

  localparam int MAX_ERRORS = 30;
  localparam int LSU_DISP_W = 2;
  localparam int COMMIT_W = 1;
  localparam int NPREG = 64;
  localparam int FREE_TARGET = 16;  // 空きの物理レジスタがこれより少なければ空ける
  localparam int STUCK_LIMIT = 3000;
  localparam int FLUSH_RATE = 600;

  // IQ
  localparam int Q_INT = 0;
  localparam int Q_MEM = 1;
  localparam int Q_FPU = 2;

  // レーン（= 書き込みのポート）
  localparam int L_ALU = 0;
  localparam int L_MEM = 1;
  localparam int L_FS  = 2;
  localparam int L_FL  = 3;
  localparam int L_FVL = 4;

  // 命令の種類
  localparam int K_ADD    = 0;
  localparam int K_ADDI   = 1;
  localparam int K_SUB    = 2;
  localparam int K_SRA    = 3;
  localparam int K_JAL    = 4;
  localparam int K_JALR   = 5;
  localparam int K_BR     = 6;
  localparam int K_FLI    = 7;
  localparam int K_FLHI   = 8;
  localparam int K_FCSIGN = 9;
  localparam int K_FBR    = 10;
  localparam int K_FMUL   = 11;
  localparam int K_ITOF   = 12;
  localparam int K_FTOI   = 13;
  localparam int K_FADD   = 14;
  localparam int K_FSUB   = 15;
  localparam int K_FSQRT  = 16;
  localparam int K_FDIV   = 17;
  localparam int K_LW     = 18;
  localparam int K_SW     = 19;
  localparam int NK       = 20;

  // ランダムテストでの出やすさ
  int weight[NK] = '{6, 8, 4, 4, 2, 2, 8, 5, 3, 4, 5, 6, 3, 3, 5, 3, 1, 1, 4, 6};

  // 物理レジスタの状態
  localparam int P_FREE  = 0;
  localparam int P_PEND  = 1;  // 生きている命令が書く予定
  localparam int P_KNOWN = 2;  // 書き込み済み

  // 定型テストで見るイベント
  localparam int EV_WB   = 0;
  localparam int EV_ADDR = 1;
  localparam int EV_DATA = 2;

  // 生成のモード
  localparam int M_IDLE   = 0;
  localparam int M_RANDOM = 1;
  localparam int M_DIR    = 2;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  // ---------------- DUT ----------------

  logic rst;
  logic flush;

  logic      disp_valid_int[1];
  disp_uop_t disp_uop_int[1];
  logic      disp_full_int;
  logic      disp_valid_mem[1];
  disp_uop_t disp_uop_mem[1];
  logic      disp_full_mem;
  logic      disp_valid_fpu[1];
  disp_uop_t disp_uop_fpu[1];
  logic      disp_full_fpu;

  // unpacked 配列の要素に always から直接書くと DUT の中の組合せ回路が評価し直されないので、packed の信号から入れる
  disp_uop_t in_uop_int;
  disp_uop_t in_uop_mem;
  disp_uop_t in_uop_fpu;
  logic      in_valid_int;
  logic      in_valid_mem;
  logic      in_valid_fpu;
  assign disp_valid_int[0] = in_valid_int;
  assign disp_valid_mem[0] = in_valid_mem;
  assign disp_valid_fpu[0] = in_valid_fpu;
  assign disp_uop_int[0]   = in_uop_int;
  assign disp_uop_mem[0]   = in_uop_mem;
  assign disp_uop_fpu[0]   = in_uop_fpu;

  disp_ldq_t disp_ld[LSU_DISP_W];
  ldq_idx_t  disp_ldq_idx[LSU_DISP_W];
  logic      disp_ld_full[LSU_DISP_W];
  disp_stq_t disp_st[LSU_DISP_W];
  stq_idx_t  disp_stq_idx[LSU_DISP_W];
  logic      disp_st_full[LSU_DISP_W];
  logic      disp_br_valid[LSU_DISP_W];
  br_tag_t   disp_br_tag[LSU_DISP_W];
  for (genvar g = 0; g < LSU_DISP_W; g++) begin : g_lsu_disp
    assign disp_ld[g]       = '0;
    assign disp_st[g]       = '0;
    assign disp_br_valid[g] = 1'b0;
    assign disp_br_tag[g]   = '0;
  end

  br_update_t      br_update_ff;
  complete_t       complete_idx[5];
  complete_t       complete_st;
  logic            stq_empty;
  logic            head_load_violation;
  logic            commit_ld[COMMIT_W];
  logic            commit_st[COMMIT_W];
  for (genvar g = 0; g < COMMIT_W; g++) begin : g_commit
    assign commit_ld[g] = 1'b0;
    assign commit_st[g] = 1'b0;
  end

  logic                dc_req_valid_ff;
  logic                dc_req_we_ff;
  logic [31:0]         dc_req_addr_ff;
  logic [31:0]         dc_req_wdata_ff;
  logic [DC_TAG_W-1:0] dc_req_tag_ff;
  logic [MAX_BR-1:0]   dc_req_brmask_ff;
  logic [MAX_BR-1:0]   dc_br_kill_mask_ff;
  logic [MAX_BR-1:0]   dc_br_resolve_mask_ff;
  logic                dc_kill_all_ff;

  backend_top #(
    .LSU_DISP_W(LSU_DISP_W),
    .COMMIT_W(COMMIT_W)
  ) dut (
    .clk(clk),
    .rst(rst),
    .flush(flush),
    .disp_valid_int(disp_valid_int),
    .disp_uop_int(disp_uop_int),
    .disp_full_int(disp_full_int),
    .disp_valid_mem(disp_valid_mem),
    .disp_uop_mem(disp_uop_mem),
    .disp_full_mem(disp_full_mem),
    .disp_valid_fpu(disp_valid_fpu),
    .disp_uop_fpu(disp_uop_fpu),
    .disp_full_fpu(disp_full_fpu),
    .disp_ld(disp_ld),
    .disp_ldq_idx(disp_ldq_idx),
    .disp_ld_full(disp_ld_full),
    .disp_st(disp_st),
    .disp_stq_idx(disp_stq_idx),
    .disp_st_full(disp_st_full),
    .disp_br_valid(disp_br_valid),
    .disp_br_tag(disp_br_tag),
    .br_update_ff(br_update_ff),
    .complete_idx(complete_idx),
    .complete_st(complete_st),
    .stq_empty(stq_empty),
    .head_load_violation(head_load_violation),
    .commit_ld(commit_ld),
    .commit_st(commit_st),
    .rob_head_ld(1'b0),
    .dc_req_valid_ff(dc_req_valid_ff),
    .dc_req_we_ff(dc_req_we_ff),
    .dc_req_addr_ff(dc_req_addr_ff),
    .dc_req_wdata_ff(dc_req_wdata_ff),
    .dc_req_tag_ff(dc_req_tag_ff),
    .dc_req_brmask_ff(dc_req_brmask_ff),
    .dc_req_accepted(1'b0),
    .dc_resp_valid(1'b0),
    .dc_resp_ack(1'b0),
    .dc_resp_rdata(32'h0),
    .dc_resp_tag('0),
    .dc_br_kill_mask_ff(dc_br_kill_mask_ff),
    .dc_br_resolve_mask_ff(dc_br_resolve_mask_ff),
    .dc_kill_all_ff(dc_kill_all_ff)
  );

  // ---------------- 乱数 ----------------

  function automatic int unsigned rnd(int unsigned n);
    return $urandom_range(n - 1, 0);
  endfunction

  function automatic pc_t rnd_pc();
    case (rnd(6))
      0: return 16'h0000;
      1: return 16'hffff;
      default: return pc_t'($urandom());
    endcase
  endfunction

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

  function automatic logic alu_taken(fu_op_t op, word_t a, word_t b);
    case (op)
      FU_OP_BEQ: return a == b;
      FU_OP_BNE: return a != b;
      FU_OP_BLT: return $signed(a) < $signed(b);
      default:   return $signed(a) >= $signed(b);  // BGE
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

  // .claude/isa.md の flhi の定数表
  function automatic word_t ref_flhi(logic [4:0] ind);
    case (ind)
      5'd0:    return 32'hbe4ccccd;
      5'd1:    return 32'hbdcccccd;
      5'd2:    return 32'h38d1b717;
      5'd3:    return 32'h3c23d70a;
      5'd4:    return 32'h3c8efa35;
      5'd5:    return 32'h3d4ccccd;
      5'd6:    return 32'h3dcccccd;
      5'd7:    return 32'h3e19999a;
      5'd8:    return 32'h3e4ccccd;
      5'd9:    return 32'h3e99999a;
      5'd10:   return 32'h3f666666;
      5'd11:   return 32'h40490fdb;
      5'd12:   return 32'h4cbebc20;
      5'd13:   return 32'h4e6e6b28;
      default: return 32'h0;
    endcase
  endfunction

  function automatic word_t ref_fcsign(word_t a, logic [1:0] flag);
    case (flag)
      2'b00:   return a;
      2'b01:   return a ^ 32'h8000_0000;
      2'b10:   return a & 32'h7fff_ffff;
      default: return a | 32'h8000_0000;
    endcase
  endfunction

  function automatic int q_of(int k);
    if (k <= K_BR) return Q_INT;
    if (k >= K_LW) return Q_MEM;
    return Q_FPU;
  endfunction

  function automatic int lane_of(int k);
    if (k <= K_BR) return L_ALU;
    if (k >= K_LW) return L_MEM;
    if (k <= K_FBR) return L_FS;
    if (k <= K_FSUB) return L_FL;
    return L_FVL;
  endfunction

  function automatic string kind_name(int k);
    case (k)
      K_ADD:    return "add";
      K_ADDI:   return "addi";
      K_SUB:    return "sub";
      K_SRA:    return "sra";
      K_JAL:    return "jal";
      K_JALR:   return "jalr";
      K_BR:     return "b*";
      K_FLI:    return "fli";
      K_FLHI:   return "flhi";
      K_FCSIGN: return "fcsign";
      K_FBR:    return "fb*";
      K_FMUL:   return "fmul";
      K_ITOF:   return "itof";
      K_FTOI:   return "ftoi";
      K_FADD:   return "fadd";
      K_FSUB:   return "fsub";
      K_FSQRT:  return "fsqrt";
      K_FDIV:   return "fdiv";
      K_LW:     return "lw";
      default:  return "sw";
    endcase
  endfunction

  // ---------------- 命令の記録 ----------------

  typedef struct packed {
    int        id;     // プログラム順の番号（大きいほど若い）
    int        kind;
    int        lane;
    int        t_disp;
    int        t_wb;
    logic      done;   // 分岐：WB 済みで resolve 待ち
    preg_t     rd;
    preg_t     rs1;
    preg_t     rs2;
    word_t     value;
    rob_idx_t  rob;
    // 分岐
    logic      is_br;
    br_tag_t   tag;
    logic      mis;
    logic      taken;
    pc_t       pc;
    pc_t       target;
    // MEM
    logic      is_store;
    logic      seen_addr;
    logic      seen_data;
    addr_t     addr;
    word_t     data;
    ldq_idx_t  ldq;
    stq_idx_t  stq;
  } ins_t;

  ins_t tbl[int];  // 生きている命令

  int pst[2][NPREG];
  word_t pval[2][NPREG];
  int preaders[2][NPREG];
  int pwriter[2][NPREG];
  int pfree_at[2][NPREG];
  int recent[2][8];
  int recent_pos[2];

  int rob_owner[ROB_SIZE];
  int rob_free_at[ROB_SIZE];
  int tag_owner[MAX_BR];
  int tag_free_at[MAX_BR];
  int ldq_owner[LDQ_SIZE];
  int ldq_free_at[LDQ_SIZE];
  int stq_owner[STQ_SIZE];
  int stq_free_at[STQ_SIZE];

  int next_id;
  int mode;
  int rate;        // ランダムテストで 1 命令ごとに dispatch する確率（%）
  logic flush_en;
  logic rec_ev;    // 定型テストのイベントのサイクルを記録する

  // 定型テスト
  localparam int DIR_MAX = 32;
  int       dir_kind[DIR_MAX];
  int       dir_s1[DIR_MAX];
  int       dir_s2[DIR_MAX];
  fu_op_t   dir_op[DIR_MAX];
  imm_raw_t dir_imm[DIR_MAX];
  int       dir_id[DIR_MAX];
  preg_t    dir_rd[DIR_MAX];
  int       dir_n;
  int       dir_pos;
  int       ev_wb[int];
  int       ev_addr[int];
  int       ev_data[int];

  int unsigned cycles;
  int unsigned seed;
  int          cyc;
  int          errors;
  logic        stuck;

  // 何を確かめたかの数
  int n_disp[NK];
  int n_done[NK];
  int n_killed;
  int n_br;
  int n_mis;
  int n_two_mis;      // 同じサイクルに mispredict が 2 本
  int n_flush;
  int n_same_cycle;   // 同じサイクルに dispatch した命令の rd を読む
  int n_dir;

  task automatic fail(string msg);
    errors++;
    if (errors <= MAX_ERRORS) $display("[cycle %0d] NG: %s", cyc, msg);
  endtask

  function automatic string ins_str(ins_t e);
    return $sformatf("id=%0d %s rd=%h rs1=%h rs2=%h rob=%0d t_disp=%0d", e.id, kind_name(e.kind), e.rd, e.rs1, e.rs2,
                     e.rob, e.t_disp);
  endfunction

  function automatic int typ_i(preg_t p);
    return (p.typ == PREG_TYPE_F) ? 1 : 0;
  endfunction

  function automatic word_t val_of(preg_t p);
    if (p.typ == PREG_TYPE_NONE) return 32'h0;
    return pval[typ_i(p)][p.idx];
  endfunction

  localparam preg_t PNONE = '{typ: PREG_TYPE_NONE, idx: '0};

  // ---------------- 割り当て ----------------

  function automatic int pick_free_preg(int t);
    int c, k, n;
    c = 0;
    for (int i = 0; i < NPREG; i++) if (pst[t][i] == P_FREE && pfree_at[t][i] <= cyc) c++;
    if (c == 0) return -1;
    k = int'(rnd(c));
    n = 0;
    for (int i = 0; i < NPREG; i++) begin
      if (pst[t][i] == P_FREE && pfree_at[t][i] <= cyc) begin
        if (n == k) return i;
        n++;
      end
    end
    return -1;
  endfunction

  function automatic int pick_free(int sz, int kind);
    int c, k, n;
    logic ok;
    c = 0;
    for (int i = 0; i < sz; i++) begin
      case (kind)
        0: ok = rob_owner[i] < 0 && rob_free_at[i] <= cyc;
        1: ok = tag_owner[i] < 0 && tag_free_at[i] <= cyc;
        2: ok = ldq_owner[i] < 0 && ldq_free_at[i] <= cyc;
        default: ok = stq_owner[i] < 0 && stq_free_at[i] <= cyc;
      endcase
      if (ok) c++;
    end
    if (c == 0) return -1;
    k = int'(rnd(c));
    n = 0;
    for (int i = 0; i < sz; i++) begin
      case (kind)
        0: ok = rob_owner[i] < 0 && rob_free_at[i] <= cyc;
        1: ok = tag_owner[i] < 0 && tag_free_at[i] <= cyc;
        2: ok = ldq_owner[i] < 0 && ldq_free_at[i] <= cyc;
        default: ok = stq_owner[i] < 0 && stq_free_at[i] <= cyc;
      endcase
      if (ok) begin
        if (n == k) return i;
        n++;
      end
    end
    return -1;
  endfunction

  function automatic logic readable(int t, int i);
    return pst[t][i] == P_PEND || pst[t][i] == P_KNOWN;
  endfunction

  // ソースを選ぶ。最近 rd にしたものを多めに選んで依存を作る
  function automatic preg_t pick_src(preg_type_t typ);
    int t, c, k, n, r;
    t = (typ == PREG_TYPE_F) ? 1 : 0;
    if (rnd(20) == 0) return PNONE;
    if (rnd(10) < 6) begin
      r = recent[t][rnd(8)];
      if (r >= 0 && readable(t, r)) return '{typ: typ, idx: preg_idx_t'(r)};
    end
    c = 0;
    for (int i = 0; i < NPREG; i++) if (readable(t, i)) c++;
    if (c == 0) return PNONE;
    k = int'(rnd(c));
    n = 0;
    for (int i = 0; i < NPREG; i++) begin
      if (readable(t, i)) begin
        if (n == k) return '{typ: typ, idx: preg_idx_t'(i)};
        n++;
      end
    end
    return PNONE;
  endfunction

  function automatic brmask_t cur_brmask();
    brmask_t m;
    m = '0;
    for (int i = 0; i < MAX_BR; i++) if (tag_owner[i] >= 0) m[i] = 1'b1;
    return m;
  endfunction

  // 書き込み済みで読み手のいない物理レジスタを空ける
  task automatic free_pregs();
    int c, cand, k, n;
    for (int t = 0; t < 2; t++) begin
      for (int rep = 0; rep < 4; rep++) begin
        c = 0;
        cand = 0;
        for (int i = 0; i < NPREG; i++) begin
          if (pst[t][i] == P_FREE) c++;
          if (pst[t][i] == P_KNOWN && preaders[t][i] == 0) cand++;
        end
        if (c >= FREE_TARGET || cand == 0) break;
        k = int'(rnd(cand));
        n = 0;
        for (int i = 0; i < NPREG; i++) begin
          if (pst[t][i] == P_KNOWN && preaders[t][i] == 0) begin
            if (n == k) begin
              pst[t][i] = P_FREE;
              pfree_at[t][i] = cyc + 1;
            end
            n++;
          end
        end
      end
    end
  endtask

  task automatic release_srcs(ins_t e);
    if (e.rs1.typ != PREG_TYPE_NONE) preaders[typ_i(e.rs1)][e.rs1.idx]--;
    if (e.rs2.typ != PREG_TYPE_NONE) preaders[typ_i(e.rs2)][e.rs2.idx]--;
  endtask

  // 消える命令の後始末
  task automatic kill_ins(int id);
    ins_t e;
    e = tbl[id];
    if (e.rd.typ != PREG_TYPE_NONE && pst[typ_i(e.rd)][e.rd.idx] == P_PEND && pwriter[typ_i(e.rd)][e.rd.idx] == id) begin
      pst[typ_i(e.rd)][e.rd.idx] = P_FREE;
      pfree_at[typ_i(e.rd)][e.rd.idx] = cyc + 1;
    end
    release_srcs(e);
    rob_owner[e.rob] = -1;
    rob_free_at[e.rob] = cyc + 1;
    if (e.is_br && tag_owner[e.tag] == id) begin
      tag_owner[e.tag] = -1;
      tag_free_at[e.tag] = cyc + 1;
    end
    if (e.kind == K_LW) begin
      ldq_owner[e.ldq] = -1;
      ldq_free_at[e.ldq] = cyc + 1;
    end
    if (e.kind == K_SW) begin
      stq_owner[e.stq] = -1;
      stq_free_at[e.stq] = cyc + 1;
    end
    tbl.delete(id);
    n_killed++;
  endtask

  int kill_q[$];

  // id が a より大きい（若い）命令を全部消す
  task automatic kill_younger(int a);
    kill_q.delete();
    foreach (tbl[k]) if (k > a) kill_q.push_back(k);
    foreach (kill_q[i]) kill_ins(kill_q[i]);
  endtask

  // 終わった命令の後始末
  task automatic finish_ins(int id);
    ins_t e;
    e = tbl[id];
    release_srcs(e);
    rob_owner[e.rob] = -1;
    rob_free_at[e.rob] = cyc + 1;
    if (e.is_br) begin
      tag_owner[e.tag] = -1;
      tag_free_at[e.tag] = cyc + 1;
    end
    if (e.kind == K_LW) begin
      ldq_owner[e.ldq] = -1;
      ldq_free_at[e.ldq] = cyc + 1;
    end
    if (e.kind == K_SW) begin
      stq_owner[e.stq] = -1;
      stq_free_at[e.stq] = cyc + 1;
    end
    n_done[e.kind]++;
    tbl.delete(id);
  endtask

  // ---------------- 命令を作る ----------------

  function automatic int pick_kind();
    int sum, r;
    sum = 0;
    for (int k = 0; k < NK; k++) sum += weight[k];
    r = int'(rnd(sum));
    for (int k = 0; k < NK; k++) begin
      if (r < weight[k]) return k;
      r -= weight[k];
    end
    return K_ADDI;
  endfunction

  disp_uop_t new_uop;

  // 種類 k の命令を作って割り当てまでする。資源が足りなければ 0 を返して何もしない
  // dir >= 0 なら定型テストの dir 番目
  function automatic logic make_ins(int k, int dir);
    disp_uop_t u;
    ins_t      e;
    preg_type_t rd_typ;
    int rob_i, tag_i, lq_i, sq_i, rd_i;
    word_t a, b;
    pc_t next_pc;
    preg_type_t s2_typ;

    case (k)
      K_BR, K_FBR, K_SW, K_LW: rd_typ = PREG_TYPE_NONE;
      K_JALR: rd_typ = (dir < 0 && rnd(3) == 0) ? PREG_TYPE_NONE : PREG_TYPE_I;
      K_ADD, K_ADDI, K_SUB, K_SRA, K_JAL, K_FTOI: rd_typ = PREG_TYPE_I;
      default: rd_typ = PREG_TYPE_F;
    endcase

    rob_i = pick_free(ROB_SIZE, 0);
    if (rob_i < 0) return 1'b0;
    rd_i = 0;
    if (rd_typ != PREG_TYPE_NONE) begin
      rd_i = pick_free_preg(rd_typ == PREG_TYPE_F ? 1 : 0);
      if (rd_i < 0) return 1'b0;
    end
    tag_i = 0;
    if (k == K_BR || k == K_FBR || k == K_JALR) begin
      tag_i = pick_free(MAX_BR, 1);
      if (tag_i < 0) return 1'b0;
    end
    lq_i = 0;
    if (k == K_LW) begin
      lq_i = pick_free(LDQ_SIZE, 2);
      if (lq_i < 0) return 1'b0;
    end
    sq_i = 0;
    if (k == K_SW) begin
      sq_i = pick_free(STQ_SIZE, 3);
      if (sq_i < 0) return 1'b0;
    end

    u = '0;
    e = '0;
    e.id = next_id;
    e.kind = k;
    e.lane = lane_of(k);
    e.t_disp = cyc;
    e.rob = rob_idx_t'(rob_i);
    e.rd = (rd_typ == PREG_TYPE_NONE) ? PNONE : '{typ: rd_typ, idx: preg_idx_t'(rd_i)};
    e.rs1 = PNONE;
    e.rs2 = PNONE;
    e.pc = rnd_pc();

    // ソース
    if (dir >= 0) begin
      if (dir_s1[dir] >= 0) e.rs1 = dir_rd[dir_s1[dir]];
      if (dir_s2[dir] >= 0) e.rs2 = dir_rd[dir_s2[dir]];
      u.imm = dir_imm[dir];
    end else begin
      case (k)
        K_ADD, K_SUB, K_BR: begin
          e.rs1 = pick_src(PREG_TYPE_I);
          e.rs2 = pick_src(PREG_TYPE_I);
        end
        K_ADDI, K_SRA, K_JALR, K_ITOF, K_LW: e.rs1 = pick_src(PREG_TYPE_I);
        K_FCSIGN, K_FTOI, K_FSQRT: e.rs1 = pick_src(PREG_TYPE_F);
        K_FBR, K_FMUL, K_FADD, K_FSUB, K_FDIV: begin
          e.rs1 = pick_src(PREG_TYPE_F);
          e.rs2 = pick_src(PREG_TYPE_F);
        end
        K_SW: begin
          e.rs1 = pick_src(PREG_TYPE_I);
          s2_typ = rnd(2) ? PREG_TYPE_F : PREG_TYPE_I;
          e.rs2 = pick_src(s2_typ);
        end
        default: ;
      endcase
      u.imm = rnd_imm_raw();
    end
    a = val_of(e.rs1);
    b = val_of(e.rs2);

    // 演算の中身
    u.lat = LAT_FAST;
    u.dest_fu = 2'd0;
    case (k)
      K_ADD: begin
        u.imm_type = IMM_D;
        u.fu_op = FU_OP_ADD;
        e.value = a + b;
      end
      K_ADDI: begin
        u.imm_type = IMM_C;
        u.fu_op = FU_OP_ADDI;
        e.value = a + ref_ext(IMM_C, u.imm);
      end
      K_SUB: begin
        u.imm_type = IMM_D;
        u.fu_op = FU_OP_SUB;
        e.value = a - b;
      end
      K_SRA: begin
        u.imm_type = IMM_C;
        u.fu_op = FU_OP_SRA;
        e.value = ref_sra(a, u.imm[5:0]);
      end
      K_JAL: begin
        u.imm_type = IMM_B;
        u.fu_op = FU_OP_JAL;
        e.value = word_t'(pc_t'(e.pc + 16'd1));
      end
      K_JALR: begin
        u.imm_type = IMM_C;
        u.fu_op = FU_OP_JALR;
        e.value = word_t'(pc_t'(e.pc + 16'd1));
        e.is_br = 1'b1;
        e.taken = 1'b1;
        e.target = pc_t'(a + ref_ext(IMM_C, u.imm));
      end
      K_BR: begin
        u.imm_type = IMM_D;
        u.fu_op = (dir >= 0) ? dir_op[dir] : fu_op_t'(rnd(4));
        e.is_br = 1'b1;
        e.taken = alu_taken(u.fu_op, a, b);
        e.target = e.taken ? pc_t'(word_t'(e.pc) + ref_ext(IMM_D, u.imm)) : pc_t'(e.pc + 16'd1);
      end
      K_FLI: begin
        u.imm_type = IMM_A;
        u.fu_op = FU_OP_FLI;
        e.value = ref_ext(IMM_A, u.imm);
      end
      K_FLHI: begin
        u.imm_type = IMM_B;
        u.fu_op = FU_OP_FLHI;
        e.value = ref_flhi(u.imm[4:0]);
      end
      K_FCSIGN: begin
        u.imm_type = IMM_C;
        u.fu_op = FU_OP_FCSIGN;
        e.value = ref_fcsign(a, u.imm[1:0]);
      end
      K_FBR: begin
        u.imm_type = IMM_D;
        u.fu_op = (dir >= 0) ? dir_op[dir] : fu_op_t'(rnd(4));
        e.is_br = 1'b1;
        e.taken = fs_taken(u.fu_op, a, b);
        e.target = e.taken ? pc_t'(word_t'(e.pc) + ref_ext(IMM_D, u.imm)) : pc_t'(e.pc + 16'd1);
      end
      K_FMUL: begin
        u.dest_fu = FU_FMUL;
        u.fu_op = FU_OP_FMUL;
        u.lat = LAT_FMUL;
        e.value = m_fmul(a, b);
      end
      K_ITOF: begin
        u.dest_fu = FU_FCVT;
        u.fu_op = FU_OP_ITOF;
        u.lat = LAT_ITOF;
        e.value = m_itof(a);
      end
      K_FTOI: begin
        u.dest_fu = FU_FCVT;
        u.fu_op = FU_OP_FTOI;
        u.lat = LAT_ITOF;
        e.value = m_ftoi(a);
      end
      K_FADD: begin
        u.dest_fu = FU_FADD;
        u.fu_op = FU_OP_FADD;
        u.lat = LAT_FADD;
        e.value = m_fadd(a, b, 1'b0);
      end
      K_FSUB: begin
        u.dest_fu = FU_FADD;
        u.fu_op = FU_OP_FSUB;
        u.lat = LAT_FADD;
        e.value = m_fadd(a, b, 1'b1);
      end
      K_FSQRT: begin
        u.dest_fu = FU_FSQRT;
        u.fu_op = FU_OP_FSQRT;
        e.value = m_fsqrt(a);
      end
      K_FDIV: begin
        u.dest_fu = FU_FDIV;
        u.fu_op = FU_OP_FDIV;
        e.value = m_fdiv(a, b);
      end
      K_LW: begin
        u.imm_type = IMM_C;
        u.fu_op = FU_OP_AGU;
        e.addr = a + ref_ext(IMM_C, u.imm);
        e.ldq = ldq_idx_t'(lq_i);
      end
      default: begin  // K_SW
        u.imm_type = IMM_D;
        u.fu_op = FU_OP_AGU;
        u.is_store = 1'b1;
        e.is_store = 1'b1;
        e.addr = a + ref_ext(IMM_D, u.imm);
        e.data = b;
        e.stq = stq_idx_t'(sq_i);
      end
    endcase

    case (lane_of(k))
      L_ALU: u.dest_eu = EU_ALU;
      L_MEM: u.dest_eu = EU_MEM;
      L_FS:  u.dest_eu = EU_F_SHORT;
      L_FL:  u.dest_eu = EU_F_LONG;
      default: u.dest_eu = EU_F_VERY_LONG;
    endcase

    // 分岐の予測
    if (e.is_br) begin
      next_pc = e.target;
      e.tag = br_tag_t'(tag_i);
      if (dir < 0 && rnd(100) < 15) begin
        e.mis = 1'b1;
        u.predict_pc = next_pc + pc_t'(rnd(16'hfffe) + 1);
      end else begin
        u.predict_pc = next_pc;
      end
    end else begin
      u.predict_pc = rnd_pc();
    end

    u.rd = e.rd;
    u.rs1 = e.rs1;
    u.rs2 = e.rs2;
    u.pc = e.pc;
    u.ftq_idx = ftq_idx_t'(rnd(32));
    u.rob_idx = e.rob;
    u.brmask = cur_brmask();
    u.br_tag = e.tag;
    u.ldq_idx = e.ldq;
    u.stq_idx = e.stq;

    // 割り当てる
    if (e.rs1.typ != PREG_TYPE_NONE) begin
      preaders[typ_i(e.rs1)][e.rs1.idx]++;
      // && の右でも連想配列を読むとエントリを作るので if を分ける
      if (pst[typ_i(e.rs1)][e.rs1.idx] == P_PEND && tbl.exists(pwriter[typ_i(e.rs1)][e.rs1.idx]))
        if (tbl[pwriter[typ_i(e.rs1)][e.rs1.idx]].t_disp == cyc) n_same_cycle++;
    end
    if (e.rs2.typ != PREG_TYPE_NONE) preaders[typ_i(e.rs2)][e.rs2.idx]++;
    if (e.rd.typ != PREG_TYPE_NONE) begin
      pst[typ_i(e.rd)][e.rd.idx] = P_PEND;
      pval[typ_i(e.rd)][e.rd.idx] = e.value;
      pwriter[typ_i(e.rd)][e.rd.idx] = e.id;
      recent[typ_i(e.rd)][recent_pos[typ_i(e.rd)]] = int'(e.rd.idx);
      recent_pos[typ_i(e.rd)] = (recent_pos[typ_i(e.rd)] + 1) % 8;
    end
    rob_owner[rob_i] = e.id;
    if (e.is_br) tag_owner[tag_i] = e.id;
    if (k == K_LW) ldq_owner[lq_i] = e.id;
    if (k == K_SW) stq_owner[sq_i] = e.id;
    if (dir >= 0) begin
      dir_id[dir] = e.id;
      dir_rd[dir] = e.rd;
    end

    tbl[e.id] = e;
    next_id++;
    n_disp[k]++;
    new_uop = u;
    return 1'b1;
  endfunction

  // このサイクルの dispatch を決めて入れる
  task automatic gen_dispatch();
    logic used[3];
    logic full[3];
    int k, q, dir;
    used = '{1'b0, 1'b0, 1'b0};
    full = '{disp_full_int, disp_full_mem, disp_full_fpu};
    in_valid_int = 1'b0;
    in_valid_mem = 1'b0;
    in_valid_fpu = 1'b0;
    in_uop_int = '0;
    in_uop_mem = '0;
    in_uop_fpu = '0;
    if (mode == M_IDLE || flush) return;
    for (int slot = 0; slot < 3; slot++) begin
      if (mode == M_DIR) begin
        if (dir_pos >= dir_n) break;
        dir = dir_pos;
        k = dir_kind[dir];
      end else begin
        if (int'(rnd(100)) >= rate) break;
        dir = -1;
        k = pick_kind();
      end
      q = q_of(k);
      if (used[q] || full[q]) break;
      if (!make_ins(k, dir)) break;
      used[q] = 1'b1;
      if (mode == M_DIR) dir_pos++;
      case (q)
        Q_INT: begin
          in_valid_int = 1'b1;
          in_uop_int = new_uop;
        end
        Q_MEM: begin
          in_valid_mem = 1'b1;
          in_uop_mem = new_uop;
        end
        default: begin
          in_valid_fpu = 1'b1;
          in_uop_fpu = new_uop;
        end
      endcase
    end
  endtask

  // ---------------- 照合 ----------------

  int res_q[$];

  task automatic check_br_update();
    br_update_t u;
    ins_t e;
    int oldest, nmis, id;
    u = br_update_ff;
    if (u.mispredict !== (|u.kill_mask))
      fail($sformatf("br_update_ff.mispredict=%b なのに kill_mask=%b", u.mispredict, u.kill_mask));
    oldest = -1;
    nmis = 0;
    res_q.delete();
    for (int t = 0; t < MAX_BR; t++) begin
      if (!(u.resolve_mask[t] || u.kill_mask[t])) continue;
      if (u.resolve_mask[t] && u.kill_mask[t]) fail($sformatf("tag %0d が resolve_mask と kill_mask の両方にある", t));
      id = tag_owner[t];
      if (id < 0 || !tbl.exists(id)) begin
        fail($sformatf("br_update_ff の tag %0d（resolve=%b kill=%b）に生きている分岐が無い", t, u.resolve_mask[t],
                       u.kill_mask[t]));
        continue;
      end
      e = tbl[id];
      if (!e.done || e.t_wb != cyc - 1)
        fail($sformatf("tag %0d の分岐が WB の次のサイクル以外で resolve された（WB 済み=%b t_wb=%0d）: %s", t, e.done,
                       e.t_wb, ins_str(e)));
      if (u.kill_mask[t] !== e.mis)
        fail($sformatf("tag %0d の分岐の mispredict=%b、期待 %b: %s taken=%b target=%h", t, u.kill_mask[t], e.mis,
                       ins_str(e), e.taken, e.target));
      if (u.kill_mask[t]) begin
        nmis++;
        if (oldest < 0 || id < oldest) oldest = id;
      end
      res_q.push_back(id);
    end
    if (oldest >= 0) begin
      e = tbl[oldest];
      if (u.tag !== e.tag || u.taken !== e.taken || u.pc !== e.pc || u.target !== e.target || u.rob_idx !== e.rob)
        fail($sformatf("br_update_ff 復帰用 tag=%0d taken=%b pc=%h target=%h rob=%0d 期待 %0d %b %h %h %0d", u.tag,
                       u.taken, u.pc, u.target, u.rob_idx, e.tag, e.taken, e.pc, e.target, e.rob));
      n_mis++;
      if (nmis > 1) n_two_mis++;
    end
    foreach (res_q[i]) begin
      if (tbl.exists(res_q[i])) begin
        n_br++;
        finish_ins(res_q[i]);
      end
    end
    if (oldest >= 0) kill_younger(oldest);

    // WB したのに resolve されない分岐
    res_q.delete();
    foreach (tbl[k]) if (tbl[k].is_br && tbl[k].done && tbl[k].t_wb < cyc) res_q.push_back(k);
    foreach (res_q[i]) begin
      fail($sformatf("WB の次のサイクルに resolve されなかった: %s", ins_str(tbl[res_q[i]])));
      finish_ins(res_q[i]);
    end
  endtask

  task automatic do_flush();
    kill_q.delete();
    foreach (tbl[k]) kill_q.push_back(k);
    foreach (kill_q[i]) kill_ins(kill_q[i]);
    n_flush++;
  endtask

  task automatic check_wb_lane(int lane, complete_t c, ex_wb_t w);
    ins_t e;
    int id;
    if (c.valid !== w.valid || (w.valid && c.rob_idx !== w.rob_idx))
      fail($sformatf("complete_idx[%0d]={%b,%0d} が WB {%b,%0d} と違う", lane, c.valid, c.rob_idx, w.valid, w.rob_idx));
    if (w.valid !== 1'b1) return;
    id = rob_owner[w.rob_idx];
    if (id < 0 || !tbl.exists(id)) begin
      fail($sformatf("レーン %0d の WB rd=%h value=%h rob=%0d は生きている命令のものではない", lane, w.rd, w.value, w.rob_idx));
      return;
    end
    e = tbl[id];
    if (e.lane != lane || e.done) begin
      fail($sformatf("レーン %0d の WB（rob=%0d）が違うレーンか 2 回目: %s", lane, w.rob_idx, ins_str(e)));
      return;
    end
    if (w.rd !== e.rd) fail($sformatf("レーン %0d の WB rd=%h 期待 %h: %s", lane, w.rd, e.rd, ins_str(e)));
    else if (e.rd.typ != PREG_TYPE_NONE && w.value !== e.value)
      fail($sformatf("レーン %0d の WB value=%h 期待 %h: %s", lane, w.value, e.value, ins_str(e)));
    if (e.rd.typ != PREG_TYPE_NONE && pwriter[typ_i(e.rd)][e.rd.idx] == id) pst[typ_i(e.rd)][e.rd.idx] = P_KNOWN;
    if (rec_ev) ev_wb[id] = cyc;
    if (e.is_br) begin
      e.done = 1'b1;
      e.t_wb = cyc;
      tbl[id] = e;
    end else begin
      finish_ins(id);
    end
  endtask

  task automatic check_lsu();
    ex_lsu_t x;
    ins_t e;
    int id;
    x = dut.ex_lsu[0];
    if (!(x.addr_valid || x.data_valid)) return;
    id = x.is_store ? stq_owner[x.stq_idx] : ldq_owner[x.ldq_idx];
    if (id < 0 || !tbl.exists(id)) begin
      fail($sformatf("ex_lsu is_store=%b addr_valid=%b data_valid=%b ldq=%0d stq=%0d は生きている命令のものではない",
                     x.is_store, x.addr_valid, x.data_valid, x.ldq_idx, x.stq_idx));
      return;
    end
    e = tbl[id];
    if (!x.is_store && x.data_valid) fail($sformatf("load なのに data_valid: %s", ins_str(e)));
    if (x.addr_valid) begin
      if (e.seen_addr) fail($sformatf("アドレスが 2 回出た: %s", ins_str(e)));
      else if (x.addr !== e.addr) fail($sformatf("ex_lsu addr=%h 期待 %h: %s", x.addr, e.addr, ins_str(e)));
      e.seen_addr = 1'b1;
      if (rec_ev) ev_addr[id] = cyc;
    end
    if (x.data_valid && x.is_store) begin
      if (e.seen_data) fail($sformatf("データが 2 回出た: %s", ins_str(e)));
      else if (x.data !== e.data) fail($sformatf("ex_lsu data=%h 期待 %h: %s", x.data, e.data, ins_str(e)));
      e.seen_data = 1'b1;
      if (rec_ev) ev_data[id] = cyc;
    end
    tbl[id] = e;
    if (e.seen_addr && (!e.is_store || e.seen_data)) finish_ins(id);
  endtask

  task automatic check_stuck();
    if (stuck) return;
    foreach (tbl[k]) begin
      if (cyc - tbl[k].t_disp > STUCK_LIMIT) begin
        fail($sformatf("%0d サイクル以上終わらない: %s（ほかに生きている命令 %0d 個）", STUCK_LIMIT, ins_str(tbl[k]),
                       tbl.size()));
        stuck = 1'b1;
        return;
      end
    end
  endtask

  // ---------------- 1 サイクル ----------------

  task automatic tick();
    @(negedge clk);
    cyc++;
    check_br_update();
    flush = (mode == M_RANDOM) && flush_en && (rnd(FLUSH_RATE) == 0);
    if (flush) do_flush();
    free_pregs();
    gen_dispatch();
    #1;
    check_wb_lane(L_ALU, complete_idx[0], dut.wb_alu[0]);
    check_wb_lane(L_FS, complete_idx[2], dut.wb_fpu[0]);
    check_wb_lane(L_FL, complete_idx[3], dut.wb_fpu[1]);
    check_wb_lane(L_FVL, complete_idx[4], dut.wb_fpu[2]);
    check_lsu();
    if (cyc % 64 == 0) check_stuck();
  endtask

  task automatic drain(string what);
    int n;
    mode = M_IDLE;
    n = 0;
    while (tbl.size() != 0 && !stuck) begin
      tick();
      n++;
      if (n > STUCK_LIMIT * 2) begin
        fail($sformatf("%s: 終わらない命令が %0d 個残った", what, tbl.size()));
        stuck = 1'b1;
      end
    end
    // 空けたものを使えるようにしておく
    tick();
    tick();
  endtask

  // ---------------- 定型テスト ----------------

  function automatic int dir_add(int k, int s1, int s2, fu_op_t op, imm_raw_t imm);
    dir_kind[dir_n] = k;
    dir_s1[dir_n] = s1;
    dir_s2[dir_n] = s2;
    dir_op[dir_n] = op;
    dir_imm[dir_n] = imm;
    dir_n++;
    return dir_n - 1;
  endfunction

  function automatic int ev_of(int d, int ev);
    int id;
    id = dir_id[d];
    case (ev)
      EV_WB:   return ev_wb.exists(id) ? ev_wb[id] : -1000000;
      EV_ADDR: return ev_addr.exists(id) ? ev_addr[id] : -1000000;
      default: return ev_data.exists(id) ? ev_data[id] : -1000000;
    endcase
  endfunction

  function automatic string ev_name(int ev);
    case (ev)
      EV_WB:   return "WB";
      EV_ADDR: return "アドレス";
      default: return "データ";
    endcase
  endfunction

  // p を c が読む 2 命令を流して、イベントの間隔が gap になるか見る
  task automatic dir_pair(int kp, int kc, int c_src, int ev_c, int gap, imm_raw_t imm_c);
    int p, c, tp, tc;
    dir_n = 0;
    dir_pos = 0;
    ev_wb.delete();
    ev_addr.delete();
    ev_data.delete();
    p = dir_add(kp, -1, -1, FU_OP_BEQ, 20'h00011);
    if (c_src == 1) c = dir_add(kc, p, -1, FU_OP_BEQ, imm_c);
    else c = dir_add(kc, -1, p, FU_OP_BEQ, imm_c);
    mode = M_DIR;
    while (dir_pos < dir_n) tick();
    drain("定型テスト");
    tp = ev_of(p, EV_WB);
    tc = ev_of(c, ev_c);
    n_dir++;
    if (tc - tp != gap)
      fail($sformatf("%s→%s（%s）の間隔 %0d、期待 %0d（%s の WB %0d、%s の%s %0d）", kind_name(kp), kind_name(kc),
                     ev_name(ev_c), tc - tp, gap, kind_name(kp), tp, kind_name(kc), ev_name(ev_c), tc));
  endtask

  // 依存の鎖を n 本流して、WB が毎サイクル続くか見る
  task automatic dir_chain(int k, int n, int gap);
    int prev, cur, tp, tc;
    dir_n = 0;
    dir_pos = 0;
    ev_wb.delete();
    prev = dir_add(k, -1, -1, FU_OP_BEQ, 20'h00003);
    for (int i = 1; i < n; i++) begin
      cur = dir_add(k, prev, -1, FU_OP_BEQ, 20'h00005);
      prev = cur;
    end
    mode = M_DIR;
    while (dir_pos < dir_n) tick();
    drain("定型テスト");
    for (int i = 1; i < n; i++) begin
      tp = ev_of(i - 1, EV_WB);
      tc = ev_of(i, EV_WB);
      n_dir++;
      if (tc - tp != gap)
        fail($sformatf("%s の鎖の %0d 番目の間隔 %0d、期待 %0d", kind_name(k), i, tc - tp, gap));
    end
  endtask

  task automatic run_directed();
    $display("定型テスト");
    rec_ev = 1'b1;
    dir_chain(K_ADDI, 8, 1);
    dir_chain(K_FCSIGN, 6, 1);
    dir_chain(K_FMUL, 5, 2);
    dir_chain(K_FADD, 4, 4);
    dir_pair(K_FLI, K_FCSIGN, 1, EV_WB, 1, 20'h00001);
    dir_pair(K_FMUL, K_FMUL, 1, EV_WB, 2, '0);
    dir_pair(K_ITOF, K_FADD, 2, EV_WB, 3, '0);
    dir_pair(K_FADD, K_FMUL, 1, EV_WB, 4, '0);
    dir_pair(K_FMUL, K_FCSIGN, 1, EV_WB, -1, 20'h00001);
    dir_pair(K_FTOI, K_ADDI, 1, EV_WB, 0, 20'h00007);
    dir_pair(K_ADDI, K_ITOF, 1, EV_WB, 4, '0);
    dir_pair(K_FMUL, K_FTOI, 1, EV_WB, 2, '0);
    dir_pair(K_FTOI, K_ITOF, 1, EV_WB, 3, '0);
    dir_pair(K_ADDI, K_BR, 1, EV_WB, 1, 20'h00010);
    dir_pair(K_FADD, K_FBR, 2, EV_WB, 1, 20'h00010);
    dir_pair(K_ADDI, K_SW, 1, EV_ADDR, 1, 20'h00004);
    dir_pair(K_FLI, K_SW, 2, EV_DATA, 1, 20'h00004);
    dir_pair(K_FMUL, K_SW, 2, EV_DATA, -1, 20'h00004);
    dir_pair(K_FTOI, K_SW, 2, EV_DATA, 0, 20'h00004);
    dir_pair(K_ADDI, K_LW, 1, EV_ADDR, 1, 20'h00004);
    dir_pair(K_FTOI, K_LW, 1, EV_ADDR, 0, 20'h00004);
    dir_pair(K_FSQRT, K_FADD, 1, EV_WB, 6, '0);
    dir_pair(K_FDIV, K_FCSIGN, 1, EV_WB, 3, 20'h00002);
    dir_pair(K_FSQRT, K_SW, 2, EV_DATA, 3, 20'h00004);
    rec_ev = 1'b0;
  endtask

  // ---------------- 本体 ----------------

  initial begin
    if (!$value$plusargs("cycles=%d", cycles)) cycles = 200000;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    $display("backend_top: seed=%0d cycles=%0d", seed, cycles);

    rst = 1'b1;
    flush = 1'b0;
    in_valid_int = 1'b0;
    in_valid_mem = 1'b0;
    in_valid_fpu = 1'b0;
    in_uop_int = '0;
    in_uop_mem = '0;
    in_uop_fpu = '0;
    cyc = 0;
    errors = 0;
    stuck = 1'b0;
    next_id = 0;
    mode = M_IDLE;
    rate = 100;
    flush_en = 1'b0;
    rec_ev = 1'b0;
    for (int t = 0; t < 2; t++) begin
      for (int i = 0; i < NPREG; i++) begin
        pst[t][i] = P_FREE;
        pval[t][i] = '0;
        preaders[t][i] = 0;
        pwriter[t][i] = -1;
        pfree_at[t][i] = 0;
      end
      for (int i = 0; i < 8; i++) recent[t][i] = -1;
      recent_pos[t] = 0;
    end
    for (int i = 0; i < ROB_SIZE; i++) begin
      rob_owner[i] = -1;
      rob_free_at[i] = 0;
    end
    for (int i = 0; i < MAX_BR; i++) begin
      tag_owner[i] = -1;
      tag_free_at[i] = 0;
    end
    for (int i = 0; i < LDQ_SIZE; i++) begin
      ldq_owner[i] = -1;
      ldq_free_at[i] = 0;
    end
    for (int i = 0; i < STQ_SIZE; i++) begin
      stq_owner[i] = -1;
      stq_free_at[i] = 0;
    end
    for (int k = 0; k < NK; k++) begin
      n_disp[k] = 0;
      n_done[k] = 0;
    end
    n_killed = 0;
    n_br = 0;
    n_mis = 0;
    n_two_mis = 0;
    n_flush = 0;
    n_same_cycle = 0;
    n_dir = 0;

    // rst は最初の 3 サイクル
    repeat (3) @(negedge clk);
    rst = 1'b0;

    run_directed();

    // ランダム。dispatch の頻度を 1000 サイクルごとに変える
    $display("ランダムテスト");
    mode = M_RANDOM;
    flush_en = 1'b1;
    for (int i = 0; i < int'(cycles) && !stuck; i++) begin
      if (i % 1000 == 0) begin
        case (rnd(3))
          0: rate = 100;
          1: rate = 70;
          default: rate = 30;
        endcase
      end
      tick();
    end
    flush_en = 1'b0;
    drain("ランダムテストの後");

    $display("定型テストの間隔 %0d 個", n_dir);
    for (int k = 0; k < NK; k++)
      $display("  %s dispatch %0d / 終わった %0d", kind_name(k), n_disp[k], n_done[k]);
    $display("  分岐の resolve %0d、mispredict %0d（同じサイクルに 2 本 %0d）、flush %0d、消えた命令 %0d", n_br, n_mis,
             n_two_mis, n_flush, n_killed);
    $display("  同じサイクルに dispatch した命令の rd を読んだ %0d", n_same_cycle);
    if (errors == 0) $display("PASS");
    else $display("FAIL: %0d 個", errors);
    $finish;
  end

endmodule

`default_nettype wire
