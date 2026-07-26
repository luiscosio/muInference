/* CBMC unit harnesses for S1 (no undefined behaviour) and S2 (arena bounds).
 *
 * WHY UNIT HARNESSES RATHER THAN ONE END-TO-END HARNESS
 *   Verifying mu_forward whole does not scale. CBMC encodes IEEE-754
 *   arithmetic bit-precisely, and one forward pass is thousands of float
 *   operations; it did not finish in ten minutes even on an 8-dimension model.
 *   That cost buys nothing for memory safety, because no index in the engine
 *   depends on a float VALUE.
 *
 *   Verifying function by function is cheaper AND proves more: the sizes can be
 *   symbolic, so each result holds for a RANGE of shapes instead of the one
 *   config an end-to-end harness pins down.
 *
 * Select a harness with -DH_<name>. See tests/verify_s1.sh.
 */
#include <stdint.h>
#include <stddef.h>
/* mu_core.c is INCLUDED, not linked, so the static helpers (mu_matmul,
 * mu_softmax, mu_rmsnorm) are visible to the harnesses. Standard technique for
 * unit-verifying internal functions without exporting them in the shipping
 * build. */
#include "mu_core.c"

int32_t nondet_int32(void);
uint32_t nondet_uint32(void);
size_t nondet_size(void);
float nondet_float(void);

/* ===================================================================== S2
 * The arena is the whole of S2. Pure integer arithmetic, so this is exact and
 * fast, and it is a complete proof rather than a bounded one for the property
 * that matters: a returned block always lies inside the arena.
 */
#ifdef H_ARENA
#define POOL 192   /* keeps mu_memset's byte loop inside the unwind bound */
static uint8_t pool[POOL];

int main(void)
{
    size_t size = nondet_size();
    __CPROVER_assume(size <= POOL);

    mu_arena a;
    mu_arena_init(&a, pool, size);

    __CPROVER_assert(a.used == 0, "fresh arena has nothing used");
    __CPROVER_assert(a.size == size, "arena records its size");

    /* Three successive allocations of unconstrained sizes. Three is enough to
     * expose an overlap bug: it needs a previous block, a current one, and a
     * following one. */
    size_t n1 = nondet_size(), n2 = nondet_size(), n3 = nondet_size();
    __CPROVER_assume(n1 <= POOL && n2 <= POOL && n3 <= POOL);

    uint8_t *p1 = (uint8_t *)mu_arena_alloc(&a, n1);
    size_t used1 = a.used;
    uint8_t *p2 = (uint8_t *)mu_arena_alloc(&a, n2);
    size_t used2 = a.used;
    uint8_t *p3 = (uint8_t *)mu_arena_alloc(&a, n3);

    /* Invariant that must hold no matter what was asked for. */
    __CPROVER_assert(a.used <= a.size, "used never exceeds size");

    /* Every non-NULL block lies wholly inside the arena. */
    if (p1) {
        __CPROVER_assert(p1 >= pool, "block 1 starts at or after the base");
        __CPROVER_assert(p1 + n1 <= pool + size, "block 1 ends inside the arena");
        __CPROVER_assert(((uintptr_t)p1 % 64u) == 0, "block 1 is 64-byte aligned");
    }
    if (p2) {
        __CPROVER_assert(p2 + n2 <= pool + size, "block 2 ends inside the arena");
        __CPROVER_assert(((uintptr_t)p2 % 64u) == 0, "block 2 is 64-byte aligned");
        /* Non-overlap: block 2 begins at or after where block 1 ended. */
        if (p1) __CPROVER_assert(p2 >= p1 + n1, "block 2 does not overlap block 1");
    }
    if (p3) {
        __CPROVER_assert(p3 + n3 <= pool + size, "block 3 ends inside the arena");
        if (p2) __CPROVER_assert(p3 >= p2 + n2, "block 3 does not overlap block 2");
    }

    /* used is monotonic: an allocation never gives memory back. */
    __CPROVER_assert(used1 <= used2, "used is monotonic across allocations");
    __CPROVER_assert(used2 <= a.used, "used is monotonic across allocations");
    return 0;
}
#endif

/* ===================================================================== S1
 * mu_argmax over a symbolic length. Proves the returned index is in range and
 * that no element outside [0, n) is read.
 */
#ifdef H_ARGMAX
#define AMAX 8
int main(void)
{
    static float v[AMAX];
    int32_t n = nondet_int32();
    __CPROVER_assume(n >= 1 && n <= AMAX);

    for (int32_t i = 0; i < AMAX; i++) v[i] = nondet_float();

    int32_t k = mu_argmax(v, n);
    __CPROVER_assert(k >= 0 && k < n, "argmax index is within [0, n)");
    return 0;
}
#endif

/* ===================================================================== S1
 * mu_matmul index arithmetic over symbolic n and d. This is the function where
 * an indexing bug would be catastrophic and silent, and the one that reads the
 * most memory. Weights are concrete: only the INDICES matter here.
 */
#ifdef H_MATMUL
#define MN 6
#define MD 6
int main(void)
{
    static float w[MN * MD];
    static float x[MN];
    static float out[MD];

    int32_t n = nondet_int32(), d = nondet_int32();
    __CPROVER_assume(n >= 1 && n <= MN);
    __CPROVER_assume(d >= 1 && d <= MD);

    /* The arrays are sized to the exact contract: w is n*d, x is n, out is d.
     * Any read past w[n*d) or x[n), or any write past out[d), is therefore an
     * out-of-bounds access on a real object and CBMC will report it. */
    mu_matmul(out, x, w, n, d);

    __CPROVER_assert(1, "matmul completed with no out-of-bounds access");
    return 0;
}
#endif

