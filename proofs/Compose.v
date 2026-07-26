(* S4c -- how per-stage error bounds compose into an end-to-end bound.
 *
 * S4a bounds mu_expf. S4b bounds the dot product loop. Neither says anything
 * about the whole forward pass, because a forward pass is a chain of stages and
 * each stage feeds the next one an input that is already wrong.
 *
 * This file proves the machinery for that: if every stage is Lipschitz and
 * every implementation is within e_i of its exact stage, the chain's total error
 * is bounded, and the bound is a weighted sum rather than a product. That is why
 * a 6-layer transformer does not blow up: errors accumulate additively, scaled
 * by the Lipschitz constants downstream of where they were introduced.
 *
 * WHAT THIS IS AND IS NOT
 *   It IS the composition step, proven in general, plus the two-stage and
 *   n-stage forms.
 *   It is NOT a numeric constant for mu_forward. That needs a Lipschitz
 *   constant for each transformer stage, and those depend on the weights. The
 *   bound below is parametric in them, which is the honest form: plug in the
 *   weight norms for a given checkpoint and you get a number.
 *)

Require Import Reals.
Require Import List.
Require Import Lra.
Import ListNotations.
Open Scope R_scope.

Section Composition.

(* An exact stage and its implementation, both on reals. Vectors would be
   lists; the scalar case carries all the structure of the argument and keeps
   the proofs readable. *)

Definition lipschitz (f : R -> R) (L : R) : Prop :=
  forall x y, Rabs (f x - f y) <= L * Rabs (x - y).

(* The implementation is within e of the exact stage, for every input. This is
   the shape S4a and S4b both deliver. *)
Definition approximates (impl f : R -> R) (e : R) : Prop :=
  forall x, Rabs (impl x - f x) <= e.

(* ---------------------------------------------------------------- two stages *)

