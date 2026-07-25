/* mu_core.c -- freestanding deterministic Llama-2 forward pass.
 *
 * Arithmetically faithful to llama2.c's run.c (MIT, Andrej Karpathy), with
 * the transcendentals replaced per mu_math.h and RoPE replaced by a measured
 * table. Accumulation order is fixed and sequential everywhere; nothing in
 * this file may be parallelised without breaking the reproducibility claim.
 */

#include "mu_core.h"
#include "mu_math.h"

/* ---- freestanding memory primitives --------------------------------- */
/* Written out rather than calling libc so this object links with -nostdlib.
 * Byte-at-a-time is intentional: correctness and auditability over speed,
 * and these are not on the hot path. */
static void mu_memcpy(void *dst, const void *src, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
}

static void mu_memset(void *dst, uint8_t c, size_t n)
{
    uint8_t *d = (uint8_t *)dst;
    for (size_t i = 0; i < n; i++) d[i] = c;
}

/* Unsigned byte comparison with strcmp ordering semantics (C requires strcmp
 * to compare as unsigned char, so this matches upstream's qsort order even
 * though `char` signedness differs between x86-64 and AArch64). */
static int mu_bcmp_ord(const uint8_t *a, size_t na, const uint8_t *b, size_t nb)
{
    size_t n = na < nb ? na : nb;
    for (size_t i = 0; i < n; i++) {
        if (a[i] != b[i]) return (int)a[i] - (int)b[i];
    }
    if (na == nb) return 0;
    return na < nb ? -1 : 1;
}

/* ---- arena ---------------------------------------------------------- */
#define MU_ALIGN 64u

void mu_arena_init(mu_arena *a, void *base, size_t size)
{
    a->base = (uint8_t *)base;
    a->size = size;
    a->used = 0;
}

void *mu_arena_alloc(mu_arena *a, size_t bytes)
{
    size_t off = (a->used + (MU_ALIGN - 1)) & ~(size_t)(MU_ALIGN - 1);
    if (off + bytes > a->size) return 0;
    void *p = a->base + off;
    a->used = off + bytes;
    mu_memset(p, 0, bytes);
    return p;
}

static size_t mu_round_up(size_t n) { return (n + (MU_ALIGN - 1)) & ~(size_t)(MU_ALIGN - 1); }

size_t mu_arena_required(const mu_config *cfg)
{
    size_t dim    = (size_t)cfg->dim;
    size_t hidden = (size_t)cfg->hidden_dim;
    size_t kv_dim = ((size_t)cfg->dim * (size_t)cfg->n_kv_heads) / (size_t)cfg->n_heads;
    size_t cache  = (size_t)cfg->n_layers * (size_t)cfg->seq_len * kv_dim;
    size_t f      = sizeof(float);

    size_t t = 0;
    t += mu_round_up(dim * f);            /* x       */
    t += mu_round_up(dim * f);            /* xb      */
    t += mu_round_up(dim * f);            /* xb2     */
    t += mu_round_up(hidden * f);         /* hb      */
    t += mu_round_up(hidden * f);         /* hb2     */
    t += mu_round_up(dim * f);            /* q       */
    t += mu_round_up((size_t)cfg->n_heads * (size_t)cfg->seq_len * f); /* att */
    t += mu_round_up((size_t)cfg->vocab_size * f);   /* logits */
    t += mu_round_up(cache * f);          /* key_cache   */
    t += mu_round_up(cache * f);          /* value_cache */
    return t;
}

/* ---- model init ----------------------------------------------------- */
static mu_err mu_check_bounds(const mu_config *c)
{
    if (c->dim <= 0 || c->dim > MU_MAX_DIM)                 return MU_E_BOUNDS;
    if (c->hidden_dim <= 0 || c->hidden_dim > MU_MAX_HIDDEN) return MU_E_BOUNDS;
    if (c->n_layers <= 0 || c->n_layers > MU_MAX_LAYERS)     return MU_E_BOUNDS;
    if (c->n_heads <= 0 || c->n_heads > MU_MAX_HEADS)        return MU_E_BOUNDS;
    if (c->n_kv_heads <= 0 || c->n_kv_heads > c->n_heads)    return MU_E_BOUNDS;
    if (c->vocab_size <= 0 || c->vocab_size > MU_MAX_VOCAB)  return MU_E_BOUNDS;
    if (c->seq_len <= 0 || c->seq_len > MU_MAX_SEQ)          return MU_E_BOUNDS;
    if (c->dim % c->n_heads != 0)                            return MU_E_BOUNDS;
    if (c->n_heads % c->n_kv_heads != 0)                     return MU_E_BOUNDS;
    return MU_OK;
}

