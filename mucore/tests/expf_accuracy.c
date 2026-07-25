/* Accuracy check for mu_expf against the platform libm.
 *
 * Determinism is worthless without accuracy: a reproducibly wrong exp would
 * pass every test in determinism.sh. This measures mu_expf's error in ULPs
 * against the host libm over the input range the transformer actually uses,
 * plus a wide sweep.
 *
 * Ranges that matter:
 *   softmax : x - max_val, always <= 0, realistically [-40, 0]
 *   SwiGLU  : -val for the sigmoid, realistically [-30, 30]
 *
 * This test links libm on purpose. It is a test, not part of the core.
 */
#include <stdio.h>
#include <stdint.h>
#include <math.h>
#include "mu_math.h"

static int32_t ulp_diff(float a, float b)
{
    union { float f; int32_t i; } ua, ub;
    ua.f = a; ub.f = b;
    if (ua.i < 0) ua.i = 0x80000000 - ua.i;
    if (ub.i < 0) ub.i = 0x80000000 - ub.i;
    int32_t d = ua.i - ub.i;
    return d < 0 ? -d : d;
}

static void sweep(const char *name, double lo, double hi, int n)
{
    int32_t worst = 0;
    double worst_x = 0;
    long exact = 0, within1 = 0;

    for (int i = 0; i <= n; i++) {
        double t = lo + (hi - lo) * ((double)i / (double)n);
        float x = (float)t;
        float mine = mu_expf(x);
        float ref  = expf(x);
        int32_t u = ulp_diff(mine, ref);
        if (u == 0) exact++;
        if (u <= 1) within1++;
        if (u > worst) { worst = u; worst_x = x; }
    }
    printf("  %-22s n=%-8d exact=%6.2f%%  <=1ulp=%6.2f%%  max=%d ulp (at x=%.6g)\n",
           name, n,
           100.0 * (double)exact / (double)(n + 1),
           100.0 * (double)within1 / (double)(n + 1),
           worst, worst_x);
}

int main(void)
{
    printf("\nmu_expf vs platform libm expf\n");
    printf("-----------------------------------------------------------------\n");
    sweep("softmax range [-40,0]",   -40.0,   0.0, 4000000);
    sweep("swiglu range [-30,30]",   -30.0,  30.0, 4000000);
    sweep("wide [-87,88]",           -87.0,  88.0, 4000000);
    sweep("near zero [-1,1]",         -1.0,   1.0, 4000000);

    /* Spot checks against values that are exactly representable concepts. */
    printf("\n  spot checks\n");
    struct { float x; const char *what; } sp[] = {
        { 0.0f,  "exp(0) must be exactly 1" },
        { 1.0f,  "exp(1)" },
        { -1.0f, "exp(-1)" },
        { 88.0f, "near overflow" },
        { -87.0f,"near underflow" },
    };
    for (unsigned i = 0; i < sizeof sp / sizeof sp[0]; i++) {
        float m = mu_expf(sp[i].x), r = expf(sp[i].x);
        printf("    x=%-8.4g mine=%-16.9g libm=%-16.9g ulp=%-3d  %s\n",
               sp[i].x, (double)m, (double)r, ulp_diff(m, r), sp[i].what);
    }

    if (mu_expf(0.0f) != 1.0f) {
        printf("\n  FAIL: exp(0) != 1\n");
        return 1;
    }
    printf("\n  exp(0) == 1.0 exactly: OK\n\n");
    return 0;
}
