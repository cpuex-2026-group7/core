`timescale 1ns / 1ps
`default_nettype none

// eu_4_top のテストで使う演算器の代わりの中身
// FPU 担当の実装ができるまでの仮のもので、EU の調停と kill を確かめるためだけに使う。
// 結果は整数の演算で適当に作っている（float の計算ではない）。
// サイクル数はオペランドで変えて、fsqrt と fdiv が同じサイクルに終わる場合を作る。
package eu_4_model_pkg;
  import types::*;

  // issued のサイクルから done のサイクルまでのサイクル数
  function automatic int lat_fsqrt(word_t a);
    return 3 + int'(a[3:0]);
  endfunction

  function automatic int lat_fdiv(word_t a, word_t b);
    return 3 + int'(a[3:0] ^ b[7:4]);
  endfunction

  function automatic word_t m_fsqrt(word_t a);
    return {a[15:0], a[31:16]} + 32'h0000_1001;
  endfunction

  function automatic word_t m_fdiv(word_t a, word_t b);
    return a ^ (b << 3) ^ 32'hC3C3_0000;
  endfunction
endpackage

`default_nettype wire