/* Lay the weight views over the blob. Identical ordering to run.c's
 * memory_map_weights, including the two skipped legacy RoPE tables. */
static void mu_map_weights(mu_weights *w, const mu_config *p,
                           const float *ptr, int shared_weights)
{
    size_t head_size = (size_t)p->dim / (size_t)p->n_heads;
    size_t n_layers  = (size_t)p->n_layers;
    size_t dim       = (size_t)p->dim;
    size_t hidden    = (size_t)p->hidden_dim;
    size_t n_kv      = (size_t)p->n_kv_heads;
    size_t n_h       = (size_t)p->n_heads;

    w->token_embedding_table = ptr; ptr += (size_t)p->vocab_size * dim;
    w->rms_att_weight = ptr;        ptr += n_layers * dim;
    w->wq = ptr;                    ptr += n_layers * dim * (n_h  * head_size);
    w->wk = ptr;                    ptr += n_layers * dim * (n_kv * head_size);
    w->wv = ptr;                    ptr += n_layers * dim * (n_kv * head_size);
    w->wo = ptr;                    ptr += n_layers * (n_h * head_size) * dim;
    w->rms_ffn_weight = ptr;        ptr += n_layers * dim;
    w->w1 = ptr;                    ptr += n_layers * dim * hidden;
    w->w2 = ptr;                    ptr += n_layers * hidden * dim;
    w->w3 = ptr;                    ptr += n_layers * dim * hidden;
    w->rms_final_weight = ptr;      ptr += dim;
    ptr += (size_t)p->seq_len * head_size / 2;   /* legacy freq_cis_real */
    ptr += (size_t)p->seq_len * head_size / 2;   /* legacy freq_cis_imag */
    w->wcls = shared_weights ? w->token_embedding_table : ptr;
}

mu_err mu_model_init(mu_model *m,
                     const void *ckpt, size_t ckpt_bytes,
                     const void *rope, size_t rope_bytes,
                     mu_arena *arena)
{
    if (ckpt_bytes < 7 * sizeof(int32_t)) return MU_E_BADMAGIC;

    const int32_t *hdr = (const int32_t *)ckpt;
    mu_config c;
    c.dim        = hdr[0];
    c.hidden_dim = hdr[1];
    c.n_layers   = hdr[2];
    c.n_heads    = hdr[3];
    c.n_kv_heads = hdr[4];
    c.vocab_size = hdr[5];
    c.seq_len    = hdr[6];

    /* Upstream signals unshared classifier weights with a negative vocab. */
    int shared_weights = c.vocab_size > 0 ? 1 : 0;
    if (c.vocab_size < 0) c.vocab_size = -c.vocab_size;

    mu_err e = mu_check_bounds(&c);
    if (e != MU_OK) return e;

    m->cfg       = c;
    m->head_size = c.dim / c.n_heads;
    m->kv_dim    = (c.dim * c.n_kv_heads) / c.n_heads;
    m->kv_mul    = c.n_heads / c.n_kv_heads;

    /* The measured RoPE table must match this config exactly. Size is the
     * check: [seq_len][head_size/2][2] float32. */
    size_t want_rope = (size_t)c.seq_len * (size_t)(m->head_size / 2) * 2u * sizeof(float);
    if (rope_bytes != want_rope) return MU_E_ROPE;
    m->rope = (const float *)rope;

    const float *wptr = (const float *)((const uint8_t *)ckpt + 7 * sizeof(int32_t));
    mu_map_weights(&m->w, &c, wptr, shared_weights);

    /* Arena carve-out. Order is fixed so the layout is reproducible. */
    size_t dim = (size_t)c.dim, hidden = (size_t)c.hidden_dim;
    size_t kv_dim = (size_t)m->kv_dim;
    size_t cache = (size_t)c.n_layers * (size_t)c.seq_len * kv_dim;

    m->s.x           = (float *)mu_arena_alloc(arena, dim * sizeof(float));
    m->s.xb          = (float *)mu_arena_alloc(arena, dim * sizeof(float));
    m->s.xb2         = (float *)mu_arena_alloc(arena, dim * sizeof(float));
    m->s.hb          = (float *)mu_arena_alloc(arena, hidden * sizeof(float));
    m->s.hb2         = (float *)mu_arena_alloc(arena, hidden * sizeof(float));
    m->s.q           = (float *)mu_arena_alloc(arena, dim * sizeof(float));
    m->s.att         = (float *)mu_arena_alloc(arena, (size_t)c.n_heads * (size_t)c.seq_len * sizeof(float));
    m->s.logits      = (float *)mu_arena_alloc(arena, (size_t)c.vocab_size * sizeof(float));
    m->s.key_cache   = (float *)mu_arena_alloc(arena, cache * sizeof(float));
    m->s.value_cache = (float *)mu_arena_alloc(arena, cache * sizeof(float));
    m->s.k = 0;
    m->s.v = 0;

    if (!m->s.x || !m->s.xb || !m->s.xb2 || !m->s.hb || !m->s.hb2 || !m->s.q ||
        !m->s.att || !m->s.logits || !m->s.key_cache || !m->s.value_cache)
        return MU_E_ARENA;

    return MU_OK;
}

