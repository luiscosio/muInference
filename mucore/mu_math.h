/* mu_math.h -- deterministic floating point primitives for muinference.
 *
 * DETERMINISM CONTRACT
 * --------------------
 * IEEE-754 (clause 5.4.1) mandates that +, -, *, / and sqrt be correctly
 * rounded. Any two conforming implementations therefore produce bit-identical
 * results for those five operations. Conversions between binary32 and binary64
 * are likewise mandated (clause 5.4.2).
 *
 * IEEE-754 does NOT mandate correct rounding for exp, log, sin, cos or pow.
 * Those are the "recommended" operations of clause 9.2, and real libm
 * implementations differ between vendors, versions and even ISA extension
 * paths within one library. Calling them destroys reproducibility.
 *
 * Every function in this header is built exclusively from mandated operations
 * and integer arithmetic. The result is bit-identical on any conforming
 * platform, provided the compiler is forbidden from reassociating or
 * contracting expressions. That requires, at minimum:
 *
 *     -fno-fast-math -ffp-contract=off -fno-unsafe-math-optimizations
 *
 * FMA contraction is disallowed because a*b+c fused into one instruction
 * rounds once where the source rounds twice, which changes the result.
 *
 * There is no <math.h> dependency and no libm at link time.
 */
#ifndef MU_MATH_H
#define MU_MATH_H

#include <stdint.h>

/* Correctly-rounded square root. IEEE-754 mandated, so this is reproducible.
 * Emitted as a single hardware instruction on every target we support. */
static inline float mu_sqrtf(float x)
{
#if defined(__CPROVER__)
    /* CBMC does not model inline assembly. Left as-is, it silently treats the
     * asm block as having no effect, which would make any verification result
     * about a function using sqrt meaningless. So under CBMC only, call sqrtf,
     * which CBMC models as the IEEE-754 square root -- exactly what the
     * assembly below computes. Both are the correctly-rounded operation clause
     * 5.4.1 mandates, so the substitution is sound.
     *
     * Declared rather than included to avoid pulling in all of <math.h>. This
     * introduces no libm dependency in the shipping build, which S3a checks
     * independently. */
    float sqrtf(float);
    return sqrtf(x);
#elif defined(__aarch64__)
    float r;
    __asm__("fsqrt %s0, %s1" : "=w"(r) : "w"(x));
    return r;
#elif defined(__x86_64__)
    float r;
    __asm__("sqrtss %1, %0" : "=x"(r) : "x"(x));
    return r;
#else
    return __builtin_sqrtf(x);
#endif
}

/* Deterministic exp for binary32 inputs.
 *
 * Method: argument reduction x = k*ln2 + r with |r| <= ln2/2, a degree-7
 * Taylor series for exp(r) evaluated in binary64, then scaling by 2^k built
 * directly as a bit pattern. Truncation error of the series on |r| <= 0.3466
 * is bounded by r^8/8! < 5.3e-9 relative, roughly 1/22 of a binary32 ULP, so
 * the binary64 result rounds to the correctly-rounded binary32 answer for
 * essentially all inputs.
 *
 * Uses only *, +, - and int->double bit assembly. No division, no libm. */
static inline float mu_expf(float xf)
{
    /* Overflow / underflow thresholds for binary32 results. */
    if (xf > 88.72283935546875f)  return 3.4028234663852886e+38f; /* ~FLT_MAX */
    if (xf < -103.97207641601562f) return 0.0f;

    const double INV_LN2 = 1.4426950408889634074;
    /* ln2 split so that k*LN2_HI is exact for |k| <= 1024. */
    const double LN2_HI  = 6.93147180369123816490e-01;
    const double LN2_LO  = 1.90821492927058770002e-10;

    double x = (double)xf;
    double t = x * INV_LN2;

    /* Round t to nearest integer, halves away from zero. Deterministic:
     * truncation toward zero is exactly specified by C, and the +-0.5 is
     * a mandated addition. */
    int32_t k = (int32_t)(t >= 0.0 ? t + 0.5 : t - 0.5);

    double kd = (double)k;
    double r  = (x - kd * LN2_HI) - kd * LN2_LO;

    /* exp(r) - Taylor, Horner form, fixed evaluation order. */
    const double c2 = 0.5;
    const double c3 = 1.6666666666666666e-01;
    const double c4 = 4.1666666666666664e-02;
    const double c5 = 8.3333333333333332e-03;
    const double c6 = 1.3888888888888889e-03;
    const double c7 = 1.9841269841269841e-04;

    double p = c6 + r * c7;
    p = c5 + r * p;
    p = c4 + r * p;
    p = c3 + r * p;
    p = c2 + r * p;
    p = 1.0 + r * p;
    p = 1.0 + r * p;

    /* 2^k as a binary64 bit pattern. k is within [-150, 128] here, so the
     * biased exponent 1023+k is always a valid normal encoding. */
    union { uint64_t u; double d; } scale;
    scale.u = (uint64_t)(1023 + k) << 52;

    return (float)(p * scale.d);
}

/* Logistic sigmoid, used by SwiGLU. Division is IEEE-754 mandated. */
static inline float mu_sigmoidf(float x)
{
    return 1.0f / (1.0f + mu_expf(-x));
}

#endif /* MU_MATH_H */
