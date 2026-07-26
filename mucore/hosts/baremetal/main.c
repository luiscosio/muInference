/* Bare-metal aarch64 host for the muinference core (Stage B).
 *
 * No libc, no OS, no filesystem. The blobs are linked into the image; output
 * goes out through ARM semihosting so the logits can be hashed by shasum on
 * the host rather than by anything we wrote.
 *
 * The point of this host is evidentiary. It shares mu_core.c byte for byte
 * with the POSIX host, but is built by a different driver, linked by a
 * different linker, against no libc, and executed on emulated hardware. If
 * the logits still hash identically, the reproducibility claim is about the
 * arithmetic rather than about one lucky build environment.
 */
#include <stdint.h>
#include <stddef.h>
#include "mu_core.h"

/* ---- semihosting ---------------------------------------------------- */
extern long mu_sh_call(long op, void *args);
extern void mu_bm_exit(int code);

#define SYS_OPEN   0x01
#define SYS_CLOSE  0x02
#define SYS_WRITE0 0x04
#define SYS_WRITE  0x05

static void sh_puts(const char *s)
{
    mu_sh_call(SYS_WRITE0, (void *)(uintptr_t)s);
}

static size_t cstrlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }

static long sh_open_wb(const char *path)
{
    /* mode 5 == "wb" in the semihosting mode table */
    long args[3];
    args[0] = (long)(uintptr_t)path;
    args[1] = 5;
    args[2] = (long)cstrlen(path);
    return mu_sh_call(SYS_OPEN, args);
}

/* Returns 0 on success. SYS_WRITE reports the number of bytes NOT written. */
static int sh_write(long h, const void *buf, size_t len)
{
    long args[3];
    args[0] = h;
    args[1] = (long)(uintptr_t)buf;
    args[2] = (long)len;
    return mu_sh_call(SYS_WRITE, args) != 0;
}

static void sh_close(long h)
{
    long args[1] = { h };
    mu_sh_call(SYS_CLOSE, args);
}

/* Minimal unsigned decimal formatting; avoids pulling in any printf. */
static void sh_putu(unsigned long v)
{
    char b[24];
    int i = 23;
    b[i--] = 0;
    if (v == 0) b[i--] = '0';
    while (v) { b[i--] = (char)('0' + (v % 10)); v /= 10; }
    sh_puts(&b[i + 1]);
}

/* ---- embedded blobs -------------------------------------------------
 * Produced by llvm-objcopy -I binary. The symbol names come from the input
 * filename, so the Makefile copies each blob to a fixed short name first. */
extern const uint8_t _binary_model_bin_start[],     _binary_model_bin_end[];
extern const uint8_t _binary_tokenizer_bin_start[], _binary_tokenizer_bin_end[];
extern const uint8_t _binary_rope_bin_start[],      _binary_rope_bin_end[];

/* Arena in .bss, sized identically to the POSIX host. */
#ifndef MU_ARENA_BYTES
#define MU_ARENA_BYTES (16u * 1024u * 1024u)
#endif
static uint8_t g_arena[MU_ARENA_BYTES];

/* Steps kept modest: every step writes 32000 float32 through semihosting,
 * which is not fast. 24 steps is 3 MiB and plenty to detect a single bit. */
#ifndef MU_BM_STEPS
#define MU_BM_STEPS 24
#endif

/* Prompt is fixed and must match what the host harness is told to use. */
static const char g_prompt[] = "Once upon a time";

static int32_t prompt_tokens[MU_MAX_SEQ + 8];
static uint8_t scratch[4096];

int mu_bm_main(void)
{
    sh_puts("muinference bare-metal aarch64\r\n");

    size_t model_len = (size_t)(_binary_model_bin_end - _binary_model_bin_start);
    size_t tok_len   = (size_t)(_binary_tokenizer_bin_end - _binary_tokenizer_bin_start);
    size_t rope_len  = (size_t)(_binary_rope_bin_end - _binary_rope_bin_start);

    sh_puts("  model bytes     "); sh_putu(model_len); sh_puts("\r\n");
    sh_puts("  tokenizer bytes "); sh_putu(tok_len);   sh_puts("\r\n");
    sh_puts("  rope bytes      "); sh_putu(rope_len);  sh_puts("\r\n");

    mu_arena arena;
    mu_arena_init(&arena, g_arena, sizeof g_arena);

    static mu_model model;
    mu_err e = mu_model_init(&model, _binary_model_bin_start, model_len,
                             _binary_rope_bin_start, rope_len, &arena);
    if (e != MU_OK) {
        sh_puts("  mu_model_init failed, err="); sh_putu((unsigned long)(-e)); sh_puts("\r\n");
        mu_bm_exit(1);
    }

    static mu_tokenizer tok;
    e = mu_tok_init(&tok, _binary_tokenizer_bin_start, tok_len,
                    model.cfg.vocab_size, &arena);
    if (e != MU_OK) {
        sh_puts("  mu_tok_init failed, err="); sh_putu((unsigned long)(-e)); sh_puts("\r\n");
        mu_bm_exit(1);
    }

    sh_puts("  arena used      "); sh_putu((unsigned long)arena.used); sh_puts("\r\n");

    int32_t n_prompt = 0;
    e = mu_tok_encode(&tok, (const uint8_t *)g_prompt, sizeof g_prompt - 1,
                      1, 0, prompt_tokens, &n_prompt,
                      (int32_t)(sizeof prompt_tokens / sizeof prompt_tokens[0]),
                      scratch, sizeof scratch);
    if (e != MU_OK) {
        sh_puts("  encode failed\r\n");
        mu_bm_exit(1);
    }
    sh_puts("  prompt tokens   "); sh_putu((unsigned long)n_prompt); sh_puts("\r\n");

    long fh = sh_open_wb("bm.logits");
    if (fh <= 0) { sh_puts("  semihosting open failed\r\n"); mu_bm_exit(1); }

    sh_puts("  generating: ");

    int32_t token = prompt_tokens[0];
    int32_t pos = 0;
    uint8_t piece[64];

    while (pos < MU_BM_STEPS) {
        const float *logits = mu_forward(&model, token, pos);

        if (sh_write(fh, logits, (size_t)model.cfg.vocab_size * sizeof(float))) {
            sh_puts("\r\n  semihosting write failed\r\n");
            mu_bm_exit(1);
        }

        int32_t next = (pos < n_prompt - 1)
                     ? prompt_tokens[pos + 1]
                     : mu_argmax(logits, model.cfg.vocab_size);
        pos++;
        if (next == 1) break;

        int32_t nb = mu_tok_decode(&tok, token, next, piece, (int32_t)sizeof piece - 1);
        if (nb > 0) { piece[nb] = 0; sh_puts((const char *)piece); }
        token = next;
    }

    sh_close(fh);
    sh_puts("\r\n  wrote bm.logits, ");
    sh_putu((unsigned long)pos);
    sh_puts(" steps\r\ndone\r\n");
    mu_bm_exit(0);
    return 0;
}