/* ---- neural net blocks ---------------------------------------------- */
/* Sequential reduction. Do not vectorise with reassociation enabled. */
static void mu_rmsnorm(float *o, const float *x, const float *weight, int32_t size)
{
    float ss = 0.0f;
    for (int32_t j = 0; j < size; j++) ss += x[j] * x[j];
    ss /= (float)size;
    ss += 1e-5f;
    ss = 1.0f / mu_sqrtf(ss);
    for (int32_t j = 0; j < size; j++) o[j] = weight[j] * (ss * x[j]);
}

static void mu_softmax(float *x, int32_t size)
{
    float max_val = x[0];
    for (int32_t i = 1; i < size; i++) if (x[i] > max_val) max_val = x[i];
    float sum = 0.0f;
    for (int32_t i = 0; i < size; i++) {
        x[i] = mu_expf(x[i] - max_val);
        sum += x[i];
    }
    for (int32_t i = 0; i < size; i++) x[i] /= sum;
}

/* W (d,n) @ x (n,) -> xout (d,). One accumulator, ascending j. This exact
 * order is the reproducibility contract; ggml gets thread-invariance the
 * same way, by partitioning outputs rather than the reduction. */
static void mu_matmul(float *xout, const float *x, const float *w,
                      int32_t n, int32_t d)
{
    for (int32_t i = 0; i < d; i++) {
        float val = 0.0f;
        const float *wr = w + (size_t)i * (size_t)n;
        for (int32_t j = 0; j < n; j++) val += wr[j] * x[j];
        xout[i] = val;
    }
}

