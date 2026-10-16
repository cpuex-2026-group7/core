#pragma once

#include <cstdint>
#include <cstdio>

// Kanata v4. Shadow instruction IDs follow the enables/flushes in inter_stage_regs.sv.
// Each sample describes the stages BEFORE the rising edge, just like commit DPI.
class KonataTrace {
 public:
  void open(FILE *fp) {
    fp_ = fp;
    std::fprintf(fp_, "Kanata\t0004\nC=\t0\n");
  }

  void sample(uint32_t pc, uint32_t instr, bool stall_f, bool stall_d,
              bool flush_d, bool flush_e) {
    if(!fp_) return;
    if(sampled_) {
      boundary();
      retire(4, false);
      move(3, 4);
      move(2, 3);
      if(flush_d_) retire(1, true);
      else if(!flush_e_) move(1, 2);
      else if(!stall_d_) retire(1, true);
      if(flush_d_) retire(0, true);
      else if(!stall_d_) move(0, 1);
    }
    if(ids_[0] == empty) {
      ids_[0] = next_id_++;
      std::fprintf(fp_, "I\t%llu\t%llu\t0\nL\t%llu\t0\tpc=%08x instr=%08x\n",
                   ids_[0], ids_[0], ids_[0], pc, instr);
      stage('S', 0);
    }
    stalled_[0] = stall_f;
    stalled_[1] = stall_d;
    for(int s = 0; s < 2; ++s)
      if(stalled_[s] && ids_[s] != empty)
        std::fprintf(fp_, "S\t%llu\t1\tstall\n", ids_[s]);
    stall_d_ = stall_d;
    flush_d_ = flush_d;
    flush_e_ = flush_e;
    sampled_ = true;
  }

  void reg_write(int idx, uint32_t value) {
    if(fp_ && ids_[4] != empty)
      std::fprintf(fp_, "L\t%llu\t1\t%c%02u=%08x\\n\n", ids_[4],
                   idx < 32 ? 'x' : 'f', unsigned(idx) % 32, value);
  }
  void mem_write(uint32_t addr, uint32_t value) {
    if(fp_ && ids_[3] != empty)
      std::fprintf(fp_, "L\t%llu\t1\tM[%08x]=%08x\\n\n", ids_[3], addr, value);
  }

  // The last sampled WB instruction has completed; younger instructions have not.
  // Close every record even on timeout, explicitly labeling truncated instructions.
  void finish(bool halted) {
    if(!fp_) return;
    if(sampled_) {
      boundary();
      retire(4, false);
      for(int s = 0; s < 4; ++s) {
        if(ids_[s] != empty)
          std::fprintf(fp_, "L\t%llu\t1\t%s\n", ids_[s],
                       halted ? "simulation stopped at halt" : "simulation truncated");
        retire(s, true);
      }
    }
    fp_ = nullptr;  // FILE ownership stays with the caller.
  }

 private:
  using Id = unsigned long long;
  static constexpr Id empty = ~Id{0};
  FILE *fp_ = nullptr;
  Id ids_[5] = {empty, empty, empty, empty, empty};
  Id next_id_ = 0, next_retire_ = 0;
  bool sampled_ = false, stall_d_ = false, flush_d_ = false, flush_e_ = false;
  bool stalled_[2] = {false, false};

  void stage(char command, int s) {
    static const char *names[] = {"IF", "ID", "EX", "MEM", "WB"};
    std::fprintf(fp_, "%c\t%llu\t0\t%s\n", command, ids_[s], names[s]);
  }
  void boundary() {
    std::fprintf(fp_, "C\t1\n");
    for(int s = 0; s < 2; ++s)
      if(stalled_[s] && ids_[s] != empty)
        std::fprintf(fp_, "E\t%llu\t1\tstall\n", ids_[s]);
  }
  void retire(int s, bool flushed) {
    if(ids_[s] == empty) return;
    stage('E', s);
    std::fprintf(fp_, "R\t%llu\t%llu\t%d\n", ids_[s], next_retire_, flushed ? 1 : 0);
    if(!flushed) ++next_retire_;
    ids_[s] = empty;
  }
  void move(int from, int to) {
    if(ids_[from] == empty) return;
    stage('E', from);
    ids_[to] = ids_[from];
    ids_[from] = empty;
    stage('S', to);
    // A held halt in ID can be copied into EX repeatedly by RTL. Track its first
    // execution only; the copies behind it never complete before simulation stops.
  }
};
