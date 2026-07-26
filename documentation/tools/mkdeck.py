#!/usr/bin/env python3
"""muInference deck. Plain wording, no narrative framing."""
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE

BG     = RGBColor(0x11, 0x16, 0x1D)
PANEL  = RGBColor(0x1A, 0x21, 0x2B)
PANEL2 = RGBColor(0x22, 0x2B, 0x38)
FG     = RGBColor(0xE8, 0xEC, 0xF1)
MUTED  = RGBColor(0x8B, 0x99, 0xA8)
CYAN   = RGBColor(0x36, 0xD3, 0xC4)
AMBER  = RGBColor(0xF2, 0xB0, 0x37)
RED    = RGBColor(0xE5, 0x5C, 0x5C)
VIOLET = RGBColor(0x9B, 0x8C, 0xF0)

SANS, MONO = "Helvetica Neue", "Menlo"
W, H = Inches(13.333), Inches(7.5)

prs = Presentation()
prs.slide_width, prs.slide_height = W, H


def slide():
    s = prs.slides.add_slide(prs.slide_layouts[6])
    bg = s.shapes.add_shape(MSO_SHAPE.RECTANGLE, 0, 0, W, H)
    bg.fill.solid(); bg.fill.fore_color.rgb = BG
    bg.line.fill.background(); bg.shadow.inherit = False
    return s


def text(s, x, y, w, h, runs, size=18, color=FG, font=SANS, align=PP_ALIGN.LEFT,
         bold=False, space_after=6, line=1.25):
    tb = s.shapes.add_textbox(x, y, w, h)
    tf = tb.text_frame
    tf.word_wrap = True
    tf.margin_left = tf.margin_right = tf.margin_top = tf.margin_bottom = 0
    if isinstance(runs, str):
        runs = [(runs, {})]
    for i, (txt, opt) in enumerate(runs):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = opt.get("align", align)
        p.space_after = Pt(opt.get("space_after", space_after))
        p.line_spacing = opt.get("line", line)
        r = p.add_run(); r.text = txt
        f = r.font
        f.size = Pt(opt.get("size", size)); f.color.rgb = opt.get("color", color)
        f.name = opt.get("font", font); f.bold = opt.get("bold", bold)
    return tb


def panel(s, x, y, w, h, fill=PANEL, edge=None, radius=True):
    shp = s.shapes.add_shape(
        MSO_SHAPE.ROUNDED_RECTANGLE if radius else MSO_SHAPE.RECTANGLE, x, y, w, h)
    shp.fill.solid(); shp.fill.fore_color.rgb = fill
    if edge:
        shp.line.color.rgb = edge; shp.line.width = Pt(1.25)
    else:
        shp.line.fill.background()
    shp.shadow.inherit = False
    if radius:
        try: shp.adjustments[0] = 0.06
        except Exception: pass
    return shp


def title(s, head, sub=None):
    text(s, Inches(0.85), Inches(0.62), Inches(11.6), Inches(0.7), head, size=33, bold=True)
    if sub:
        text(s, Inches(0.85), Inches(1.34), Inches(11.6), Inches(0.4), sub, size=15, color=MUTED)


def footer(s, n):
    text(s, Inches(0.85), Inches(6.98), Inches(9), Inches(0.3),
         "muInference", size=10, color=MUTED)
    text(s, Inches(11.6), Inches(6.98), Inches(0.85), Inches(0.3),
         str(n), size=10, color=MUTED, align=PP_ALIGN.RIGHT)


def rows(s, y0, data, pitch=Inches(0.56), cols=((1.1, 3.2, 13, FG, SANS),)):
    y = y0
    for rec in data:
        panel(s, Inches(0.85), y, Inches(11.6), pitch - Inches(0.06))
        for val, (x, w, sz, col, fnt) in zip(rec, cols):
            if callable(col):
                col = col(rec)
            text(s, Inches(x), y + Inches(0.13), Inches(w), Inches(0.3),
                 val, size=sz, color=col, font=fnt)
        y += pitch
    return y


