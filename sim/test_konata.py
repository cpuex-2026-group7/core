"""Run with python3 sim/test_konata.py; requires a C++17 compiler, not Verilator."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


HARNESS = r'''
#include "konata_trace.h"
int main(int argc, char **argv) {
  KonataTrace trace;
  trace.open(stdout);
  const char mode = argv[1][0];
  for(unsigned c = 0; c < 9; ++c) {
    bool stall = (mode == 's' && (c == 2 || c == 3)) || (mode == 'h' && c >= 1);
    bool branch = mode == 'b' && c == 2;
    trace.sample(c, 0x32000000 + c, stall, stall, branch,
                 branch || (mode == 's' && stall));
    if(c == 3) trace.mem_write(0x123, 0x456);
    if(c == 4) trace.reg_write(3, 42);
    if(mode == 'h' && c == 4) break;
  }
  trace.finish(mode == 'h');
}
'''


class KonataTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        source = Path(cls.tmp.name) / 'trace.cpp'
        source.write_text(HARNESS)
        cls.exe = str(Path(cls.tmp.name) / 'trace')
        subprocess.run(shlex.split(os.environ.get('CXX', 'c++')) + [
            '-std=c++17', '-Wall', '-Wextra', '-Wno-unused-parameter',
            '-I', str(Path(__file__).resolve().parent), str(source), '-o', cls.exe,
        ], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def read_trace(self, mode):
        lines = subprocess.check_output([self.exe, mode], text=True).splitlines()
        self.assertEqual(lines.pop(0), 'Kanata\t0004')
        cycle, live, stages, history, retired, labels = 0, set(), {}, {}, {}, []
        retirement_id = 0
        for line in lines:
            fields = line.split('\t')
            command = fields[0]
            if command == 'C=':
                cycle = int(fields[1])
            elif command == 'C':
                self.assertGreater(int(fields[1]), 0)
                cycle += int(fields[1])
            elif command == 'I':
                ident = int(fields[1])
                self.assertNotIn(ident, history)
                live.add(ident)
                history[ident] = []
            else:
                ident = int(fields[1])
                self.assertIn(ident, live)
                if command in ('S', 'E'):
                    key = (ident, fields[2])
                    if command == 'S':
                        self.assertNotIn(key, stages)
                        stages[key] = (fields[3], cycle)
                        history[ident].append((fields[3], cycle))
                    else:
                        name, start = stages.pop(key)
                        self.assertEqual(name, fields[3])
                        self.assertGreater(cycle, start)
                elif command == 'R':
                    self.assertFalse(any(k[0] == ident for k in stages))
                    self.assertEqual(int(fields[2]), retirement_id)
                    retired[ident] = (int(fields[3]), cycle)
                    if fields[3] == '0':
                        retirement_id += 1
                    live.remove(ident)
                elif command == 'L':
                    labels.append((ident, fields[3]))
                else:
                    self.fail(f'Unexpected command: {command}')
        self.assertFalse(live)
        self.assertFalse(stages)
        return history, retired, labels

    def test_straight_pipeline_and_commit_labels(self):
        history, retired, labels = self.read_trace('normal')
        self.assertEqual(history[0], [('IF', 0), ('ID', 1), ('EX', 2), ('MEM', 3), ('WB', 4)])
        self.assertEqual(retired[0], (0, 5))
        self.assertIn((0, 'M[00000123]=00000456\\n'), labels)
        self.assertIn((0, 'x03=0000002a\\n'), labels)
        self.assertIn((8, 'simulation truncated'), labels)

    def test_load_use_stall_holds_identity(self):
        history, retired, _ = self.read_trace('stall')
        self.assertEqual([x for x in history[1] if x[0] != 'stall'],
                         [('IF', 1), ('ID', 2), ('EX', 5), ('MEM', 6), ('WB', 7)])
        self.assertEqual(retired[1], (0, 8))
        self.assertIn(('stall', 2), history[2])
        self.assertIn(('stall', 3), history[2])

    def test_branch_flushes_only_younger_instructions(self):
        history, retired, _ = self.read_trace('branch')
        self.assertEqual(retired[0], (0, 5))
        self.assertEqual(retired[1], (1, 3))
        self.assertEqual(retired[2], (1, 3))
        self.assertEqual(history[3][0], ('IF', 3))

    def test_held_halt_is_not_duplicated(self):
        history, retired, labels = self.read_trace('halt')
        self.assertEqual(set(history), {0, 1})
        self.assertEqual(retired[0], (0, 5))
        self.assertEqual(retired[1], (1, 5))
        self.assertIn((1, 'simulation stopped at halt'), labels)


if __name__ == '__main__':
    unittest.main()
