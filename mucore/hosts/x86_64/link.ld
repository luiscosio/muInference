/* Linker script for muinference x86-64 multiboot (Stage B2).
 *
 * Loaded by QEMU -kernel at the conventional 1 MiB mark. The multiboot header
 * must appear within the first 8 KiB of the file, so it goes first.
 */
ENTRY(_start)

SECTIONS
{
    . = 0x100000;


    /* Must land in a PT_NOTE segment for QEMU to find the PVH entry, so it is
     * kept here and deliberately excluded from the /DISCARD/ of .note.* below. */
    .note.Xen : { KEEP(*(.note.Xen)) }

    .text : ALIGN(4096) {
        KEEP(*(.text.boot))
        *(.text .text.*)
    }

    .rodata : ALIGN(64) { *(.rodata .rodata.*) }

    /* 64-byte aligned so the float arrays inside the blobs are aligned. */
    .rodata_blobs : ALIGN(64) { *(.rodata_blobs .rodata_blobs.*) }

    .data : ALIGN(64) { *(.data .data.*) }

    /* 4 KiB aligned because the page tables live here. */
    .bss (NOLOAD) : ALIGN(4096) {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(8);
        __bss_end = .;
    }

    __image_end = .;

    /DISCARD/ : { *(.comment) *(.note.GNU-stack) *(.note.gnu.*) *(.eh_frame) *(.eh_frame_hdr) }
}
