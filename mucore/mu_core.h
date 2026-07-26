/* mu_core.h -- freestanding deterministic Llama-2 inference core.
 *
 * Derived from llama2.c by Andrej Karpathy (MIT). The arithmetic is faithful
 * to the original; the changes are all in service of three properties the
 * original does not have:
 *
 *   1. FREESTANDING. No libc, no libm, no syscalls, no file I/O. The caller
 *      hands us pointers to already-resident blobs. This lets the same object
 *      files link into a POSIX harness, a bare-metal aarch64 image, or an
 *      seL4/Microkit protection domain.
 *
 *   2. STATIC ALLOCATION. One caller-provided arena, no malloc, no free. The
 *      whole memory footprint is known at build time, which is what makes an
 *      image measurement meaningful and what Microkit requires.
 *
 *   3. BIT-REPRODUCIBLE. Fixed accumulation order, single-threaded, no libm
 *      transcendentals, greedy sampling. See mu_math.h for the IEEE-754
 *      argument. Two builds of this core on any two conforming platforms
 *      produce identical logits, and therefore identical text.
 *
 * Removed deliberately: OpenMP (parallel reduction reorders accumulation),
 * temperature/top-p sampling (RNG), mmap, and the RoPE transcendentals
 * (replaced by a measured table, see tables/).
 */
#ifndef MU_CORE_H
#define MU_CORE_H

#include <stdint.h>
#include <stddef.h>

/* ---- error codes ---------------------------------------------------- */
typedef enum {
    MU_OK               =  0,
    MU_E_BADMAGIC       = -1,  /* checkpoint header failed sanity checks   */
    MU_E_ARENA          = -2,  /* arena too small for this config          */
    MU_E_BOUNDS         = -3,  /* config exceeds compiled-in limits        */
    MU_E_ROPE           = -4,  /* rope table size does not match config    */
    MU_E_TOKBLOB        = -5,  /* tokenizer blob malformed                 */
    MU_E_SEQ            = -6,  /* position beyond seq_len                  */
} mu_err;

/* ---- compiled-in upper bounds --------------------------------------- */
/* These bound the arena and the tokenizer index. They exist so that every
 * allocation is a compile-time constant, which is a Microkit requirement and
 * an auditability win: there is no input that can make this core allocate. */
#ifndef MU_MAX_DIM
#define MU_MAX_DIM        4096
#endif
#ifndef MU_MAX_HIDDEN
#define MU_MAX_HIDDEN     11008
#endif
#ifndef MU_MAX_LAYERS
#define MU_MAX_LAYERS     32
#endif
#ifndef MU_MAX_HEADS
#define MU_MAX_HEADS      32
#endif
#ifndef MU_MAX_VOCAB
#define MU_MAX_VOCAB      32000
#endif
#ifndef MU_MAX_SEQ
#define MU_MAX_SEQ        256
#endif

typedef struct {
    int32_t dim;
    int32_t hidden_dim;
    int32_t n_layers;
    int32_t n_heads;
    int32_t n_kv_heads;
    int32_t vocab_size;
    int32_t seq_len;
} mu_config;

/* Weight views into the caller's checkpoint blob. Nothing is copied. */
typedef struct {
    const float *token_embedding_table;
    const float *rms_att_weight;
    const float *rms_ffn_weight;
    const float *wq, *wk, *wv, *wo;
    const float *w1, *w2, *w3;
    const float *rms_final_weight;
    const float *wcls;
} mu_weights;

/* Activation buffers, all carved from the arena. */
typedef struct {
    float *x, *xb, *xb2;
    float *hb, *hb2;
    float *q, *k, *v;
    float *att;
    float *logits;
    float *key_cache;
    float *value_cache;
} mu_state;

typedef struct {
    mu_config   cfg;
    mu_weights  w;
    mu_state    s;
    const float *rope;      /* measured table: [seq_len][head_size/2][2]     */
    int32_t      head_size;
    int32_t      kv_dim;
    int32_t      kv_mul;
} mu_model;

/* ---- arena ---------------------------------------------------------- */
typedef struct {
    uint8_t *base;
    size_t   size;
    size_t   used;
} mu_arena;

void  mu_arena_init(mu_arena *a, void *base, size_t size);
void *mu_arena_alloc(mu_arena *a, size_t bytes);   /* 64-byte aligned, zeroed */

/* Bytes of arena required for a given config. Lets a host size its region
 * statically, or fail loudly before touching any weights. */
size_t mu_arena_required(const mu_config *cfg);

/* ---- model ---------------------------------------------------------- */
/* ckpt      : whole checkpoint blob (7-int header followed by float weights)
 * ckpt_bytes: its length, used to validate the header against the blob size
 * rope      : measured RoPE table blob
 * rope_bytes: its length
 * arena     : scratch, must satisfy mu_arena_required()                    */
mu_err mu_model_init(mu_model *m,
                     const void *ckpt, size_t ckpt_bytes,
                     const void *rope, size_t rope_bytes,
                     mu_arena *arena);

/* One decode step. Returns the logits buffer (owned by the model). */
const float *mu_forward(mu_model *m, int32_t token, int32_t pos);

/* Deterministic greedy selection. No RNG, no temperature, no sorting. */
int32_t mu_argmax(const float *v, int32_t n);

/* ---- tokenizer ------------------------------------------------------ */
typedef struct {
    const uint8_t *blob;
    size_t         blob_bytes;
    uint32_t       max_token_length;
    int32_t        vocab_size;
    /* index[i] = byte offset of token i's length-prefixed record */
    uint32_t      *offset;      /* arena, vocab_size entries */
    float         *score;       /* arena, vocab_size entries */
    uint16_t      *len;         /* arena, vocab_size entries */
    int32_t       *sorted;      /* arena, vocab_size token ids, strcmp order */
    uint8_t        byte_pieces[512];
} mu_tokenizer;

size_t mu_tok_arena_required(int32_t vocab_size);

mu_err mu_tok_init(mu_tokenizer *t, const void *blob, size_t blob_bytes,
                   int32_t vocab_size, mu_arena *arena);

/* Pointer + length of token's raw piece. No NUL terminator involved. */
const uint8_t *mu_tok_piece(const mu_tokenizer *t, int32_t id, int32_t *out_len);

/* Decode one token to bytes, applying the sentencepiece leading-space rule
 * and <0xNN> byte-fallback expansion. Returns bytes written to out.        */
int32_t mu_tok_decode(const mu_tokenizer *t, int32_t prev, int32_t id,
                      uint8_t *out, int32_t out_cap);

/* BPE encode. tokens must have room for at least text_len + 3 entries. */
mu_err mu_tok_encode(const mu_tokenizer *t, const uint8_t *text, size_t text_len,
                     int add_bos, int add_eos,
                     int32_t *tokens, int32_t *n_tokens, int32_t tokens_cap,
                     uint8_t *scratch, size_t scratch_bytes);

#endif /* MU_CORE_H */
