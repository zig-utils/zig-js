.text
.p2align 2
.globl _ZJSObjCNativeInvokeAsm
_ZJSObjCNativeInvokeAsm:
    .cfi_startproc
    stp x29, x30, [sp, #-32]!
    .cfi_def_cfa_offset 32
    .cfi_offset x29, -32
    .cfi_offset x30, -24
    stp x19, x20, [sp, #16]
    .cfi_offset x19, -16
    .cfi_offset x20, -8
    mov x29, sp
    .cfi_def_cfa_register x29
    mov x19, x0

    ldr x20, [x19, #16]
    sub sp, sp, x20
    ldr x9, [x19, #8]
    mov x10, sp
    mov x11, x20
L_zjs_arm64_copy_stack:
    cbz x11, L_zjs_arm64_stack_done
    ldr x12, [x9], #8
    str x12, [x10], #8
    sub x11, x11, #8
    b L_zjs_arm64_copy_stack
L_zjs_arm64_stack_done:
    ldr x8, [x19, #24]
    ldp x0, x1, [x19, #32]
    ldp x2, x3, [x19, #48]
    ldp x4, x5, [x19, #64]
    ldp x6, x7, [x19, #80]
    ldp q0, q1, [x19, #96]
    ldp q2, q3, [x19, #128]
    ldp q4, q5, [x19, #160]
    ldp q6, q7, [x19, #192]
    ldr x16, [x19]
    blr x16
    stp x0, x1, [x19, #224]
    stp q0, q1, [x19, #240]
    stp q2, q3, [x19, #272]

    mov sp, x29
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
    .cfi_endproc