# ---- 1 title ---------------------------------------------------------
s = slide()
panel(s, Inches(0), Inches(0), Inches(0.18), H, fill=CYAN, radius=False)
text(s, Inches(1.1), Inches(2.3), Inches(11), Inches(1.1), "μInference", size=62, bold=True)
text(s, Inches(1.1), Inches(3.5), Inches(11), Inches(0.6),
     "A verifiable minimum inference engine for LLMs", size=24, color=CYAN)
text(s, Inches(1.1), Inches(4.35), Inches(10), Inches(1.0), [
    ("692 lines of trusted code.", {}),
    ("Same output on nine different builds, bit for bit.", {}),
    ("Runs on seL4, a formally verified microkernel.", {}),
], size=16, color=MUTED, line=1.35, space_after=4)
text(s, Inches(1.1), Inches(6.4), Inches(11), Inches(0.3),
     "SL5 Task Force  ·  July 2026", size=12, color=MUTED)

# ---- 2 what it is ----------------------------------------------------
s = slide(); title(s, "What it is", "A small LLM inference engine built to be checked.")
cards = [
    ("Small", "692 lines of code do the inference.\nNo libc. No libm. No heap. No threads.", CYAN),
    ("Reproducible", "Same weights and prompt give the same\nlogits on every system tested.", CYAN),
    ("Isolated", "Runs as one seL4 protection domain.\nNo device access. No Linux.", VIOLET),
    ("Bounded", "Memory use is fixed at build time.\n4.1 MB. No input can change it.", VIOLET),
]
x = Inches(0.85)
for head, body, col in cards:
    panel(s, x, Inches(2.1), Inches(2.75), Inches(2.0), edge=col)
    text(s, x + Inches(0.25), Inches(2.35), Inches(2.3), Inches(0.35), head, size=19, bold=True, color=col)
    text(s, x + Inches(0.25), Inches(2.85), Inches(2.3), Inches(1.0), body, size=13, line=1.3)
    x += Inches(2.9)

panel(s, Inches(0.85), Inches(4.45), Inches(11.6), Inches(2.2), fill=PANEL2)
text(s, Inches(1.2), Inches(4.7), Inches(11), Inches(0.35), "What it is for", size=17, bold=True, color=AMBER)
text(s, Inches(1.2), Inches(5.15), Inches(11), Inches(1.4), [
    ("To check that some other system ran a model correctly, you have to run it again yourself.", {}),
    ("That means you need an engine you trust more than the one you are checking.", {}),
    ("Existing engines are too large to trust and do not give the same answer twice.", {}),
], size=14, line=1.4, space_after=8)
footer(s, 2)

# ---- 3 why others are not reproducible -------------------------------
s = slide(); title(s, "Why other engines are not reproducible",
                   "The cause is batching, not floating-point error.")
panel(s, Inches(0.85), Inches(2.05), Inches(5.6), Inches(2.9), edge=RED)
text(s, Inches(1.2), Inches(2.3), Inches(5.0), Inches(0.4), "vLLM, SGLang", size=19, bold=True, color=RED)
text(s, Inches(1.2), Inches(2.85), Inches(5.0), Inches(2.0), [
    ("They batch requests together.", {}),
    ("Batch size changes how sums are split up.", {}),
    ("Batch size depends on how busy the server is.", {}),
    ("1000 runs of one prompt gave 80 different answers.", {"color": AMBER}),
    ("Forcing them to be reproducible costs 1.6-2x speed.", {"color": AMBER}),
], size=14, line=1.35, space_after=8)

panel(s, Inches(6.85), Inches(2.05), Inches(5.6), Inches(2.9), edge=CYAN)
text(s, Inches(7.2), Inches(2.3), Inches(5.0), Inches(0.4), "μInference", size=19, bold=True, color=CYAN)
text(s, Inches(7.2), Inches(2.85), Inches(5.0), Inches(2.0), [
    ("It does not batch.", {}),
    ("One request at a time, one sum order, always.", {}),
    ("So the problem does not arise.", {}),
    ("Reproducibility costs nothing here.", {"color": CYAN}),
    ("It is a result of the design.", {"color": CYAN}),
], size=14, line=1.35, space_after=8)

