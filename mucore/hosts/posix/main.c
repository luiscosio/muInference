/* POSIX harness for the muinference core (Stage A).
 *
 * This file is the ONLY place POSIX appears. It reads blobs off disk and hands
 * them to the core, which is freestanding. The bare-metal and Microkit hosts
 * replace exactly this file and nothing else, which is the point of the split:
 * the code under test is identical across all three, so a determinism result
 * measured here carries over.
 *
 * --dump-logits writes raw float32 logits for every decode step so the run can
 * be fingerprinted with an external, trusted hash (shasum) rather than one we
 * wrote ourselves.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#include "mu_core.h"

/* Arena: static BSS so the footprint is fixed at link time, exactly as it
 * will be in a Microkit memory region. 16 MiB covers stories15M (needs
 * ~3.8 MiB of activations plus ~0.4 MiB of tokenizer index) with headroom. */
#ifndef MU_ARENA_BYTES
#define MU_ARENA_BYTES (16u * 1024u * 1024u)
#endif
static uint8_t g_arena[MU_ARENA_BYTES];

static void *map_file(const char *path, size_t *out_len)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) { fprintf(stderr, "open %s failed\n", path); exit(1); }
    struct stat st;
    if (fstat(fd, &st) != 0) { fprintf(stderr, "fstat %s failed\n", path); exit(1); }
    void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (p == MAP_FAILED) { fprintf(stderr, "mmap %s failed\n", path); exit(1); }
    close(fd);
    *out_len = (size_t)st.st_size;
    return p;
}

static const char *errname(mu_err e)
{
    switch (e) {
    case MU_OK:           return "ok";
    case MU_E_BADMAGIC:   return "bad checkpoint header";
    case MU_E_ARENA:      return "arena exhausted";
    case MU_E_BOUNDS:     return "config exceeds compiled limits";
    case MU_E_ROPE:       return "rope table does not match config";
    case MU_E_TOKBLOB:    return "tokenizer blob malformed";
    case MU_E_SEQ:        return "position beyond seq_len";
    default:              return "unknown";
    }
}

int main(int argc, char **argv)
{
    const char *ckpt_path = "model/stories15M.bin";
    const char *tok_path  = "model/tokenizer.bin";
    const char *rope_path = "mucore/tables/rope_256x48.bin";
    const char *prompt    = "";
    const char *dump_path = NULL;
    int steps = 64;
    int quiet = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-m") && i + 1 < argc)      ckpt_path = argv[++i];
        else if (!strcmp(argv[i], "-z") && i + 1 < argc) tok_path  = argv[++i];
        else if (!strcmp(argv[i], "-r") && i + 1 < argc) rope_path = argv[++i];
        else if (!strcmp(argv[i], "-i") && i + 1 < argc) prompt    = argv[++i];
        else if (!strcmp(argv[i], "-n") && i + 1 < argc) steps     = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dump-logits") && i + 1 < argc) dump_path = argv[++i];
        else if (!strcmp(argv[i], "-q")) quiet = 1;
        else { fprintf(stderr,
            "usage: %s [-m ckpt] [-z tokenizer] [-r rope] [-i prompt] [-n steps]\n"
            "          [--dump-logits FILE] [-q]\n", argv[0]); return 2; }
    }

    size_t ckpt_len, tok_len, rope_len;
    void *ckpt = map_file(ckpt_path, &ckpt_len);
    void *tokb = map_file(tok_path,  &tok_len);
    void *rope = map_file(rope_path, &rope_len);

    mu_arena arena;
    mu_arena_init(&arena, g_arena, sizeof g_arena);

    mu_model model;
    mu_err e = mu_model_init(&model, ckpt, ckpt_len, rope, rope_len, &arena);
    if (e != MU_OK) { fprintf(stderr, "mu_model_init: %s (%d)\n", errname(e), e); return 1; }

    mu_tokenizer tok;
    e = mu_tok_init(&tok, tokb, tok_len, model.cfg.vocab_size, &arena);
    if (e != MU_OK) { fprintf(stderr, "mu_tok_init: %s (%d)\n", errname(e), e); return 1; }

    if (!quiet) {
        fprintf(stderr,
            "muinference: dim=%d hidden=%d layers=%d heads=%d kv_heads=%d "
            "vocab=%d seq_len=%d head_size=%d\n",
            model.cfg.dim, model.cfg.hidden_dim, model.cfg.n_layers,
            model.cfg.n_heads, model.cfg.n_kv_heads, model.cfg.vocab_size,
            model.cfg.seq_len, model.head_size);
        fprintf(stderr, "arena: %zu / %zu bytes used (%.1f%%)\n",
            arena.used, sizeof g_arena, 100.0 * (double)arena.used / (double)sizeof g_arena);
    }

    if (steps > model.cfg.seq_len) steps = model.cfg.seq_len;

    /* Encode the prompt. Bound the token buffer the same way upstream does. */
    static int32_t prompt_tokens[MU_MAX_SEQ + 8];
    static uint8_t scratch[4096];
    int32_t n_prompt = 0;
    e = mu_tok_encode(&tok, (const uint8_t *)prompt, strlen(prompt),
                      1 /*bos*/, 0 /*eos*/,
                      prompt_tokens, &n_prompt,
                      (int32_t)(sizeof prompt_tokens / sizeof prompt_tokens[0]),
                      scratch, sizeof scratch);
    if (e != MU_OK) { fprintf(stderr, "encode: %s (%d)\n", errname(e), e); return 1; }
    if (n_prompt < 1) { fprintf(stderr, "encode produced no tokens\n"); return 1; }

    FILE *dump = NULL;
    if (dump_path) {
        dump = fopen(dump_path, "wb");
        if (!dump) { fprintf(stderr, "fopen %s failed\n", dump_path); return 1; }
    }

    /* Decode loop, structurally identical to run.c's generate(). */
    int32_t token = prompt_tokens[0];
    int32_t pos = 0;
    uint8_t piece[64];

    while (pos < steps) {
        const float *logits = mu_forward(&model, token, pos);

        if (dump) {
            if (fwrite(logits, sizeof(float), (size_t)model.cfg.vocab_size, dump)
                != (size_t)model.cfg.vocab_size) {
                fprintf(stderr, "dump write failed\n"); return 1;
            }
        }

        int32_t next;
        if (pos < n_prompt - 1) next = prompt_tokens[pos + 1];
        else                    next = mu_argmax(logits, model.cfg.vocab_size);
        pos++;

        if (next == 1) break;   /* BOS acts as terminator, as upstream */

        int32_t nb = mu_tok_decode(&tok, token, next, piece, (int32_t)sizeof piece);
        if (nb > 0) fwrite(piece, 1, (size_t)nb, stdout);
        token = next;
    }
    fputc('\n', stdout);

    if (dump) fclose(dump);
    return 0;
}
