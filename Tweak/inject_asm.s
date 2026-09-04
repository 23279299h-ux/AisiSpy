// 纯汇编constructor：用ARM64系统调用写文件
// 位置无关代码，不依赖任何C库函数
.text
.align 2
.globl _inject_constructor
_inject_constructor:
    // 保存寄存器
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #32

    // open("/tmp/aisi_inject_test.txt", O_WRONLY|O_CREAT|O_TRUNC, 0644)
    adr x0, L_path_str       // x0 = 路径字符串地址（位置无关）
    mov x1, #0x241           // O_WRONLY(1)|O_CREAT(0x200)|O_TRUNC(0x400) = 0x241
    mov x2, #0x1a4           // 0644 octal = 420 decimal = 0x1a4
    mov x16, #5              // syscall: open = 5
    svc #0x80                // 触发系统调用

    mov x20, x0              // 保存fd到x20

    // write(fd, "inject OK\n", 10)
    adr x1, L_msg_str        // x1 = 消息字符串地址
    mov x2, #10              // 长度
    mov x0, x20              // fd
    mov x16, #4              // syscall: write = 4
    svc #0x80

    // close(fd)
    mov x0, x20
    mov x16, #6              // syscall: close = 6
    svc #0x80

    // 恢复寄存器并返回
    add sp, sp, #32
    ldp x29, x30, [sp], #16
    ret

L_path_str:
    .asciz "/tmp/aisi_inject_test.txt"
    .align 2
L_msg_str:
    .asciz "inject OK\n"
    .align 2