(* The key step. `fi (gi x)` is the implementation of the composition: the outer
   implementation applied to the inner implementation's already-wrong output. *)
Theorem chain2 :
  forall f g fi gi Lf ef eg,
    lipschitz f Lf -> 0 <= Lf ->
    approximates fi f ef ->
    approximates gi g eg ->
    forall x, Rabs (fi (gi x) - f (g x)) <= ef + Lf * eg.
Proof.
  intros f g fi gi Lf ef eg HL HLpos Hf Hg x.
  (* split at f (gi x): the outer stage's own error, then the outer stage
     amplifying the inner stage's error *)
  replace (fi (gi x) - f (g x))
     with ((fi (gi x) - f (gi x)) + (f (gi x) - f (g x))) by ring.
  eapply Rle_trans; [apply Rabs_triang |].
  apply Rplus_le_compat.
  - apply Hf.
  - eapply Rle_trans; [apply HL |].
    apply Rmult_le_compat_l; [exact HLpos | apply Hg].
Qed.

(* ------------------------------------------------------------------ n stages *)

(* A stage record: the exact function, its implementation, its Lipschitz
   constant, and its own error. *)
Record stage := {
  s_exact : R -> R;
  s_impl  : R -> R;
  s_lip   : R;
  s_err   : R
}.

Definition wf_stage (s : stage) : Prop :=
  lipschitz (s_exact s) (s_lip s)
  /\ 0 <= s_lip s
  /\ 0 <= s_err s
  /\ approximates (s_impl s) (s_exact s) (s_err s).

(* Apply a pipeline left to right: the head is the FIRST stage applied. *)
Fixpoint run_exact (l : list stage) (x : R) : R :=
  match l with
  | []      => x
  | s :: t  => run_exact t (s_exact s x)
  end.

Fixpoint run_impl (l : list stage) (x : R) : R :=
  match l with
  | []      => x
  | s :: t  => run_impl t (s_impl s x)
  end.

(* The Lipschitz constant of everything downstream of a position. *)
Fixpoint lip_tail (l : list stage) : R :=
  match l with
  | []     => 1
  | s :: t => s_lip s * lip_tail t
  end.

(* Total error: each stage's own error, amplified by everything after it. *)
Fixpoint total_err (l : list stage) : R :=
  match l with
  | []     => 0
  | s :: t => s_err s * lip_tail t + total_err t
  end.

Lemma lip_tail_nonneg : forall l, Forall wf_stage l -> 0 <= lip_tail l.
Proof.
  induction l as [| s t IH]; intros HF; simpl.
  - lra.
  - inversion HF as [| ? ? Hs Ht]; subst.
    destruct Hs as [_ [Hlp _]].
    specialize (IH Ht). nra.
Qed.

(* run_exact is Lipschitz with constant lip_tail. Needed to push an upstream
   error through the rest of the pipeline. *)
Lemma run_exact_lipschitz :
  forall l, Forall wf_stage l ->
    forall x y, Rabs (run_exact l x - run_exact l y) <= lip_tail l * Rabs (x - y).
Proof.
  induction l as [| s t IH]; intros HF x y; simpl.
  - rewrite Rmult_1_l. apply Rle_refl.
  - inversion HF as [| ? ? Hs Ht]; subst.
    destruct Hs as [Hlip [Hlp _]].
    eapply Rle_trans; [apply (IH Ht) |].
    assert (Ht0 : 0 <= lip_tail t) by (apply lip_tail_nonneg; exact Ht).
    eapply Rle_trans.
    { apply Rmult_le_compat_l; [exact Ht0 | apply Hlip]. }
    rewrite <- Rmult_assoc, (Rmult_comm (lip_tail t) (s_lip s)), Rmult_assoc.
    apply Rle_refl.
Qed.

(* ---------------------------------------------------------------- main result *)

Theorem chain_n :
  forall l, Forall wf_stage l ->
    forall x, Rabs (run_impl l x - run_exact l x) <= total_err l.
Proof.
  induction l as [| s t IH]; intros HF x; simpl.
  - replace (x - x) with 0 by ring. rewrite Rabs_R0. apply Rle_refl.
  - inversion HF as [| ? ? Hs Ht]; subst.
    destruct Hs as [Hlip [Hlp [Herr Happ]]].
    (* split at run_exact t (s_impl s x):
         what the tail does wrong, plus the tail amplifying this stage's error *)
    replace (run_impl t (s_impl s x) - run_exact t (s_exact s x))
       with ((run_impl t (s_impl s x) - run_exact t (s_impl s x))
             + (run_exact t (s_impl s x) - run_exact t (s_exact s x))) by ring.
    eapply Rle_trans; [apply Rabs_triang |].
    assert (Htail : Rabs (run_impl t (s_impl s x) - run_exact t (s_impl s x))
                    <= total_err t) by (apply IH; exact Ht).
    assert (Hpush : Rabs (run_exact t (s_impl s x) - run_exact t (s_exact s x))
                    <= lip_tail t * Rabs (s_impl s x - s_exact s x))
      by (apply run_exact_lipschitz; exact Ht).
    assert (Ht0 : 0 <= lip_tail t) by (apply lip_tail_nonneg; exact Ht).
    assert (Hthis : lip_tail t * Rabs (s_impl s x - s_exact s x)
                    <= lip_tail t * s_err s)
      by (apply Rmult_le_compat_l; [exact Ht0 | apply Happ]).
    (* total_err (s :: t) = s_err s * lip_tail t + total_err t *)
    nra.
Qed.

(* ------------------------------------------------------------- what it means *)

(* Non-expansive stages compose to a non-expansive pipeline. Pulled out as its
   own lemma: doing it inline needs an induction on the tail while the head's
   hypotheses are still in scope, which does not go through. *)
Lemma lip_tail_le_1 :
  forall l, Forall wf_stage l ->
    Forall (fun s => s_lip s <= 1) l -> lip_tail l <= 1.
Proof.
  induction l as [| s t IH]; intros HF HL; simpl; [lra |].
  inversion HF as [| ? ? Hs Ht]; subst.
  inversion HL as [| ? ? Hl1 Ht1]; subst.
  destruct Hs as [_ [Hlp _]].
  assert (H0 : 0 <= lip_tail t) by (apply lip_tail_nonneg; exact Ht).
  assert (H1 : lip_tail t <= 1) by (apply IH; assumption).
  nra.
Qed.

(* Additivity, stated plainly: if every stage is non-expansive (L <= 1), which
   is what normalisation layers are for, the total error is at most the SUM of
   the per-stage errors. No exponential blow-up with depth. This is the reason a
   6-layer forward pass is bounded at all. *)
Lemma total_err_additive :
  forall l, Forall wf_stage l ->
    Forall (fun s => s_lip s <= 1) l ->
    total_err l <= fold_right (fun s acc => s_err s + acc) 0 l.
Proof.
  induction l as [| s t IH]; intros HF HL; simpl; [lra |].
  inversion HF as [| ? ? Hs Ht]; subst.
  inversion HL as [| ? ? Hl1 Ht1]; subst.
  destruct Hs as [_ [Hlp [Herr _]]].
  assert (Ht0 : 0 <= lip_tail t) by (apply lip_tail_nonneg; exact Ht).
  assert (Hle1 : lip_tail t <= 1) by (apply lip_tail_le_1; assumption).
  specialize (IH Ht Ht1).
  nra.
Qed.

End Composition.
