# S4b -- machine-checked error bound for the sequential dot product.
#
#   make          build and check the proof
#   make check    also print the axioms each theorem depends on
#
# Needs Rocq (brew install coq). Checked against Rocq 9.2.

COQC ?= coqc

# Silence the Rocq 9.x warning about unprefixed stdlib imports. We use the
# unprefixed form deliberately so the file also builds on Coq 8.18, which is
# what Ubuntu ships and what CI runs.
COQFLAGS ?= -w -deprecated-missing-stdlib

.PHONY: all check clean

all: DotError.vo

DotError.vo: DotError.v
	$(COQC) $(COQFLAGS) DotError.v

# A proof is only worth as much as its axiom set. This should show exactly the
# two axioms Rocq's classical reals are built on and nothing else -- no
# Admitted, no assumptions of our own.
check: DotError.vo
	@printf 'From Stdlib Require Import Reals.\nRequire Import DotError.\n' > axioms_probe.v
	@printf 'Print Assumptions DotError.dot_error_loop_from_zero.\n' >> axioms_probe.v
	@$(COQC) $(COQFLAGS) -Q . "" axioms_probe.v 2>&1 | grep -vE 'deprecated|^Use |^for compat|^\[dep'
	@rm -f axioms_probe.v axioms_probe.vo axioms_probe.glob axioms_probe.vos axioms_probe.vok

clean:
	rm -f *.vo *.vok *.vos *.glob .*.aux .nra.cache .lia.cache axioms_probe.*