const float *mu_forward(mu_model *m, int32_t token, int32_t pos)
{
    const mu_config *p = &m->cfg;
    const mu_weights *w = &m->w;
    mu_state *s = &m->s;

    float *x = s->x;
    int32_t dim = p->dim;
    int32_t kv_dim = m->kv_dim;
    int32_t kv_mul = m->kv_mul;
    int32_t hidden_dim = p->hidden_dim;
    int32_t head_size = m->head_size;
    int32_t rope_stride = (head_size / 2) * 2;

    /* Precomputed 1/sqrt(head_size): a compile-time-constant-shaped value,
     * removing one of the two runtime sqrt calls from the original. */
    const float att_scale = 1.0f / mu_sqrtf((float)head_size);

    mu_memcpy(x, w->token_embedding_table + (size_t)token * (size_t)dim,
              (size_t)dim * sizeof(float));

    for (int32_t l = 0; l < p->n_layers; l++) {

        mu_rmsnorm(s->xb, x, w->rms_att_weight + (size_t)l * dim, dim);

        size_t loff = (size_t)l * (size_t)p->seq_len * (size_t)kv_dim;
        s->k = s->key_cache   + loff + (size_t)pos * kv_dim;
        s->v = s->value_cache + loff + (size_t)pos * kv_dim;

        mu_matmul(s->q, s->xb, w->wq + (size_t)l * dim * dim,      dim, dim);
        mu_matmul(s->k, s->xb, w->wk + (size_t)l * dim * kv_dim,   dim, kv_dim);
        mu_matmul(s->v, s->xb, w->wv + (size_t)l * dim * kv_dim,   dim, kv_dim);

        /* RoPE from the measured table. Upstream computes
         *   freq = 1/powf(10000, head_dim/head_size); fcr=cosf(pos*freq)
         * here those are table lookups, so powf/cosf/sinf leave the TCB. */
        const float *rope_pos = m->rope + (size_t)pos * (size_t)rope_stride;
        for (int32_t i = 0; i < dim; i += 2) {
            int32_t head_dim = i % head_size;
            float fcr = rope_pos[head_dim];       /* cos, at index (head_dim/2)*2 */
            float fci = rope_pos[head_dim + 1];   /* sin                          */
            int32_t rotn = i < kv_dim ? 2 : 1;
            for (int32_t v = 0; v < rotn; v++) {
                float *vec = (v == 0) ? s->q : s->k;
                float v0 = vec[i];
                float v1 = vec[i + 1];
                vec[i]     = v0 * fcr - v1 * fci;
                vec[i + 1] = v0 * fci + v1 * fcr;
            }
        }

        /* Multi-head attention. Sequential over heads: no omp. */
        for (int32_t h = 0; h < p->n_heads; h++) {
            const float *q = s->q + (size_t)h * head_size;
            float *att = s->att + (size_t)h * p->seq_len;

            for (int32_t t = 0; t <= pos; t++) {
                const float *k = s->key_cache + loff + (size_t)t * kv_dim
                               + (size_t)(h / kv_mul) * head_size;
                float score = 0.0f;
                for (int32_t i = 0; i < head_size; i++) score += q[i] * k[i];
                score *= att_scale;
                att[t] = score;
            }

            mu_softmax(att, pos + 1);

            float *xb = s->xb + (size_t)h * head_size;
            mu_memset(xb, 0, (size_t)head_size * sizeof(float));
            for (int32_t t = 0; t <= pos; t++) {
                const float *v = s->value_cache + loff + (size_t)t * kv_dim
                               + (size_t)(h / kv_mul) * head_size;
                float a = att[t];
                for (int32_t i = 0; i < head_size; i++) xb[i] += a * v[i];
            }
        }

        mu_matmul(s->xb2, s->xb, w->wo + (size_t)l * dim * dim, dim, dim);
        for (int32_t i = 0; i < dim; i++) x[i] += s->xb2[i];

        mu_rmsnorm(s->xb, x, w->rms_ffn_weight + (size_t)l * dim, dim);

        mu_matmul(s->hb,  s->xb, w->w1 + (size_t)l * dim * hidden_dim, dim, hidden_dim);
        mu_matmul(s->hb2, s->xb, w->w3 + (size_t)l * dim * hidden_dim, dim, hidden_dim);

        /* SwiGLU */
        for (int32_t i = 0; i < hidden_dim; i++) {
            float val = s->hb[i];
            val *= mu_sigmoidf(val);
            val *= s->hb2[i];
            s->hb[i] = val;
        }

        mu_matmul(s->xb, s->hb, w->w2 + (size_t)l * dim * hidden_dim, hidden_dim, dim);
        for (int32_t i = 0; i < dim; i++) x[i] += s->xb[i];
    }

    mu_rmsnorm(x, x, w->rms_final_weight, dim);
    mu_matmul(s->logits, x, w->wcls, dim, p->vocab_size);
    return s->logits;
}

/* Greedy. Strict > so the lowest index wins ties, matching upstream's
 * sample_argmax and making the choice order-independent. */
int32_t mu_argmax(const float *v, int32_t n)
{
    int32_t best_i = 0;
    float best_p = v[0];
    for (int32_t i = 1; i < n; i++) {
        if (v[i] > best_p) { best_p = v[i]; best_i = i; }
    }
    return best_i;
}

/* ---- tokenizer ------------------------------------------------------ */
size_t mu_tok_arena_required(int32_t vocab_size)
{
    size_t v = (size_t)vocab_size;
    return mu_round_up(v * sizeof(uint32_t))    /* offset */
         + mu_round_up(v * sizeof(float))       /* score  */
         + mu_round_up(v * sizeof(uint16_t))    /* len    */
         + mu_round_up(v * sizeof(int32_t));    /* sorted */
}

/* Little-endian loads. Explicit so the core does not depend on host
 * endianness or on unaligned access being permitted. */
static uint32_t ld_u32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static float ld_f32(const uint8_t *p)
{
    union { uint32_t u; float f; } c; c.u = ld_u32(p); return c.f;
}

static const uint8_t *tok_ptr(const mu_tokenizer *t, int32_t id)
{
    return t->blob + t->offset[id];
}

