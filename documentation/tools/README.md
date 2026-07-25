# Deck generator

`muinference-deck.pptx` is generated, not hand-edited. Regenerate it after
changing the content:

```sh
uv run --with python-pptx python documentation/tools/mkdeck.py \
  documentation/muinference-deck.pptx

# optional PDF, for people who will not open a pptx
soffice --headless --convert-to pdf --outdir documentation \
  documentation/muinference-deck.pptx
```

Edit `mkdeck.py`, not the pptx. Hand-editing the slides means the next
regeneration silently discards the change.

The `.pptx` and `.pdf` are committed so the deck can be shared straight from the
repo without a toolchain. If that ever becomes annoying, gitignore them — the
generator is the source of truth either way.
