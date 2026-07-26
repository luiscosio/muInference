/* x86-64 freestanding host for the muinference core (Stage B2).
 *
 * This host exists purely as evidence. The aarch64 bare-metal host proved the
 * logits do not depend on the toolchain, the C library, the linker or the OS,
 * but every environment tested so far was aarch64 running on an Apple Silicon
 * FPU. This one is compiled by a different LLVM backend (different instruction
 * selection, different register allocation, SSE instead of NEON) and executed
 * by QEMU's x86 TCG, which evaluates SSE with its own softfloat library rather
 * than on host hardware.
 *
 * So if the logits still match, the IEEE-754 argument in mu_math.h has been
 * confirmed across two independent floating point *implementations*, not just
 * two views of the same silicon. That is the claim cross-ISA testing is for.
 *
 * Two serial ports: COM1 carries human-readable progress, COM2 carries the raw
 * float32 logits so QEMU can write them straight to a file with no hex
 * expansion and no in-guest hashing.
 */
#include <stdint.h>
#include <stddef.h>
#include "mu_core.h"

extern void mu_x86_exit(int code);

/* ---- port I/O -------------------------------------------------------- */
static inline void outb(uint16_t port, uint8_t v)
{
    __asm__ volatile("outb %0, %1" :: "a"(v), "Nd"(port));
}
static inline uint8_t inb(uint16_t port)
{
    uint8_t v;
    __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port));
    return v;
}

#define COM1 0x3F8   /* console */
#define COM2 0x2F8   /* logits  */

static void serial_init(uint16_t base)
{
    outb(base + 1, 0x00);   /* interrupts off            */
    outb(base + 3, 0x80);   /* DLAB on                   */
    outb(base + 0, 0x03);   /* divisor low  (38400 baud) */
    outb(base + 1, 0x00);   /* divisor high              */
    outb(base + 3, 0x03);   /* 8 bits, no parity, 1 stop */
    outb(base + 2, 0xC7);   /* FIFO on, cleared, 14-byte */
    outb(base + 4, 0x0B);   /* RTS/DSR set               */
}

static void serial_putc(uint16_t base, uint8_t c)
{
    while ((inb(base + 5) & 0x20) == 0) { }   /* wait for THR empty */
    outb(base, c);
}

static void puts1(const char *s)
{
    for (; *s; s++) serial_putc(COM1, (uint8_t)*s);
}

static void putu1(unsigned long v)
{
    char b[24];
    int i = 23;
    b[i--] = 0;
    if (v == 0) b[i--] = '0';
    while (v) { b[i--] = (char)('0' + (v % 10)); v /= 10; }
    puts1(&b[i + 1]);
}

static void emit_logits(const void *p, size_t n)
{
    const uint8_t *b = (const uint8_t *)p;
    for (size_t i = 0; i < n; i++) serial_putc(COM2, b[i]);
}

/* ---- embedded blobs -------------------------------------------------- */
extern const uint8_t _binary_model_bin_start[],     _binary_model_bin_end[];
extern const uint8_t _binary_tokenizer_bin_start[], _binary_tokenizer_bin_end[];
extern const uint8_t _binary_rope_bin_start[],      _binary_rope_bin_end[];

#ifndef MU_ARENA_BYTES
#define MU_ARENA_BYTES (16u * 1024u * 1024u)
#endif
static uint8_t g_arena[MU_ARENA_BYTES];

/* Must match the aarch64 host and the POSIX invocation in cross_env.sh. */
#ifndef MU_BM_STEPS
#define MU_BM_STEPS 24
#endif
static const char g_prompt[] = "Once upon a time";

static int32_t prompt_tokens[MU_MAX_SEQ + 8];
static uint8_t scratch[4096];

