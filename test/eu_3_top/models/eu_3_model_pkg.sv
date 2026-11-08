`timescale 1ns / 1ps
`default_nettype none

// eu_3_top のテストで使う演算器の代わりの中身
// FPU 担当の実装ができるまでの仮のもので、EU の配線と段数を確かめるためだけに使う。
// 命令ごとに結果が違うように、整数の演算で適当に作っている（float の計算ではない）。
package eu_3_model_pkg;
  import types::*;

  function automatic word_t m_fmul(word_t a, word_t b);
    return a * b + 32'h1357_9BDF;
  endfunction

  function automatic word_t m_itof(word_t a);
    return {a[7:0], a[31:8]} ^ 32'h5A5A_5A5A;
  endfunction

  function automatic word_t m_ftoi(word_t a);
    return ~a + 32'd3;
  endfunction

  function automatic word_t m_fadd(word_t a, word_t b, logic sub);
    return sub ? a - b : a + b;
  endfunction
endpackage

`default_nettype wire