panel(s, Inches(0.85), Inches(5.3), Inches(11.6), Inches(1.1), fill=PANEL2)
text(s, Inches(1.2), Inches(5.52), Inches(11), Inches(0.4),
     "for (j = 0; j < n; j++)  val += wr[j] * x[j];", size=18, font=MONO, color=CYAN)
text(s, Inches(1.2), Inches(5.98), Inches(11), Inches(0.35),
     "This loop must stay exactly this shape.", size=13, color=MUTED)
footer(s, 3)

# ---- 4 which FP operations ------------------------------------------
s = slide(); title(s, "Which maths operations are used",
                   "The IEEE-754 standard requires exact results for some operations, not others.")
panel(s, Inches(0.85), Inches(1.95), Inches(5.6), Inches(1.75), edge=CYAN)
text(s, Inches(1.15), Inches(2.15), Inches(5.1), Inches(0.35),
     "REQUIRED TO BE EXACT", size=12, bold=True, color=CYAN)
text(s, Inches(1.15), Inches(2.58), Inches(5.1), Inches(0.5),
     "+   −   ×   ÷   √", size=24, font=MONO)
text(s, Inches(1.15), Inches(3.15), Inches(5.1), Inches(0.4),
     "Any two correct systems must agree.", size=13, color=MUTED)

panel(s, Inches(6.85), Inches(1.95), Inches(5.6), Inches(1.75), edge=RED)
text(s, Inches(7.15), Inches(2.15), Inches(5.1), Inches(0.35),
     "NOT REQUIRED TO BE EXACT", size=12, bold=True, color=RED)
text(s, Inches(7.15), Inches(2.58), Inches(5.1), Inches(0.5),
     "exp  log  sin  cos  pow", size=19, font=MONO)
text(s, Inches(7.15), Inches(3.15), Inches(5.1), Inches(0.4),
     "Results differ between systems.", size=13, color=MUTED)

text(s, Inches(0.85), Inches(3.95), Inches(11.6), Inches(0.35),
     "So the engine only uses the exact ones. The rest were replaced:", size=14, color=FG)
rows(s, Inches(4.4), [
    ("expf", "used by softmax and SwiGLU", "replaced with a polynomial", "within 1 ULP of libm"),
    ("powf cosf sinf", "used by RoPE", "replaced with a lookup table", "table is hashed and checked"),
    ("sqrtf", "used by RMSNorm", "kept, it is exact", "no change needed"),
    ("malloc, OpenMP, RNG", "not maths, but not reproducible", "removed", "fixed memory, one thread"),
], pitch=Inches(0.62), cols=(
    (1.1, 2.6, 12, AMBER, MONO), (3.85, 2.9, 13, FG, SANS),
    (6.9, 2.7, 13, FG, SANS), (9.8, 2.5, 12, CYAN, SANS)))
footer(s, 4)

# ---- 5 repo structure ------------------------------------------------
s = slide(); title(s, "How the repo is organised",
                   "One engine. Four ways to run it. The engine code is the same in all four.")
panel(s, Inches(2.9), Inches(1.95), Inches(7.0), Inches(1.5), fill=PANEL2, edge=CYAN)
text(s, Inches(3.2), Inches(2.13), Inches(5.5), Inches(0.35),
     "mucore/  —  the engine", size=15, bold=True, color=CYAN)
text(s, Inches(3.2), Inches(2.53), Inches(5.5), Inches(0.85), [
    ("mu_math.h   85   the maths", {}),
    ("mu_core.h  133   the interface", {}),
    ("mu_core.c  474   the transformer", {}),
], size=11.5, font=MONO, space_after=2, line=1.15)
text(s, Inches(10.05), Inches(2.3), Inches(2.3), Inches(0.9),
     "692\nlines", size=27, bold=True, color=CYAN, line=1.0)