/* Deterministic bottom-up merge sort on token ids by strcmp order. Chosen
 * over qsort because qsort is (a) libc and (b) not required to be stable, so
 * its output can differ between implementations for equal keys. */
static void tok_sort(mu_tokenizer *t, int32_t *tmp)
{
    int32_t n = t->vocab_size;
    int32_t *src = t->sorted, *dst = tmp;

    for (int32_t i = 0; i < n; i++) src[i] = i;

    for (int32_t width = 1; width < n; width *= 2) {
        for (int32_t i = 0; i < n; i += 2 * width) {
            int32_t lo = i;
            int32_t mid = (i + width < n) ? i + width : n;
            int32_t hi = (i + 2 * width < n) ? i + 2 * width : n;
            int32_t a = lo, b = mid, o = lo;
            while (a < mid && b < hi) {
                const uint8_t *pa = tok_ptr(t, src[a]);
                const uint8_t *pb = tok_ptr(t, src[b]);
                int c = mu_bcmp_ord(pa, t->len[src[a]], pb, t->len[src[b]]);
                /* <= keeps the sort stable, so equal pieces resolve by id */
                dst[o++] = (c <= 0) ? src[a++] : src[b++];
            }
            while (a < mid) dst[o++] = src[a++];
            while (b < hi)  dst[o++] = src[b++];
        }
        int32_t *sw = src; src = dst; dst = sw;
    }
    if (src != t->sorted) {
        for (int32_t i = 0; i < n; i++) t->sorted[i] = src[i];
    }
}

mu_err mu_tok_init(mu_tokenizer *t, const void *blob, size_t blob_bytes,
                   int32_t vocab_size, mu_arena *arena)
{
    if (blob_bytes < 4) return MU_E_TOKBLOB;
    if (vocab_size <= 0 || vocab_size > MU_MAX_VOCAB) return MU_E_BOUNDS;

    t->blob = (const uint8_t *)blob;
    t->blob_bytes = blob_bytes;
    t->vocab_size = vocab_size;
    t->max_token_length = ld_u32(t->blob);

    for (int32_t i = 0; i < 256; i++) {
        t->byte_pieces[i * 2]     = (uint8_t)i;
        t->byte_pieces[i * 2 + 1] = 0;
    }

    t->offset = (uint32_t *)mu_arena_alloc(arena, (size_t)vocab_size * sizeof(uint32_t));
    t->score  = (float    *)mu_arena_alloc(arena, (size_t)vocab_size * sizeof(float));
    t->len    = (uint16_t *)mu_arena_alloc(arena, (size_t)vocab_size * sizeof(uint16_t));
    t->sorted = (int32_t  *)mu_arena_alloc(arena, (size_t)vocab_size * sizeof(int32_t));
    if (!t->offset || !t->score || !t->len || !t->sorted) return MU_E_ARENA;

    /* Walk the blob: [u32 max_len]{ f32 score, i32 len, u8 bytes[len] }* */
    size_t off = 4;
    for (int32_t i = 0; i < vocab_size; i++) {
        if (off + 8 > blob_bytes) return MU_E_TOKBLOB;
        t->score[i] = ld_f32(t->blob + off); off += 4;
        uint32_t len = ld_u32(t->blob + off); off += 4;
        if (len > 0xFFFFu || off + len > blob_bytes) return MU_E_TOKBLOB;
        t->offset[i] = (uint32_t)off;
        t->len[i] = (uint16_t)len;
        off += len;
    }

    /* Borrow scratch for the merge sort, then hand it back. */
    size_t mark = arena->used;
    int32_t *tmp = (int32_t *)mu_arena_alloc(arena, (size_t)vocab_size * sizeof(int32_t));
    if (!tmp) return MU_E_ARENA;
    tok_sort(t, tmp);
    arena->used = mark;

    return MU_OK;
}

const uint8_t *mu_tok_piece(const mu_tokenizer *t, int32_t id, int32_t *out_len)
{
    if (id < 0 || id >= t->vocab_size) { *out_len = 0; return 0; }
    *out_len = (int32_t)t->len[id];
    return t->blob + t->offset[id];
}

