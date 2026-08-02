.text
.p2align 4, 0x90
.globl _ZJSObjCNativeInvokeAsm
_ZJSObjCNativeInvokeAsm:
    .cfi_startproc
    pushq %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset %rbp, -16
    movq %rsp, %rbp
    .cfi_def_cfa_register %rbp
    pushq %rbx
    .cfi_offset %rbx, -24
    pushq %r12
    .cfi_offset %r12, -32
    movq %rdi, %rbx

    movq 16(%rbx), %r12
    subq %r12, %rsp
    movq 8(%rbx), %rsi
    movq %rsp, %rdi
    movq %r12, %rcx
    shrq $3, %rcx
    rep movsq

    movq 32(%rbx), %rdi
    movq 40(%rbx), %rsi
    movq 48(%rbx), %rdx
    movq 56(%rbx), %rcx
    movq 64(%rbx), %r8
    movq 72(%rbx), %r9
    movdqu 96(%rbx), %xmm0
    movdqu 112(%rbx), %xmm1
    movdqu 128(%rbx), %xmm2
    movdqu 144(%rbx), %xmm3
    movdqu 160(%rbx), %xmm4
    movdqu 176(%rbx), %xmm5
    movdqu 192(%rbx), %xmm6
    movdqu 208(%rbx), %xmm7
    callq *(%rbx)
    movq %rax, 224(%rbx)
    movq %rdx, 232(%rbx)
    movdqu %xmm0, 240(%rbx)
    movdqu %xmm1, 256(%rbx)
    movdqu %xmm2, 272(%rbx)
    movdqu %xmm3, 288(%rbx)

    leaq -16(%rbp), %rsp
    popq %r12
    popq %rbx
    popq %rbp
    retq
    .cfi_endproc