hosts = [
    ("hosts/posix", "Runs on macOS or Linux.\nFor development.", "159 lines", MUTED),
    ("hosts/baremetal", "Runs on ARM with no\noperating system.", "338 lines", VIOLET),
    ("hosts/x86_64", "Runs on Intel with no\noperating system.", "365 lines", VIOLET),
    ("hosts/microkit", "Runs on seL4 as one\nprotection domain.", "157 lines", CYAN),
]
x = Inches(0.85)
for name, what, loc, col in hosts:
    panel(s, x, Inches(3.85), Inches(2.75), Inches(1.85), edge=col)
    text(s, x + Inches(0.22), Inches(4.03), Inches(2.4), Inches(0.3),
         name, size=13, font=MONO, bold=True, color=col)
    text(s, x + Inches(0.22), Inches(4.45), Inches(2.4), Inches(0.7), what, size=12, line=1.25)
    text(s, x + Inches(0.22), Inches(5.3), Inches(2.4), Inches(0.3),
         loc, size=11, font=MONO, color=MUTED)
    x += Inches(2.9)

panel(s, Inches(0.85), Inches(5.95), Inches(11.6), Inches(0.75), fill=PANEL2)
text(s, Inches(1.15), Inches(6.16), Inches(11.1), Inches(0.4),
     "The model weights are built into each image. One hash covers the code and the weights.",
     size=13.5, color=AMBER)
footer(s, 5)

# ---- 6 result --------------------------------------------------------
s = slide(); title(s, "Result: nine builds, one hash",
                   "Hash of the raw output numbers from every step. 3,072,000 bytes.")
panel(s, Inches(0.85), Inches(1.95), Inches(11.6), Inches(0.68), fill=PANEL2, edge=CYAN)
text(s, Inches(1.1), Inches(2.12), Inches(11.1), Inches(0.4),
     "9b78b92a305dc59611b5c53a04b538ae9c4ae18aea6c1fdbf6e45e9848b23bd2",
     size=16, font=MONO, color=CYAN, align=PP_ALIGN.CENTER)
envs = [
    ("clang 21, -O2", "macOS", "", MUTED),
    ("clang 21, -O0", "macOS", "different optimisation level", MUTED),
    ("clang 22, -O2", "macOS", "different compiler version", MUTED),
    ("GCC 16, -O2", "macOS", "different compiler", VIOLET),
    ("CompCert 3.17", "macOS", "FORMALLY VERIFIED compiler", CYAN),
    ("clang 18, -O2", "Linux", "different OS and CPU (CI)", VIOLET),
    ("ARM, no OS", "QEMU", "no C library at all", VIOLET),
    ("Intel, no OS", "QEMU", "different CPU maths implementation", CYAN),
    ("seL4 / Microkit", "QEMU", "the target system", CYAN),
]
y = Inches(2.76)
for name, plat, note, col in envs:
    panel(s, Inches(0.85), y, Inches(11.6), Inches(0.40))
    text(s, Inches(1.1), y + Inches(0.07), Inches(0.3), Inches(0.3), "✓", size=13, bold=True, color=CYAN)
    text(s, Inches(1.5), y + Inches(0.07), Inches(3.3), Inches(0.3), name, size=12.5)
    text(s, Inches(4.9), y + Inches(0.07), Inches(1.4), Inches(0.3), plat, size=11.5, font=MONO, color=MUTED)
    text(s, Inches(6.5), y + Inches(0.07), Inches(5.8), Inches(0.3), note, size=11.5, color=col)
    y += Inches(0.455)
footer(s, 6)

# ---- 7 negative control ---------------------------------------------
s = slide(); title(s, "The test can fail",
                   "Built the wrong way, the output changes. So the test is real.")
panel(s, Inches(0.85), Inches(2.05), Inches(5.6), Inches(2.4), edge=CYAN)
text(s, Inches(1.15), Inches(2.28), Inches(5.0), Inches(0.35), "CORRECT BUILD", size=13, bold=True, color=CYAN)
text(s, Inches(1.15), Inches(2.72), Inches(5.0), Inches(0.8),
     "-fno-fast-math\n-ffp-contract=off", size=14, font=MONO, line=1.35)
text(s, Inches(1.15), Inches(3.55), Inches(5.0), Inches(0.4),
     "0 fused multiply-add", size=19, bold=True, color=CYAN)
