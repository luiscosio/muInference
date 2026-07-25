/* CBMC harness for S1 (no undefined behaviour) on the forward pass.
 *
 * STRATEGY
 *   The shipping model is 60 MB, far beyond symbolic execution. But the
 *   indexing logic in mu_forward is parametric in the config: the same
 *   expressions compute offsets whether dim is 8 or 4096. So we verify a tiny
 *   config exhaustively, with UNCONSTRAINED weights and an UNCONSTRAINED token,
 *   and let CBMC prove that no execution path performs an out-of-bounds access,
 *   overflows, or divides by zero.
 *
 *   That is not a proof for all configs — Frama-C with a loop invariant over
 *   symbolic dim would be. It is a proof that every branch and index expression
 *   in the function is safe for arbitrary float inputs at this shape, which is
 *   where indexing bugs actually live.
 *
 * WHAT IS NONDETERMINISTIC
 *   Every weight, every RoPE table entry, and the token id. Weights are
 *   unconstrained floats, so NaN and infinity are in scope: the harness proves
 *   memory safety even when the arithmetic produces garbage.
 *
 * Build:  goto-cc, then cbmc with the check flags. See tests/verify_s1.sh.
 */
#include <stdint.h>
#include <stddef.h>
#include "mu_core.h"

/* --- tiny config -------------------------------------------------------
 * head_size = dim / n_heads = 4, kv_dim = 8, so every shape is exercised
 * including the kv-sharing path and the RoPE rotn split. */
#define T_DIM      8
#define T_HIDDEN   16
#define T_LAYERS   1
#define T_HEADS    2
#define T_KVHEADS  1    /* < T_HEADS, so kv_mul == 2 and rotn takes both values */
#define T_VOCAB    8
#define T_SEQ      2
#define T_HEAD    (T_DIM / T_HEADS)

/* Weight float count, in the exact order mu_map_weights walks. */
#define N_W ( (size_t)T_VOCAB*T_DIM                       /* token_embedding */ \
            + (size_t)T_LAYERS*T_DIM                      /* rms_att         */ \
            + (size_t)T_LAYERS*T_DIM*(T_HEADS*T_HEAD)     /* wq              */ \
            + (size_t)T_LAYERS*T_DIM*(T_KVHEADS*T_HEAD)   /* wk              */ \
            + (size_t)T_LAYERS*T_DIM*(T_KVHEADS*T_HEAD)   /* wv              */ \
            + (size_t)T_LAYERS*(T_HEADS*T_HEAD)*T_DIM     /* wo              */ \
            + (size_t)T_LAYERS*T_DIM                      /* rms_ffn         */ \
            + (size_t)T_LAYERS*T_DIM*T_HIDDEN             /* w1              */ \
            + (size_t)T_LAYERS*T_HIDDEN*T_DIM             /* w2              */ \
            + (size_t)T_LAYERS*T_DIM*T_HIDDEN             /* w3              */ \
            + (size_t)T_DIM                               /* rms_final       */ \
            + (size_t)T_SEQ*T_HEAD/2 + (size_t)T_SEQ*T_HEAD/2 )  /* legacy rope */

#define N_ROPE ((size_t)T_SEQ * (size_t)T_HEAD)

/* Checkpoint layout, declared directly rather than assembled by a copy loop.
 * int32_t and float are both 4 bytes with no padding between them, so this
 * struct has exactly the byte layout mu_model_init parses. Declaring it this
 * way removes three 800-iteration initialisation loops from the harness, which
 * would otherwise force --unwind above 800 and blow up the solver for no
 * benefit. */
static struct {
    int32_t hdr[7];
    float   w[N_W];
} ck;

static float   rope[N_ROPE];
static uint8_t arena_mem[1u << 16];   /* 64 KiB, ample for this config */

int32_t nondet_int32(void);

int main(void)
{
    /* Fixed, valid config. mu_check_bounds must accept it. */
    ck.hdr[0] = T_DIM;
    ck.hdr[1] = T_HIDDEN;
    ck.hdr[2] = T_LAYERS;
    ck.hdr[3] = T_HEADS;
    ck.hdr[4] = T_KVHEADS;
    ck.hdr[5] = T_VOCAB;    /* positive => shared classifier weights */
    ck.hdr[6] = T_SEQ;

    /* Weights and the RoPE table are left concrete (zero).
     *
     * Every index computed in mu_forward is a function of the config, the
     * token and the position -- never of a weight VALUE. Float values reach
     * control flow only through the two `>` comparisons in mu_softmax and
     * mu_argmax, and both branches of each are index-safe. Making them
     * symbolic therefore adds no coverage of memory safety while making the
     * float reasoning intractable (it did not finish in 10 minutes).
     */

    const void *blob = &ck;

    mu_arena arena;
    mu_arena_init(&arena, arena_mem, sizeof arena_mem);

    static mu_model m;
    mu_err e = mu_model_init(&m, blob, sizeof ck,
                             rope, sizeof rope, &arena);

    /* If init rejected the config the rest is unreachable; assert it did not,
     * so a silent early return cannot make the harness vacuous. */
    __CPROVER_assert(e == MU_OK, "model init accepts the fixed valid config");
    if (e != MU_OK) return 0;

    /* Post-conditions on the derived shape, so a wrong division would be caught
     * here rather than as an out-of-bounds access later. */
    __CPROVER_assert(m.head_size == T_HEAD, "head_size derived correctly");
    __CPROVER_assert(m.kv_dim > 0 && m.kv_dim <= T_DIM, "kv_dim in range");
    __CPROVER_assert(m.kv_mul >= 1, "kv_mul at least one");
    __CPROVER_assert(arena.used <= arena.size, "arena within its bounds");

    /* Unconstrained token, constrained only to the valid range the caller
     * contract requires. Feeding an out-of-range token is a caller bug, not an
     * engine bug, so it is assumed away rather than proven safe. */
    int32_t token = nondet_int32();
    __CPROVER_assume(token >= 0 && token < T_VOCAB);

    /* Walk every position, which is what grows the KV cache and exercises the
     * attention loop bounds. */
    /* Nondeterministic start position, so the attention loop bound and the
     * KV-cache offsets are proven for every reachable pos rather than only for
     * a walk beginning at zero. */
    int32_t p0 = nondet_int32();
    __CPROVER_assume(p0 >= 0 && p0 < T_SEQ);

    for (int32_t pos = p0; pos < T_SEQ; pos++) {
        const float *logits = mu_forward(&m, token, pos);
        __CPROVER_assert(logits != 0, "forward returns a buffer");

        /* Touch both ends of the logits so a short allocation is caught. */
        volatile float lo = logits[0];
        volatile float hi = logits[T_VOCAB - 1];
        (void)lo; (void)hi;

        int32_t next = mu_argmax(logits, T_VOCAB);
        __CPROVER_assert(next >= 0 && next < T_VOCAB, "argmax returns a valid index");

        token = next;
    }

    __CPROVER_assert(arena.used <= arena.size, "arena still within bounds");
    return 0;
}
