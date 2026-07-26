/* seL4 / Microkit protection domain for the muinference core (Stage C).
 *
 * This is the target configuration: a single-core aarch64 seL4 system with one
 * protection domain that does nothing but inference. No Linux guest, no VMM,
 * no device drivers, no GPU. The PD has no capabilities beyond its own memory
 * and the debug console.
 *
 * On isolation claims, precisely: the seL4 AArch64 hypervisor configuration has
 * machine-checked functional correctness and integrity proofs (confidentiality
 * is listed in progress, information flow is not proven, and binary-level
 * verification covers AArch32 and RISC-V64 rather than AArch64). No verified
 * configuration includes an SMMU, and verified means single core. So the honest
 * statement is: this runs on a formally verified microkernel, in a
 * configuration whose functional correctness and integrity are proven, with
 * one PD and no device access.
 *
 * Output goes through seL4's debug console, which is why the build uses the
 * SDK's `debug` configuration. Logits are emitted as hex between markers so the
 * harness can extract and hash them externally with shasum, keeping the oracle
 * independent of anything in this repo.
 */
#include <stdint.h>
#include <microkit.h>
#include "mu_core.h"

/* Blobs linked into the PD image. Named `.rodata` exactly, because that is the
 * only read-only input section microkit.ld matches; a custom name would be an
 * orphan section placed at the linker's discretion. */
extern const uint8_t _binary_model_bin_start[],     _binary_model_bin_end[];
extern const uint8_t _binary_tokenizer_bin_start[], _binary_tokenizer_bin_end[];
extern const uint8_t _binary_rope_bin_start[],      _binary_rope_bin_end[];

#ifndef MU_ARENA_BYTES
#define MU_ARENA_BYTES (16u * 1024u * 1024u)
#endif
static uint8_t g_arena[MU_ARENA_BYTES];

/* Must match cross_env.sh and the other freestanding hosts. */
#ifndef MU_MK_STEPS
#define MU_MK_STEPS 24
#endif
static const char g_prompt[] = "Once upon a time";

static int32_t prompt_tokens[MU_MAX_SEQ + 8];
static uint8_t scratch[4096];

static void putu(unsigned long v)
{
    char b[24];
    int i = 23;
    b[i--] = 0;
    if (v == 0) b[i--] = '0';
    while (v) { b[i--] = (char)('0' + (v % 10)); v /= 10; }
    microkit_dbg_puts(&b[i + 1]);
}

static const char HEX[] = "0123456789abcdef";

/* Raw bytes as hex. One seL4_DebugPutChar syscall per nibble, which is slow but
 * is the only channel a PD with no device capabilities has. Framed so the
 * harness can extract exactly the payload. */
static void emit_hex(const void *p, size_t n)
{
    const uint8_t *b = (const uint8_t *)p;
    for (size_t i = 0; i < n; i++) {
        microkit_dbg_putc(HEX[b[i] >> 4]);
        microkit_dbg_putc(HEX[b[i] & 0xF]);
    }
}

void init(void)
{
    microkit_dbg_puts("muinference on seL4/Microkit\n");

    size_t model_len = (size_t)(_binary_model_bin_end - _binary_model_bin_start);
    size_t tok_len   = (size_t)(_binary_tokenizer_bin_end - _binary_tokenizer_bin_start);
    size_t rope_len  = (size_t)(_binary_rope_bin_end - _binary_rope_bin_start);

    microkit_dbg_puts("  model bytes     "); putu(model_len); microkit_dbg_puts("\n");
    microkit_dbg_puts("  tokenizer bytes "); putu(tok_len);   microkit_dbg_puts("\n");
    microkit_dbg_puts("  rope bytes      "); putu(rope_len);  microkit_dbg_puts("\n");

    mu_arena arena;
    mu_arena_init(&arena, g_arena, sizeof g_arena);

    static mu_model model;
    mu_err e = mu_model_init(&model, _binary_model_bin_start, model_len,
                             _binary_rope_bin_start, rope_len, &arena);
    if (e != MU_OK) {
        microkit_dbg_puts("  mu_model_init failed err="); putu((unsigned long)(-e));
        microkit_dbg_puts("\n@@@END\n");
        return;
    }

    static mu_tokenizer tok;
    e = mu_tok_init(&tok, _binary_tokenizer_bin_start, tok_len,
                    model.cfg.vocab_size, &arena);
    if (e != MU_OK) {
        microkit_dbg_puts("  mu_tok_init failed err="); putu((unsigned long)(-e));
        microkit_dbg_puts("\n@@@END\n");
        return;
    }

    microkit_dbg_puts("  arena used      "); putu((unsigned long)arena.used);
    microkit_dbg_puts("\n");

    int32_t n_prompt = 0;
    e = mu_tok_encode(&tok, (const uint8_t *)g_prompt, sizeof g_prompt - 1,
                      1, 0, prompt_tokens, &n_prompt,
                      (int32_t)(sizeof prompt_tokens / sizeof prompt_tokens[0]),
                      scratch, sizeof scratch);
    if (e != MU_OK) {
        microkit_dbg_puts("  encode failed\n@@@END\n");
        return;
    }
    microkit_dbg_puts("  prompt tokens   "); putu((unsigned long)n_prompt);
    microkit_dbg_puts("\n  text: ");

    /* Pass 1: generate and keep the tokens, printing the text as we go. */
    static int32_t out_tokens[MU_MAX_SEQ + 8];
    static float   saved[MU_MK_STEPS * MU_MAX_VOCAB];

    int32_t token = prompt_tokens[0];
    int32_t pos = 0;
    uint8_t piece[64];

    while (pos < MU_MK_STEPS) {
        const float *logits = mu_forward(&model, token, pos);

        for (int32_t i = 0; i < model.cfg.vocab_size; i++)
            saved[(size_t)pos * (size_t)model.cfg.vocab_size + (size_t)i] = logits[i];

        int32_t next = (pos < n_prompt - 1)
                     ? prompt_tokens[pos + 1]
                     : mu_argmax(logits, model.cfg.vocab_size);
        out_tokens[pos] = next;
        pos++;
        if (next == 1) break;

        int32_t nb = mu_tok_decode(&tok, token, next, piece, (int32_t)sizeof piece - 1);
        if (nb > 0) { piece[nb] = 0; microkit_dbg_puts((const char *)piece); }
        token = next;
    }

    microkit_dbg_puts("\n  steps "); putu((unsigned long)pos); microkit_dbg_puts("\n");

    /* Pass 2: dump the logits. Separated from generation so the (slow) hex
     * emission does not interleave with the readable text above. */
    microkit_dbg_puts("@@@BEGIN\n");
    emit_hex(saved, (size_t)pos * (size_t)model.cfg.vocab_size * sizeof(float));
    microkit_dbg_puts("\n@@@END\n");
}

void notified(microkit_channel ch)
{
    (void)ch;
}