text(s, Inches(1.15), Inches(3.98), Inches(5.0), Inches(0.3),
     "9b78b92a…", size=13, font=MONO, color=MUTED)

panel(s, Inches(6.85), Inches(2.05), Inches(5.6), Inches(2.4), edge=RED)
text(s, Inches(7.15), Inches(2.28), Inches(5.0), Inches(0.35), "WRONG BUILD", size=13, bold=True, color=RED)
text(s, Inches(7.15), Inches(2.72), Inches(5.0), Inches(0.8),
     "-Ofast\n-march=native", size=14, font=MONO, line=1.35)
text(s, Inches(7.15), Inches(3.55), Inches(5.0), Inches(0.4),
     "96 fused multiply-add", size=19, bold=True, color=RED)
text(s, Inches(7.15), Inches(3.98), Inches(5.0), Inches(0.3),
     "351ebd7b…  different", size=13, font=MONO, color=RED)

panel(s, Inches(0.85), Inches(4.75), Inches(11.6), Inches(1.75), fill=PANEL2)
text(s, Inches(1.2), Inches(4.98), Inches(11), Inches(0.35),
     "Why fused multiply-add changes the answer", size=15, bold=True, color=AMBER)
text(s, Inches(1.2), Inches(5.42), Inches(11), Inches(0.95), [
    ("a*b+c as one instruction rounds once. As two instructions it rounds twice.", {}),
    ("Comparing the text would not catch this. Comparing the numbers catches one bit.", {"color": MUTED}),
], size=13.5, line=1.35, space_after=7)
footer(s, 7)

# ---- 8 numbers -------------------------------------------------------
s = slide(); title(s, "Numbers", "All measured.")
cards = [
    ("692", "lines of engine code", "llama2.c is 973.\nvLLM stack is millions.", CYAN),
    ("4.13 MB", "memory used", "Same on all nine builds.\nFixed at build time.", VIOLET),
    ("161 tok/s", "one CPU thread", "Apple Silicon.\nNo BLAS, no SIMD, no threads.", AMBER),
    ("1 ULP", "worst maths error", "Every one of the 2^32\npossible inputs checked.", CYAN),
]
x = Inches(0.85)
for big, mid, small, col in cards:
    panel(s, x, Inches(2.1), Inches(2.75), Inches(2.4), edge=col)
    text(s, x + Inches(0.25), Inches(2.4), Inches(2.3), Inches(0.6), big, size=29, bold=True, color=col)
    text(s, x + Inches(0.25), Inches(3.05), Inches(2.3), Inches(0.4), mid, size=13, line=1.2)
    text(s, x + Inches(0.25), Inches(3.55), Inches(2.3), Inches(0.8), small, size=11.5, color=MUTED, line=1.3)
    x += Inches(2.9)

panel(s, Inches(0.85), Inches(4.85), Inches(11.6), Inches(1.6), fill=PANEL2)
text(s, Inches(1.2), Inches(5.08), Inches(11), Inches(0.35),
     "Compared against the original llama2.c", size=15, bold=True, color=CYAN)
text(s, Inches(1.2), Inches(5.52), Inches(11), Inches(0.8), [
    ("5 out of 5 test prompts give exactly the same text.", {}),
    ("Replacing the maths functions did not change the output.", {"color": MUTED}),
], size=13.5, line=1.35, space_after=7)
footer(s, 8)

# ---- 9 not claimed ---------------------------------------------------
s = slide(); title(s, "What is not claimed", "")
lims = [
    ("Not tested on real hardware", "Only in QEMU, an emulator."),
    ("Builds are not reproducible", "The output is the same. The binary files are not identical."),
    ("Only one model tested", "stories15M, 15 million parameters. Not tested at 7 billion."),
    ("No temperature sampling", "Only greedy selection. Random sampling needs a fixed random seed."),
    ("No GPU support", "A GPU needs signed vendor firmware and a closed compiler. Both would break the claim."),
    ("seL4 is not fully verified on ARM", "Correctness and integrity are proven. Confidentiality is not. Single core only. No IOMMU."),
]
y = Inches(1.95)
for head, body in lims:
    panel(s, Inches(0.85), y, Inches(11.6), Inches(0.72))
    panel(s, Inches(0.85), y, Inches(0.06), Inches(0.72), fill=AMBER, radius=False)
    text(s, Inches(1.1), y + Inches(0.08), Inches(4.3), Inches(0.6), head, size=13.5, bold=True, color=AMBER, line=1.15)
    text(s, Inches(5.5), y + Inches(0.08), Inches(6.8), Inches(0.62), body, size=12, line=1.25)
    y += Inches(0.8)
