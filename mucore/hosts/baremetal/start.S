/* AArch64 bare-metal entry for muinference (Stage B).
 *
 * QEMU 'virt' with -kernel enters here at EL1 (or EL2 when virtualisation is
 * enabled) with the MMU off and caches in an implementation-defined state.
 * We only need three things before C can run: floating point ungated, a stack,
 * and a zeroed .bss. No MMU, no interrupts, no other cores.
 */
    .section .text.boot, "ax"
    .global _start
    .type _start, %function
_start:
    /* Park every core but the first. QEMU starts one CPU by default; this is
     * cheap insurance so a stray secondary cannot corrupt the arena. */
    mrs     x0, mpidr_el1
    and     x0, x0, #0xFF
    cbz     x0, 1f
0:  wfe
    b       0b
1:

    /* Ungate the FPU/SIMD at whatever exception level we booted into.
     * CPACR_EL1.FPEN and CPTR_EL2/EL3 are architecturally UNKNOWN at reset,
     * so this must be explicit or the first float instruction traps. */
    mrs     x0, CurrentEL
    lsr     x0, x0, #2
    cmp     x0, #3
    b.eq    el3
    cmp     x0, #2
    b.eq    el2
    b       el1

el3:
    msr     cptr_el3, xzr          /* no FP/SVE trapping at EL3 */
    msr     cptr_el2, xzr
    b       el1
el2:
    msr     cptr_el2, xzr          /* TFP=0: FP usable below EL2 */
el1:
    mrs     x0, cpacr_el1
    orr     x0, x0, #(3 << 20)     /* FPEN=0b11: never trap FP/SIMD */
    msr     cpacr_el1, x0
    isb

    /* Stack. Grows down from __stack_top provided by the linker script. */
    adrp    x0, __stack_top
    add     x0, x0, :lo12:__stack_top
    mov     sp, x0

    /* ---- identity-map the low 4 GiB and turn on caches ----------------
     * With the MMU off, ARMv8 treats every access as Device-nGnRnE: uncached
     * and strictly ordered. Zeroing a multi-megabyte arena in that state is
     * pathologically slow (it hangs for minutes under TCG), and the inference
     * loop would be worse. So we build a 4-entry level-1 table using 1 GiB
     * blocks, mark RAM Normal Write-Back, and enable M/C/I.
     *
     * TCR_EL1.T0SZ=32 gives a 32-bit VA with a 4 KiB granule, which starts
     * translation at level 1 where each entry covers 1 GiB. Four entries
     * cover 0x0 - 0xFFFFFFFF: entry 0 is Device (MMIO), entries 1..3 Normal
     * (QEMU virt puts RAM at 0x40000000). */
    adrp    x0, __l1_table
    add     x0, x0, :lo12:__l1_table

    /* Block descriptor common bits: AF(10) | SH=inner(9:8) | AP=RW_EL1(7:6)=0
     *                             | AttrIndx(4:2) | type=block(1)=0 | valid(0) */
    mov     x1, #(1 << 10) | (3 << 8) | 1      /* AF | SH inner | valid  */

    /* entry 0: 0x00000000, Device, AttrIndx=1 -> no SH for device */
    mov     x2, #(1 << 10) | (1 << 2) | 1
    str     x2, [x0, #0]

    /* entries 1..3: Normal WB, AttrIndx=0, output addr = index << 30 */
    mov     x3, #1
2:  lsl     x4, x3, #30                        /* output address */
    orr     x4, x4, x1
    lsl     x5, x3, #3
    str     x4, [x0, x5]
    add     x3, x3, #1
    cmp     x3, #4
    b.lo    2b

    /* MAIR: attr0 = 0xFF Normal WB RW-alloc, attr1 = 0x00 Device-nGnRnE */
    mov     x1, #0x00FF
    msr     mair_el1, x1

    /* TCR_EL1: T0SZ=32, IRGN0=WB, ORGN0=WB, SH0=inner, TG0=4K, IPS=40bit */
    ldr     x1, =((32) | (1 << 8) | (1 << 10) | (3 << 12) | (2ULL << 32))
    msr     tcr_el1, x1

    msr     ttbr0_el1, x0
    dsb     ish
    isb
    tlbi    vmalle1
    dsb     ish
    isb

    mrs     x1, sctlr_el1
    orr     x1, x1, #(1 << 0)                  /* M: MMU enable            */
    orr     x1, x1, #(1 << 2)                  /* C: data cache enable     */
    orr     x1, x1, #(1 << 12)                 /* I: instruction cache     */
    msr     sctlr_el1, x1
    dsb     sy
    isb

    /* Zero .bss -- the arena lives there, and mu_arena_alloc assumes it can
     * hand out zeroed memory. Fast now that the region is cacheable. */
    adrp    x0, __bss_start
    add     x0, x0, :lo12:__bss_start
    adrp    x1, __bss_end
    add     x1, x1, :lo12:__bss_end
2:  cmp     x0, x1
    b.hs    3f
    str     xzr, [x0], #8
    b       2b
3:

    bl      mu_bm_main

    /* Fall through to a semihosting exit if main returns. */
    mov     x1, #0
    b       mu_bm_exit
    .size _start, . - _start

/* ---- ARM semihosting primitive --------------------------------------
 * long mu_sh_call(long op, void *args);
 * The HLT encoding is the AArch64 semihosting trap. QEMU intercepts it when
 * started with -semihosting, which is how the guest reaches the host
 * filesystem to write the logits dump we hash externally.
 */
    .section .text, "ax"
    .global mu_sh_call
    .type mu_sh_call, %function
mu_sh_call:
    hlt     #0xF000
    ret
    .size mu_sh_call, . - mu_sh_call

/* void mu_bm_exit(int code) -- ADP_Stopped_ApplicationExit */
    .global mu_bm_exit
    .type mu_bm_exit, %function
mu_bm_exit:
    mov     x2, x0
    adrp    x1, __exit_block
    add     x1, x1, :lo12:__exit_block
    mov     x0, #0x26
    movk    x0, #0x2, lsl #16      /* 0x20026 */
    str     x0, [x1]
    str     x2, [x1, #8]
    mov     x0, #0x18              /* SYS_EXIT */
    hlt     #0xF000
4:  wfi
    b       4b
    .size mu_bm_exit, . - mu_bm_exit

/* The level-1 translation table must exist before .bss is zeroed, so it lives
 * in .data (loaded from the image) rather than .bss. 4 KiB, page aligned. */
    .section .data, "aw"
    .balign 4096
    .global __l1_table
__l1_table:
    .space 4096

    .section .bss, "aw", %nobits
    .align 3
__exit_block:
    .space 16
