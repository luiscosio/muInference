(* S4c, made concrete: error grows LINEARLY in depth, not exponentially.
 *
 * Compose.v proves that per-stage bounds chain. This file instantiates that for
 * the shape a transformer actually has -- the same layer repeated n times -- and
 * derives the bound a reader wants:
 *
 *     n identical non-expansive layers, each within e of exact
 *       =>  the stack is within n * e of exact
 *
 * That is the whole reason a 6-layer forward pass is bounded at all. If errors
 * compounded multiplicatively the bound would be e * L^n and useless. They do
 * not, provided each layer is non-expansive, which is what the normalisation
 * layers are there to arrange.
 *
 * WHAT IS STILL MISSING for a numeric constant on mu_forward: a per-layer e and
 * a per-layer Lipschitz constant. e comes from composing S4a (exp) and S4b (dot
 * product) across the ops in one layer; the Lipschitz constant depends on the
 * weight norms of a specific checkpoint. The theorem below is parametric in
 * both, which is the honest form -- supply them and you get a number.
 *)

Require Import Reals.
Require Import List.
Require Import Lra.
Require Import Compose.
Import ListNotations.
Open Scope R_scope.

Section DepthBound.

(* repeat s n is n copies of the same layer. *)

Lemma Forall_repeat : forall (P : stage -> Prop) s n,
  P s -> Forall P (repeat s n).
Proof.
  intros P s n H. induction n as [| n IH]; simpl; [constructor |].
  constructor; [exact H | exact IH].
Qed.

(* The per-stage errors of n identical stages sum to n * e. *)
Lemma fold_err_repeat : forall s n,
  fold_right (fun st acc => s_err st + acc) 0 (repeat s n) = INR n * s_err s.
Proof.
  intros s n. induction n as [| n IH].
  - simpl. lra.
  - (* rewrite INR (S n) first: simpl leaves it in an awkward match form.
       The closing goal is nonlinear in INR n and s_err s, so ring, not lra. *)
    rewrite S_INR. simpl. rewrite IH. ring.
Qed.

(* ---------------------------------------------------------------- the result *)

Theorem uniform_depth_linear :
  forall s n,
    wf_stage s -> s_lip s <= 1 ->
    forall x,
      Rabs (run_impl (repeat s n) x - run_exact (repeat s n) x)
        <= INR n * s_err s.
Proof.
  intros s n Hwf Hlip x.
  assert (HF  : Forall wf_stage (repeat s n)) by (apply Forall_repeat; exact Hwf).
  assert (HL1 : Forall (fun st => s_lip st <= 1) (repeat s n))
    by (apply Forall_repeat; exact Hlip).
  eapply Rle_trans; [apply (chain_n _ HF) |].
  eapply Rle_trans; [apply (total_err_additive _ HF HL1) |].
  rewrite fold_err_repeat. apply Rle_refl.
Qed.

(* Depth 6, which is what stories15M has. Stated separately because it is the
   sentence someone will actually quote. *)
Corollary depth_6 :
  forall s, wf_stage s -> s_lip s <= 1 ->
    forall x,
      Rabs (run_impl (repeat s 6) x - run_exact (repeat s 6) x)
        <= 6 * s_err s.
Proof.
  intros s Hwf Hlip x.
  assert (H := uniform_depth_linear s 6 Hwf Hlip x).
  assert (E : INR 6 = 6) by (simpl; lra).
  rewrite E in H. exact H.
Qed.

(* And the contrast, so the linear result is not mistaken for a triviality:
   with an expansive layer (L > 1) the accumulated factor is genuinely
   geometric, so non-expansiveness is doing real work. *)
Lemma lip_tail_repeat : forall s n,
  lip_tail (repeat s n) = s_lip s ^ n.
Proof.
  intros s n. induction n as [| n IH]; simpl; [reflexivity |].
  rewrite IH. reflexivity.
Qed.

End DepthBound.