footer(s, 9)

# ---- 10 goals --------------------------------------------------------
s = slide(); title(s, "Goals", "")
cols = [
    ("DONE", CYAN, ["692-line engine, four hosts",
                    "Same output on nine builds",
                    "Runs on seL4",
                    "Proved: no memory errors (6 of 8)",
                    "Proved: the exp error bound",
                    "Proved: only exact maths used",
                    "Proved: the dot product bound",
                    "Proved: reproducibility (CompCert)",
                    "All of it checked in CI"]),
    ("NEXT — MONTHS", AMBER, ["Total error for one token",
                              "Cover the last two functions",
                              "Run on real hardware",
                              "Test a larger model"]),
    ("LATER — RESEARCH", VIOLET, ["Prove the total error bound",
                                  "Use it to check other systems",
                                  "Move to RISC-V for stronger proofs",
                                  "Try integers instead of floats"]),
]
x = Inches(0.85)
for head, col, items in cols:
    panel(s, x, Inches(1.95), Inches(3.7), Inches(4.3), edge=col)
    text(s, x + Inches(0.28), Inches(2.18), Inches(3.2), Inches(0.35), head, size=13, bold=True, color=col)
    text(s, x + Inches(0.28), Inches(2.68), Inches(3.15), Inches(3.3),
         [(f"·  {t}", {}) for t in items], size=13, line=1.3, space_after=11)
    x += Inches(3.9)
footer(s, 10)

# ---- 11 status vs goal ----------------------------------------------
s = slide(); title(s, "Testing is not proving",
                   "Tests check some inputs. A proof covers all of them.")
panel(s, Inches(0.85), Inches(2.05), Inches(5.6), Inches(1.9), edge=AMBER)
text(s, Inches(1.15), Inches(2.28), Inches(5.0), Inches(0.35), "STILL TESTED ONLY", size=13, bold=True, color=AMBER)
text(s, Inches(1.15), Inches(2.72), Inches(5.0), Inches(1.1), [
    ("Real hardware. Larger models.", {"font": MONO, "size": 12.5}),
    ("One checkpoint, one prompt.", {}),
    ("The total error bound (S4c).", {"color": AMBER}),
], size=13.5, line=1.3, space_after=8)

panel(s, Inches(6.85), Inches(2.05), Inches(5.6), Inches(1.9), edge=CYAN)
text(s, Inches(7.15), Inches(2.28), Inches(5.0), Inches(0.35), "ALREADY PROVEN", size=13, bold=True, color=CYAN)
text(s, Inches(7.15), Inches(2.72), Inches(5.0), Inches(1.1), [
    ("Memory safety. Both error bounds.", {"font": MONO, "size": 12.5}),
    ("Reproducibility, via CompCert.", {}),
    ("Covers inputs never run.", {"color": CYAN}),
], size=13.5, line=1.3, space_after=8)

panel(s, Inches(0.85), Inches(4.25), Inches(11.6), Inches(2.05), fill=PANEL2, edge=RED)
text(s, Inches(1.2), Inches(4.48), Inches(11), Inches(0.35),
     "One thing proofs cannot do", size=15, bold=True, color=RED)
text(s, Inches(1.2), Inches(4.92), Inches(11), Inches(1.2), [
    ("A proof says the program is correct for all inputs. It says nothing about one specific run.", {}),
    ("To show what happened on a specific run you need attestation or re-running.", {}),
    ("Proofs make the engine worth trusting. They are not a receipt.", {"color": MUTED}),
], size=13.5, line=1.35, space_after=7)
footer(s, 11)