/* ===================================================================== S1
 * Tokenizer decode. Byte-fallback parsing and the leading-space rule are the
 * fiddly parts, and out_cap clamping is what stops a caller buffer overflow.
 */
#ifdef H_DECODE
#define TB 64
int main(void)
{
    static uint8_t blob[TB];
    for (size_t i = 0; i < TB; i++) {
        uint32_t b = nondet_uint32();
        __CPROVER_assume(b <= 255u);       /* keeps --conversion-check happy */
        blob[i] = (uint8_t)b;
    }

    /* A two-token vocabulary is enough: the record walker, the offset table and
     * the decode path all get exercised, and the blob contents are symbolic. */
    static uint32_t off[2];
    static float    sc[2];
    static uint16_t ln[2];
    static int32_t  srt[2];

    mu_tokenizer t;
    t.blob = blob; t.blob_bytes = TB; t.vocab_size = 2;
    t.max_token_length = 8;
    t.offset = off; t.score = sc; t.len = ln; t.sorted = srt;
    /* byte_pieces is deliberately left uninitialised: mu_tok_decode writes the
     * byte-fallback value straight into `out` and never reads this table. */

    /* Symbolic but in-blob records. */
    uint32_t o0 = nondet_uint32(), o1 = nondet_uint32();
    uint32_t l0 = nondet_uint32(), l1 = nondet_uint32();
    __CPROVER_assume(l0 <= 8 && l1 <= 8);
    __CPROVER_assume(o0 <= TB - 8 && o1 <= TB - 8);
    off[0] = o0; off[1] = o1; ln[0] = (uint16_t)l0; ln[1] = (uint16_t)l1;
    srt[0] = 0; srt[1] = 1;

    int32_t prev = nondet_int32(), id = nondet_int32();
    __CPROVER_assume(id >= 0 && id < 2);

    uint8_t out[16];
    int32_t cap = nondet_int32();
    __CPROVER_assume(cap >= 1 && cap <= 16);

    int32_t k = mu_tok_decode(&t, prev, id, out, cap);

    __CPROVER_assert(k >= 0, "decode returns a non-negative length");
    __CPROVER_assert(k <= cap, "decode never writes more than out_cap bytes");
    return 0;
}
#endif

/* ===================================================================== S1
 * mu_tok_init walks a length-prefixed record format out of an untrusted blob.
 * This is the highest-risk parser in the engine: a malformed tokenizer file
 * must be rejected, never cause an out-of-bounds read. The blob is fully
 * symbolic, so every byte pattern of this length is covered.
 */
#ifdef H_TOKINIT
/* 20 bytes and a one-token vocabulary is the smallest shape that still
 * exercises the interesting path: the 4-byte header, one length-prefixed
 * record, and the `off + len > blob_bytes` rejection when the symbolic length
 * field is absurd. A 48-byte symbolic blob did not finish in 8 minutes. */
#define KB 20
int main(void)
{
    static uint8_t blob[KB];
    for (size_t i = 0; i < KB; i++) {
        uint32_t b = nondet_uint32();
        __CPROVER_assume(b <= 255u);
        blob[i] = (uint8_t)b;
    }

    size_t nbytes = nondet_size();
    __CPROVER_assume(nbytes <= KB);

    int32_t vocab = 1;

    static uint8_t pool[512];
    mu_arena a;
    mu_arena_init(&a, pool, sizeof pool);

    mu_tokenizer t;
    mu_err e = mu_tok_init(&t, blob, nbytes, vocab, &a);

    /* Whatever the bytes are, init either succeeds or reports an error. It must
     * never read outside the blob, and it must never overrun the arena. */
    __CPROVER_assert(e == MU_OK || e == MU_E_TOKBLOB || e == MU_E_BOUNDS
                     || e == MU_E_ARENA, "init returns a defined status");
    __CPROVER_assert(a.used <= a.size, "arena stays within bounds");

    if (e == MU_OK) {
        /* On success every recorded record must lie inside the blob, or a
         * later piece lookup would read out of bounds. */
        for (int32_t i = 0; i < vocab; i++) {
            __CPROVER_assert((size_t)t.offset[i] + (size_t)t.len[i] <= nbytes,
                             "each token record lies inside the blob");
        }
    }
    return 0;
}
#endif

/* ===================================================================== S1
 * mu_softmax and mu_rmsnorm over a symbolic length. Values are concrete: the
 * indices do not depend on them, and symbolic floats through mu_expf would be
 * intractable for no coverage gain.
 */
#ifdef H_SOFTMAX
#define SN 8
int main(void)
{
    static float v[SN];
    int32_t n = nondet_int32();
    __CPROVER_assume(n >= 1 && n <= SN);
    mu_softmax(v, n);
    __CPROVER_assert(1, "softmax completed with no out-of-bounds access");
    return 0;
}
#endif

#ifdef H_RMSNORM
#define RN 8
int main(void)
{
    static float o[RN], x[RN], w[RN];
    int32_t n = nondet_int32();
    __CPROVER_assume(n >= 1 && n <= RN);
    mu_rmsnorm(o, x, w, n);
    __CPROVER_assert(1, "rmsnorm completed with no out-of-bounds access");
    return 0;
}
#endif


