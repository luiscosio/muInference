/* Is (float)sqrt((double)x) the same as the hardware binary32 sqrt?
 *
 * CompCert cannot compile inline asm, so under CompCert mu_sqrtf computes in
 * binary64 and rounds back. Double rounding is provably harmless for sqrt when
 * the wider format carries at least 2p+2 bits and binary64's 53 exceeds the 50
 * binary32 needs -- but a theorem cited is weaker than a theorem checked, and
 * for a one-argument binary32 function the whole domain is only 2^32 cases.
 *
 * So: enumerate every input and compare bit patterns.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <pthread.h>

#define NTHREAD 8

typedef struct { uint32_t lo, hi; uint64_t checked, differ; uint32_t first_bad; } job;

static inline float b2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
static inline uint32_t f2b(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }

static inline float hw_sqrtf(float x)
{
#if defined(__aarch64__)
    float r; __asm__("fsqrt %s0, %s1" : "=w"(r) : "w"(x)); return r;
#elif defined(__x86_64__)
    float r; __asm__("sqrtss %1, %0" : "=x"(r) : "x"(x)); return r;
#else
    return sqrtf(x);
#endif
}

static void *worker(void *arg)
{
    job *j = arg; j->checked = j->differ = 0; j->first_bad = 0;
    for (uint64_t u = j->lo; u < (uint64_t)j->hi; u++) {
        float x = b2f((uint32_t)u);
        if (isnan(x) || x < 0.0f) continue;      /* sqrt of a negative is NaN */
        float a = hw_sqrtf(x);
        float b = (float)sqrt((double)x);
        j->checked++;
        if (f2b(a) != f2b(b)) { if (!j->differ) j->first_bad = (uint32_t)u; j->differ++; }
    }
    return 0;
}

int main(void)
{
    pthread_t th[NTHREAD]; job jb[NTHREAD]; memset(jb, 0, sizeof jb);
    const uint64_t total = 1ULL << 32;
    for (int t = 0; t < NTHREAD; t++) {
        jb[t].lo = (uint32_t)(total * t / NTHREAD);
        jb[t].hi = (uint32_t)(total * (t + 1) / NTHREAD);
        if (t == NTHREAD - 1) jb[t].hi = 0xFFFFFFFFu;
    }
    printf("\nhardware binary32 sqrt  vs  (float)sqrt((double)x)\n");
    printf("enumerating all 2^32 inputs on %d threads\n\n", NTHREAD);
    for (int t = 0; t < NTHREAD; t++) pthread_create(&th[t], 0, worker, &jb[t]);
    for (int t = 0; t < NTHREAD; t++) pthread_join(th[t], 0);

    uint64_t checked = 0, differ = 0; uint32_t bad = 0;
    for (int t = 0; t < NTHREAD; t++) {
        checked += jb[t].checked; differ += jb[t].differ;
        if (jb[t].differ && !bad) bad = jb[t].first_bad;
    }
    printf("  non-negative inputs checked  %llu\n", (unsigned long long)checked);
    printf("  differing bit patterns       %llu\n", (unsigned long long)differ);
    if (differ) { printf("  first at x = %.9g (0x%08x)\n", (double)b2f(bad), bad);
                  printf("\n  FAIL\n\n"); return 1; }
    printf("\n  IDENTICAL for every input. The CompCert substitution is exact.\n\n");
    return 0;
}