# ---- 12 spec ---------------------------------------------------------
s = slide(); title(s, "What to prove, and what is proven",
                   "Run it with: make verify")
specs = [
    ("S2", "Memory limit is never exceeded", "CBMC", "DONE   3099 checks", CYAN),
    ("S3a", "Only the exact maths operations are used", "LLVM IR check", "DONE   5 opt levels", CYAN),
    ("S4a", "The exp function is within a known error", "exhaustive", "DONE   all 2^32 inputs", CYAN),
    ("S1", "No memory errors, for any input", "CBMC", "6 of 8 functions", AMBER),
    ("S3b", "Output depends only on the inputs", "CompCert", "DONE   verified compiler", CYAN),
    ("S4b", "The dot product error bound", "Rocq proof", "DONE   no axioms added", CYAN),
    ("S4c", "The total error for one token", "combine S4a, S4b", "open", AMBER),
    ("S5", "It computes a transformer correctly", "Coq", "not scheduled", RED),
]
y = Inches(1.95)
for tag, prop, tool, mode, col in specs:
    panel(s, Inches(0.85), y, Inches(11.6), Inches(0.5))
    text(s, Inches(1.05), y + Inches(0.12), Inches(0.6), Inches(0.3), tag, size=13, font=MONO, bold=True, color=col)
    text(s, Inches(1.8), y + Inches(0.12), Inches(5.4), Inches(0.3), prop, size=13)
    text(s, Inches(7.3), y + Inches(0.12), Inches(2.6), Inches(0.3), tool, size=12, font=MONO, color=MUTED)
    text(s, Inches(10.1), y + Inches(0.12), Inches(2.3), Inches(0.3), mode, size=12, color=col)
    y += Inches(0.56)

text(s, Inches(0.85), Inches(6.55), Inches(11.6), Inches(0.3),
     "13 of 13 checks pass. Five of the eight parts are done.", size=13.5, color=CYAN, bold=True)
footer(s, 12)

# ---- 13 plan ---------------------------------------------------------
s = slide(); title(s, "Plan", "Each step is a separate piece of work with its own test in CI.")
phases = [
    ("0", "Run CBMC to look for crashes", "done", "no problems found", CYAN),
    ("1", "Prove no memory errors (S1, S2)", "done", "S2 complete, S1 6 of 8", CYAN),
    ("2", "Add the maths-operations check (S3a)", "done", "runs at 5 opt levels", CYAN),
    ("3", "Prove the exp error bound (S4a)", "done", "all 2^32 inputs, 3.4 s", CYAN),
    ("4", "Dot product error bound (S4b)", "done", "Rocq, no added axioms", CYAN),
    ("5", "Build with CompCert (S3b)", "done", "REPRODUCIBILITY PROVEN", CYAN),
    ("6", "Total error for one token (S4c)", "weeks", "combine S4a and S4b", AMBER),
    ("7", "Full correctness (S5)", "research", "not scheduled", RED),
]
y = Inches(1.95)
for n, what, effort, earns, col in phases:
    panel(s, Inches(0.85), y, Inches(11.6), Inches(0.5))
    panel(s, Inches(1.0), y + Inches(0.08), Inches(0.34), Inches(0.34), fill=col)
    text(s, Inches(1.0), y + Inches(0.12), Inches(0.34), Inches(0.3), n, size=13, bold=True, color=BG, align=PP_ALIGN.CENTER)
    text(s, Inches(1.55), y + Inches(0.12), Inches(5.2), Inches(0.3), what, size=13)
    text(s, Inches(6.9), y + Inches(0.12), Inches(1.6), Inches(0.3), effort, size=12, font=MONO, color=MUTED)
    text(s, Inches(8.7), y + Inches(0.12), Inches(3.6), Inches(0.3), earns, size=12, color=col)
    y += Inches(0.56)

panel(s, Inches(0.85), Inches(6.45), Inches(11.6), Inches(0.5), fill=PANEL2, edge=CYAN)
text(s, Inches(1.15), Inches(6.6), Inches(11.1), Inches(0.3),
     "Steps 0 to 5 are finished. Reproducibility is now proven, not tested.", size=13.5, color=CYAN)
