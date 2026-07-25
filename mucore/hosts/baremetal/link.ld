/* Linker script for muinference bare-metal aarch64 (QEMU 'virt').
 *
 * QEMU virt places RAM at 0x40000000. We load at the base and lay out a flat,
 * MMU-less image. The model, tokenizer and RoPE table are objcopy'd binary
 * blobs placed in .rodata_blobs; embedding them rather than reading files is
 * deliberate, because it is what a Microkit image does and it means one hash
 * over the image covers the weights too.
 */
ENTRY(_start)

RAM_BASE  = 0x40000000;
STACK_SIZE = 0x100000;   /* 1 MiB, single-threaded and no deep recursion */

SECTIONS
{
    . = RAM_BASE;

    .text : ALIGN(4096) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }

    .rodata : ALIGN(64) {
        *(.rodata .rodata.*)
    }

    /* Blobs get their own section at 64-byte alignment so the float arrays
     * inside them are safely aligned for direct access. */
    .rodata_blobs : ALIGN(64) {
        *(.rodata_blobs .rodata_blobs.*)
    }

    .data : ALIGN(64) {
        *(.data .data.*)
    }

    .bss (NOLOAD) : ALIGN(64) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    }

    .stack (NOLOAD) : ALIGN(4096) {
        __stack_bottom = .;
        . += STACK_SIZE;
        __stack_top = .;
    }

    __image_end = .;

    /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame) *(.eh_frame_hdr) }
}