int mu_x86_main(void)
{
    serial_init(COM1);
    serial_init(COM2);

    puts1("muinference x86-64 freestanding\r\n");

    size_t model_len = (size_t)(_binary_model_bin_end - _binary_model_bin_start);
    size_t tok_len   = (size_t)(_binary_tokenizer_bin_end - _binary_tokenizer_bin_start);
    size_t rope_len  = (size_t)(_binary_rope_bin_end - _binary_rope_bin_start);

    puts1("  model bytes     "); putu1(model_len); puts1("\r\n");
    puts1("  tokenizer bytes "); putu1(tok_len);   puts1("\r\n");
    puts1("  rope bytes      "); putu1(rope_len);  puts1("\r\n");

    /* Confirm the FP environment is the IEEE-754 default. A non-default MXCSR
     * (flush-to-zero, denormals-are-zero, or a different rounding mode) would
     * silently change results, so it is worth asserting rather than assuming. */
    uint32_t mxcsr;
    __asm__ volatile("stmxcsr %0" : "=m"(mxcsr));
    puts1("  mxcsr           "); putu1(mxcsr);
    puts1(mxcsr == 0x1F80 ? "  (IEEE default)\r\n" : "  (NON-DEFAULT!)\r\n");

    /* Progress markers. On bare metal a fault has no diagnostic at all: no
     * IDT means #GP or #PF becomes a triple fault and a silent reset. Printing
     * before each phase is the cheapest possible debugger. */
    puts1("  arena base      "); putu1((unsigned long)(uintptr_t)g_arena); puts1("\r\n");
    puts1("  arena bytes     "); putu1((unsigned long)sizeof g_arena); puts1("\r\n");

    mu_arena arena;
    mu_arena_init(&arena, g_arena, sizeof g_arena);
    puts1("  [arena init ok]\r\n");

    static mu_model model;
    mu_err e = mu_model_init(&model, _binary_model_bin_start, model_len,
                             _binary_rope_bin_start, rope_len, &arena);
    if (e != MU_OK) {
        puts1("  mu_model_init failed err="); putu1((unsigned long)(-e)); puts1("\r\n");
        mu_x86_exit(1);
    }
    puts1("  [model init ok]\r\n");

    static mu_tokenizer tok;
    e = mu_tok_init(&tok, _binary_tokenizer_bin_start, tok_len,
                    model.cfg.vocab_size, &arena);
    if (e != MU_OK) {
        puts1("  mu_tok_init failed err="); putu1((unsigned long)(-e)); puts1("\r\n");
        mu_x86_exit(1);
    }
    puts1("  [tok init ok]\r\n");

    puts1("  arena used      "); putu1((unsigned long)arena.used); puts1("\r\n");

    int32_t n_prompt = 0;
    e = mu_tok_encode(&tok, (const uint8_t *)g_prompt, sizeof g_prompt - 1,
                      1, 0, prompt_tokens, &n_prompt,
                      (int32_t)(sizeof prompt_tokens / sizeof prompt_tokens[0]),
                      scratch, sizeof scratch);
    if (e != MU_OK) { puts1("  encode failed\r\n"); mu_x86_exit(1); }
    puts1("  prompt tokens   "); putu1((unsigned long)n_prompt); puts1("\r\n");

    puts1("  generating: ");

    int32_t token = prompt_tokens[0];
    int32_t pos = 0;
    uint8_t piece[64];

    while (pos < MU_BM_STEPS) {
        const float *logits = mu_forward(&model, token, pos);
        emit_logits(logits, (size_t)model.cfg.vocab_size * sizeof(float));

        int32_t next = (pos < n_prompt - 1)
                     ? prompt_tokens[pos + 1]
                     : mu_argmax(logits, model.cfg.vocab_size);
        pos++;
        if (next == 1) break;

        int32_t nb = mu_tok_decode(&tok, token, next, piece, (int32_t)sizeof piece - 1);
        if (nb > 0) { piece[nb] = 0; puts1((const char *)piece); }
        token = next;
    }

    puts1("\r\n  emitted "); putu1((unsigned long)pos); puts1(" steps on COM2\r\ndone\r\n");
    mu_x86_exit(0);
    return 0;
}