/* Binary search over the sorted index. */
static int32_t tok_lookup(const mu_tokenizer *t, const uint8_t *s, size_t n)
{
    int32_t lo = 0, hi = t->vocab_size - 1;
    while (lo <= hi) {
        int32_t mid = lo + (hi - lo) / 2;
        int32_t id = t->sorted[mid];
        int c = mu_bcmp_ord(tok_ptr(t, id), t->len[id], s, n);
        if (c == 0) return id;
        if (c < 0) lo = mid + 1; else hi = mid - 1;
    }
    return -1;
}

static int hexval(uint8_t c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

int32_t mu_tok_decode(const mu_tokenizer *t, int32_t prev, int32_t id,
                      uint8_t *out, int32_t out_cap)
{
    int32_t len = 0;
    const uint8_t *piece = mu_tok_piece(t, id, &len);
    if (!piece) return 0;

    /* sentencepiece strips one leading space directly after BOS */
    if (prev == 1 && len > 0 && piece[0] == ' ') { piece++; len--; }

    /* byte fallback: a piece spelled exactly "<0xNN>" denotes raw byte NN */
    if (len == 6 && piece[0] == '<' && piece[1] == '0' &&
        (piece[2] == 'x' || piece[2] == 'X') && piece[5] == '>') {
        int hi = hexval(piece[3]), lo = hexval(piece[4]);
        if (hi >= 0 && lo >= 0) {
            if (out_cap < 1) return 0;
            out[0] = (uint8_t)((hi << 4) | lo);
            return 1;
        }
    }

    if (len > out_cap) len = out_cap;
    mu_memcpy(out, piece, (size_t)len);
    return len;
}

mu_err mu_tok_encode(const mu_tokenizer *t, const uint8_t *text, size_t text_len,
                     int add_bos, int add_eos,
                     int32_t *tokens, int32_t *n_tokens, int32_t tokens_cap,
                     uint8_t *scratch, size_t scratch_bytes)
{
    if (scratch_bytes < (size_t)t->max_token_length * 2 + 3) return MU_E_ARENA;

    int32_t n = 0;
    #define PUSH(v) do { if (n >= tokens_cap) return MU_E_ARENA; tokens[n++] = (v); } while (0)

    if (add_bos) PUSH(1);

    /* add_dummy_prefix: a leading " " token, unless the text is empty */
    if (text_len > 0) {
        static const uint8_t sp[1] = { ' ' };
        int32_t dp = tok_lookup(t, sp, 1);
        if (dp != -1) PUSH(dp);
    }

    /* Split into UTF-8 codepoints, mapping each to a token or byte fallback */
    size_t sl = 0;
    for (size_t i = 0; i < text_len; i++) {
        uint8_t c = text[i];
        if ((c & 0xC0) != 0x80) sl = 0;          /* not a continuation byte */
        scratch[sl++] = c;
        if (i + 1 < text_len && (text[i + 1] & 0xC0) == 0x80 && sl < 4) continue;

        int32_t id = tok_lookup(t, scratch, sl);
        if (id != -1) {
            PUSH(id);
        } else {
            /* first 3 vocab entries are <unk>,<s>,</s>, so byte b is at b+3 */
            for (size_t k = 0; k < sl; k++) PUSH((int32_t)scratch[k] + 3);
        }
        sl = 0;
    }

    /* Greedy BPE merge by vocab score. Ties resolve to the lowest id because
     * the comparison is strict >, and to the earliest position because we
     * scan left to right. Deterministic. */
    for (;;) {
        float best_score = -1e10f;
        int32_t best_id = -1, best_idx = -1;

        for (int32_t i = 0; i < n - 1; i++) {
            int32_t la = 0, lb = 0;
            const uint8_t *pa = mu_tok_piece(t, tokens[i], &la);
            const uint8_t *pb = mu_tok_piece(t, tokens[i + 1], &lb);
            if ((size_t)(la + lb) > scratch_bytes) continue;
            mu_memcpy(scratch, pa, (size_t)la);
            mu_memcpy(scratch + la, pb, (size_t)lb);
            int32_t id = tok_lookup(t, scratch, (size_t)(la + lb));
            if (id != -1 && t->score[id] > best_score) {
                best_score = t->score[id];
                best_id = id;
                best_idx = i;
            }
        }

        if (best_idx == -1) break;
        tokens[best_idx] = best_id;
        for (int32_t i = best_idx + 1; i < n - 1; i++) tokens[i] = tokens[i + 1];
        n--;
    }

    if (add_eos) PUSH(2);
    #undef PUSH

    *n_tokens = n;
    return MU_OK;
}
