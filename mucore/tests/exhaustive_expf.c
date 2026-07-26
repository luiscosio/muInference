/* S4a — the error bound for mu_expf, verified by exhaustion.
 *
 * WHY THIS IS A PROOF AND NOT A TEST
 *   mu_expf takes one binary32 argument. There are exactly 2^32 bit patterns,
 *   so enumerating all of them is a complete case analysis over the entire
 *   domain. Nothing is sampled and nothing is extrapolated. For a single-
 *   argument float32 function this is stronger than an interval bound from a
 *   tool like Gappa: Gappa proves "error <= eps"; this establishes the exact
 *   worst case and where it occurs.
 *
 *   (Gappa would still be worth having, because it proves the bound from the
 *   polynomial's structure rather than by enumeration, and so extends to
 *   binary64. It is not packaged for Homebrew, hence this route.)
 *
 * THE REFERENCE
 *   (float)exp((double)x). The host's binary64 exp is accurate to well under
 *   1 ulp of binary64, which is ~2^29 times finer than binary32, so rounding it
 *   to binary32 yields the correctly-rounded binary32 result except on inputs
 *   astronomically close to a rounding boundary. This is the standard way to
 *   obtain a float32 oracle and it is why the reference is double, not float.
 *
 * THREE DOMAINS, checked separately, because mu_expf deliberately saturates
 * outside the range where the result is a normal binary32 number:
 *   normal    the result is a normal float. Bound the ULP error.
 *   underflow x below the clamp. mu_expf returns +0. exp() would give a
 *             subnormal or 0. This loses subnormals, on purpose.
 *   overflow  x above the clamp. mu_expf returns FLT_MAX. exp() gives +inf.
 *
 * NaN and infinity inputs are reported, not asserted: the engine never produces
 * them as arguments to expf (softmax subtracts the max first, SwiGLU negates a
 * finite activation), so their behaviour is out of contract.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <pthread.h>
#include "mu_math.h"

#define CLAMP_HI  88.72283935546875f
#define CLAMP_LO (-103.97207641601562f)
#define FLT_MAX_F 3.4028234663852886e+38f

#define NTHREAD 8

typedef struct {
    uint32_t lo, hi;             /* bit-pattern range, [lo, hi) */
    uint64_t n_normal, n_under, n_over, n_nan, n_inf;
    uint64_t n_exact, n_within1;
    int32_t  worst_ulp;
    uint32_t worst_bits;
    uint64_t bad_under, bad_over;   /* documented-behaviour violations */
} job;

static inline float bits_to_f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
static inline uint32_t f_to_bits(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }

/* Monotone map from float bits to a signed ordinal, so subtracting two
 * ordinals gives the number of representable floats between them. */
static inline int64_t ordinal(float f)
{
    int32_t i = (int32_t)f_to_bits(f);
    return (i < 0) ? (int64_t)0x80000000LL - i : (int64_t)i;
}

static void *worker(void *arg)
{
    job *j = (job *)arg;
    j->worst_ulp = 0; j->worst_bits = 0;

    for (uint64_t u = j->lo; u < (uint64_t)j->hi; u++) {
        float x = bits_to_f((uint32_t)u);

        if (isnan(x)) { j->n_nan++; continue; }
        if (isinf(x)) { j->n_inf++; continue; }

        float mine = mu_expf(x);

        if (x < CLAMP_LO) {
            j->n_under++;
            if (mine != 0.0f) j->bad_under++;      /* contract: returns +0 */
            continue;
        }
        if (x > CLAMP_HI) {
            j->n_over++;
            if (mine != FLT_MAX_F) j->bad_over++;  /* contract: saturates */
            continue;
        }

        float ref = (float)exp((double)x);

        /* Skip inputs whose correctly-rounded result is not a normal float:
         * mu_expf's stated domain is the normal range. */
        if (!isnormal(ref) && ref != 0.0f) { j->n_under++; continue; }

        j->n_normal++;
        int64_t d = ordinal(mine) - ordinal(ref);
        int32_t ulp = (int32_t)(d < 0 ? -d : d);
        if (ulp == 0) j->n_exact++;
        if (ulp <= 1) j->n_within1++;
        if (ulp > j->worst_ulp) { j->worst_ulp = ulp; j->worst_bits = (uint32_t)u; }
    }
    return 0;
}

