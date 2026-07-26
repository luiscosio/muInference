/* x86-64 multiboot entry for muinference (Stage B2, cross-ISA verification).
 *
 * Purpose: prove the reproducibility claim on a genuinely different floating
 * point implementation. On the aarch64 host, QEMU runs guest FP on the Apple
 * Silicon FPU. Here, QEMU's x86 TCG backend evaluates SSE with its own
 * softfloat library. If the logits still match bit for bit, the IEEE-754
 * argument in mu_math.h holds across independent FP implementations rather
 * than across two views of the same hardware.
 *
 * QEMU -kernel enters a multiboot ELF in 32-bit protected mode with paging off.
 * Long mode requires paging, so we build a minimal identity map (2 MiB pages
 * covering the low 4 GiB via four PDPT entries pointing at 1 GiB pages),
 * enable PAE + LME, then far-jump into 64-bit code.
 */

/* ---- PVH entry note -------------------------------------------------
 * QEMU's multiboot loader rejects ELF64 outright ("Cannot load x86-64 image,
 * give a 32bit one"), because multiboot is a 32-bit protocol. The supported
 * way to direct-boot a 64-bit ELF is the PVH protocol: QEMU looks for
 * XEN_ELFNOTE_PHYS32_ENTRY (type 18) in a PT_NOTE segment and, if present,
 * enters that address in 32-bit protected mode with paging off -- which is
 * precisely the state _start expects.
 *
 * Note there is deliberately NO multiboot header here. QEMU checks for the
 * multiboot magic first, and finding it commits to the multiboot path, which
 * then fails on the ELF class before PVH is ever considered. Having both is
 * strictly worse than having only the note.
 */
    .section .note.Xen, "a", %note
    .align 4
    .long 4                             /* namesz: "Xen\0"                */
    .long 4                             /* descsz: one 32-bit address     */
    .long 18                            /* XEN_ELFNOTE_PHYS32_ENTRY       */
    .asciz "Xen"
    .align 4
    .long _start

/* ---- 32-bit entry --------------------------------------------------- */
    .section .text.boot, "ax"
    .code32
    .global _start
_start:
    cli
    movl    $stack_top, %esp

    /* Zero the two page-table pages before use. They live in .bss, which is
     * not cleared until we are in long mode, so without this the unused PML4
     * entries would hold garbage with possibly-set present bits. */
    movl    $pml4, %edi
    movl    $2048, %ecx                 /* 2 pages / 4 bytes per store    */
    xorl    %eax, %eax
    cld
    rep stosl

    /* Page tables: PML4[0] -> PDPT, PDPT[0..3] -> 1 GiB pages at 0,1,2,3 GiB.
     * 1 GiB pages need CPUID PDPE1GB; QEMU's default CPU has it. Present |
     * Writable | PageSize for the PDPT entries. */
    movl    $pml4, %edi
    movl    $pdpt, %eax
    orl     $0x03, %eax                 /* P | RW */
    movl    %eax, (%edi)
    movl    $0, 4(%edi)

    movl    $pdpt, %edi
    movl    $0, %ecx
1:  movl    %ecx, %eax
    shll    $30, %eax                   /* index * 1 GiB (low dword)     */
    orl     $0x83, %eax                 /* P | RW | PS(1GiB page)        */
    movl    %eax, (%edi)
    movl    %ecx, %eax
    shrl    $2, %eax                    /* carry into high dword         */
    movl    %eax, 4(%edi)
    addl    $8, %edi
    incl    %ecx
    cmpl    $4, %ecx
    jb      1b

    /* CR4.PAE | CR4.OSFXSR | CR4.OSXMMEXCPT
     * OSFXSR is what actually enables SSE; without it the first SSE
     * instruction raises #UD, which on a kernel with no IDT is a triple
     * fault and a silent reboot loop. */
    movl    %cr4, %eax
    orl     $(1 << 5) | (1 << 9) | (1 << 10), %eax
    movl    %eax, %cr4

    movl    $pml4, %eax
    movl    %eax, %cr3

    /* EFER.LME */
    movl    $0xC0000080, %ecx
    rdmsr
    orl     $(1 << 8), %eax
    wrmsr

    /* CR0.PG | CR0.PE, and clear EM/TS so x87/SSE are usable */
    movl    %cr0, %eax
    orl     $(1 << 31) | (1 << 0), %eax
    andl    $~((1 << 2) | (1 << 3)), %eax   /* ~EM, ~TS */
    movl    %eax, %cr0

    lgdt    gdt_ptr
    ljmp    $0x08, $long_entry

/* ---- 64-bit ---------------------------------------------------------- */
    .code64
long_entry:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    movw    %ax, %fs
    movw    %ax, %gs

    movq    $stack_top, %rsp
    xorq    %rbp, %rbp

    /* Zero .bss (the arena lives there and mu_arena_alloc expects zeros). */
    movq    $__bss_start, %rdi
    movq    $__bss_end, %rcx
    subq    %rdi, %rcx
    shrq    $3, %rcx
    xorq    %rax, %rax
    cld
    rep stosq

    /* Set MXCSR to the IEEE-754 default: round-to-nearest-even, no flush to
     * zero, no denormals-are-zero. Any other value would change results, so
     * this is part of the reproducibility contract, not boilerplate. */
    movl    $0x1F80, mxcsr_val(%rip)
    ldmxcsr mxcsr_val(%rip)

    call    mu_x86_main

    /* isa-debug-exit: writing to 0x501 makes QEMU exit with (val<<1)|1 */
2:  movl    $0x501, %edx
    movl    $0, %eax
    outb    %al, %dx
3:  hlt
    jmp     3b

/* void mu_x86_exit(int code) */
    .global mu_x86_exit
mu_x86_exit:
    movl    %edi, %eax
    movl    $0x501, %edx
    outb    %al, %dx
4:  hlt
    jmp     4b

/* ---- descriptors ----------------------------------------------------- */
    .section .rodata
    .align 16
gdt:
    .quad 0                             /* null                          */
    .quad 0x00AF9A000000FFFF            /* 0x08: 64-bit code, L=1        */
    .quad 0x00CF92000000FFFF            /* 0x10: data                    */
gdt_end:
gdt_ptr:
    .word gdt_end - gdt - 1
    .long gdt

/* The page tables MUST NOT live in .bss.
 *
 * long_entry zeroes .bss with `rep stosq`, and by then CR3 already points at
 * these pages. Putting them in .bss means the zeroing wipes the live page
 * tables out from under the MMU, which is an immediate triple fault with no
 * diagnostic. They go in .data instead, which is loaded pre-zeroed from the
 * image and never touched by the clear loop. Same reason the aarch64 host
 * keeps its level-1 table in .data. */
    .section .data
    .align 4096
pml4:
    .space 4096
pdpt:
    .space 4096

    .section .bss
    .align 16
mxcsr_val:
    .long 0
    .align 16
    .space 16384
stack_top:
