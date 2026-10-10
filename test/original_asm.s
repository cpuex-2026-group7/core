# spをx1,戻りアドレスをx2,引数をx3,retをx4とする
    addi x1 x0 1023
    addi x3 x0 10
    jal x2 fib
    halt
fib:
    addi x5 x0 2
    add x4 x3 x0
    blt x3 x5 end  # n<2

    addi x1 x1 -3
    sw x2 2(x1)
    sw x3 1(x1)
    addi x3 x3 -1
    jal x2 fib # fib(n-1)

    sw x4 0(x1)
    lw x3 1(x1)
    addi x3 x3 -2
    jal x2 fib # fib(n-2)

    lw x5 0(x1)
    add x4 x4 x5

    lw x2 2(x1)
    addi x1 x1 3
end:
    jalr x0 x2 0