footer(s, 13)

# ---- 14 constraint ---------------------------------------------------
s = slide(); title(s, "What the benchmark does and does not say",
                   "VERINA measures one-shot proof writing on unseen problems. That is not this task.")
bars = [("Writing code", 72.6, CYAN), ("Writing the spec", 52.3, AMBER), ("Writing the proof", 4.9, RED)]
y = Inches(2.2)
for name, pct, col in bars:
    text(s, Inches(0.85), y + Inches(0.1), Inches(2.8), Inches(0.35), name, size=15)
    panel(s, Inches(3.8), y, Inches(7.2), Inches(0.55), fill=PANEL, radius=False)
    panel(s, Inches(3.8), y, Emu(int(Inches(7.2) * pct / 100)), Inches(0.55), fill=col, radius=False)
    text(s, Inches(11.2), y + Inches(0.1), Inches(1.3), Inches(0.35),
         f"{pct}%", size=16, bold=True, color=col, font=MONO)
    y += Inches(0.85)

panel(s, Inches(0.85), Inches(4.85), Inches(5.6), Inches(1.6), fill=PANEL2, edge=AMBER)
text(s, Inches(1.15), Inches(5.05), Inches(5.0), Inches(0.35), "Why the number is low", size=14, bold=True, color=AMBER)
text(s, Inches(1.15), Inches(5.48), Inches(5.0), Inches(0.9),
     "One attempt. Unseen problem. No compiler feedback. No choice of how to "
     "state the theorem.", size=13, line=1.3)

panel(s, Inches(6.85), Inches(4.85), Inches(5.6), Inches(1.6), fill=PANEL2, edge=CYAN)
text(s, Inches(7.15), Inches(5.05), Inches(5.0), Inches(0.35), "S4b was written anyway", size=14, bold=True, color=CYAN)
text(s, Inches(7.15), Inches(5.48), Inches(5.0), Inches(0.9),
     "Rocq proof, no added axioms. Took about eight compile-and-fix rounds, and "
     "it caught a real error in the bound.", size=13, line=1.3)
footer(s, 14)

# ---- 15 next ---------------------------------------------------------
s = slide(); title(s, "Next steps", "")
asks = [
    ("1", "Write it up", "Five of eight parts are proven, including reproducibility via a "
     "verified compiler. No inference engine has this. That is a paper.", CYAN),
    ("2", "Decide whether to do S5", "Full correctness needs a reference transformer written in Coq. "
     "That is a large project on its own. Suggestion: leave it out for now.", AMBER),
    ("3", "Contact Theorem Labs", "A research lab working on AI for formal verification. $6M funding. "
     "Their tools found a bug in Anthropic's sampling code that testing missed.", VIOLET),
]
y = Inches(1.95)
for n, head, body, col in asks:
    panel(s, Inches(0.85), y, Inches(11.6), Inches(1.3), edge=col)
    panel(s, Inches(1.15), y + Inches(0.3), Inches(0.42), Inches(0.42), fill=col)
    text(s, Inches(1.15), y + Inches(0.35), Inches(0.42), Inches(0.3), n, size=15, bold=True, color=BG, align=PP_ALIGN.CENTER)
    text(s, Inches(1.85), y + Inches(0.22), Inches(5.0), Inches(0.35), head, size=17, bold=True, color=col)
    text(s, Inches(1.85), y + Inches(0.64), Inches(10.2), Inches(0.6), body, size=12.5, line=1.3)
    y += Inches(1.42)

panel(s, Inches(0.85), Inches(6.35), Inches(11.6), Inches(0.46), fill=PANEL2)
text(s, Inches(1.15), Inches(6.47), Inches(11.1), Inches(0.3),
     "github.com/luiscosio/muInference   ·   PR #1", size=12, font=MONO, color=MUTED)
footer(s, 15)

import sys
prs.save(sys.argv[1] if len(sys.argv) > 1 else "deck.pptx")
print("wrote", sys.argv[1], "-", len(prs.slides._sldIdLst), "slides")