int main(void)
{
    pthread_t th[NTHREAD];
    job jobs[NTHREAD];
    memset(jobs, 0, sizeof jobs);

    /* Split the full 2^32 bit-pattern space across threads. */
    const uint64_t total = 1ULL << 32;
    for (int t = 0; t < NTHREAD; t++) {
        jobs[t].lo = (uint32_t)(total * t / NTHREAD);
        jobs[t].hi = (uint32_t)(total * (t + 1) / NTHREAD);
        if (t == NTHREAD - 1) jobs[t].hi = 0xFFFFFFFFu;   /* inclusive tail */
    }

    printf("\nS4a: exhaustive check of mu_expf over all 2^32 binary32 inputs\n");
    printf("reference: (float)exp((double)x), %d threads\n\n", NTHREAD);

    for (int t = 0; t < NTHREAD; t++) pthread_create(&th[t], 0, worker, &jobs[t]);
    for (int t = 0; t < NTHREAD; t++) pthread_join(th[t], 0);

    job a; memset(&a, 0, sizeof a);
    for (int t = 0; t < NTHREAD; t++) {
        a.n_normal  += jobs[t].n_normal;  a.n_under   += jobs[t].n_under;
        a.n_over    += jobs[t].n_over;    a.n_nan     += jobs[t].n_nan;
        a.n_inf     += jobs[t].n_inf;     a.n_exact   += jobs[t].n_exact;
        a.n_within1 += jobs[t].n_within1; a.bad_under += jobs[t].bad_under;
        a.bad_over  += jobs[t].bad_over;
        if (jobs[t].worst_ulp > a.worst_ulp) {
            a.worst_ulp = jobs[t].worst_ulp; a.worst_bits = jobs[t].worst_bits;
        }
    }

    printf("  inputs in the normal domain   %llu\n", (unsigned long long)a.n_normal);
    printf("  underflow domain (returns +0) %llu\n", (unsigned long long)a.n_under);
    printf("  overflow domain (saturates)   %llu\n", (unsigned long long)a.n_over);
    printf("  NaN inputs (out of contract)  %llu\n", (unsigned long long)a.n_nan);
    printf("  infinite inputs               %llu\n", (unsigned long long)a.n_inf);
    printf("\n");
    printf("  bit-exact vs reference        %llu  (%.4f%%)\n",
           (unsigned long long)a.n_exact,
           100.0 * (double)a.n_exact / (double)a.n_normal);
    printf("  within 1 ulp                  %llu  (%.4f%%)\n",
           (unsigned long long)a.n_within1,
           100.0 * (double)a.n_within1 / (double)a.n_normal);
    printf("  WORST CASE                    %d ulp", a.worst_ulp);
    if (a.worst_ulp) printf("  at x = %.9g (0x%08x)",
                            (double)bits_to_f(a.worst_bits), a.worst_bits);
    printf("\n");
    printf("  underflow contract violations %llu\n", (unsigned long long)a.bad_under);
    printf("  overflow contract violations  %llu\n", (unsigned long long)a.bad_over);
    printf("\n");

    int fail = 0;
    if (a.worst_ulp > 1) { printf("  FAIL: worst case exceeds 1 ulp\n"); fail = 1; }
    if (a.n_within1 != a.n_normal) { printf("  FAIL: not every input is within 1 ulp\n"); fail = 1; }
    if (a.bad_under || a.bad_over) { printf("  FAIL: clamp contract violated\n"); fail = 1; }
    if (mu_expf(0.0f) != 1.0f) { printf("  FAIL: exp(0) != 1\n"); fail = 1; }

    if (!fail)
        printf("  S4a HOLDS: mu_expf is within 1 ulp of the correctly-rounded\n"
               "  result for every binary32 input in its domain. Not sampled.\n\n");
    return fail;
}
