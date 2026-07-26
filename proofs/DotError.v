(* S4b -- error bound for the sequential dot product.

   This is the loop at the heart of mu_matmul:

       float val = 0.0f;
       for (j = 0; j < n; j++) val += wr[j] * x[j];

   one accumulator, ascending index, no reassociation, no FMA. S3a proves the
   compiler emits exactly that. This file proves what it costs numerically.

   THE MODEL
     The standard floating-point model: every operation returns its exact
     result perturbed by a relative error of at most the unit roundoff u,
         fl(x op y) = (x op y)(1 + d),  |d| <= u.
     Nothing here assumes binary32 specifically, so the result holds for any
     format, and it holds for every possible choice of the rounding errors
     rather than for one execution.

   THE RESULT
     |computed - exact| <= gamma_n * sum |a_i * b_i|,  gamma_n = (1+u)^(n+1) - 1

   Underflow is NOT modelled. The multiplicative model above is exactly the
   thing that fails for subnormal results, so this bound is conditional on no
   underflow occurring. Stated here rather than buried, because it is the one
   assumption that could bite. *)

From Stdlib Require Import Reals.
From Stdlib Require Import List.
From Stdlib Require Import Lra.
Import ListNotations.
Open Scope R_scope.

Section DotProductError.

Variable u : R.
Hypothesis u_nonneg : 0 <= u.

(* One rounded operation. *)
Definition rounded (x r : R) : Prop :=
  exists d, Rabs d <= u /\ r = x * (1 + d).

(* Exact dot product of a list of pairs. *)
Fixpoint dot (l : list (R * R)) : R :=
  match l with
  | [] => 0
  | (a, b) :: t => a * b + dot t
  end.

(* Sum of the absolute values of the products: the scale the bound is
   relative to. *)
Fixpoint adot (l : list (R * R)) : R :=
  match l with
  | [] => 0
  | (a, b) :: t => Rabs (a * b) + adot t
  end.

(* Every value the algorithm can produce, for any admissible rounding errors.
   Each element costs one rounded multiply and one rounded add, which is what
   the C loop does. *)
Inductive computes : list (R * R) -> R -> Prop :=
| c_nil  : computes [] 0
| c_cons : forall a b t p st s,
    rounded (a * b) p ->
    computes t st ->
    rounded (p + st) s ->
    computes ((a, b) :: t) s.

Definition gamma (n : nat) : R := (1 + u) ^ (S n) - 1.

(* ---------------------------------------------------------------- lemmas *)

(* Rocq's stdlib has Rabs_le (build an absolute bound) but no inverse, so
   derive the two-sided form from Rle_abs. *)
Lemma abs_bound : forall x b, Rabs x <= b -> - b <= x <= b.
Proof.
  intros x b H. split.
  - assert (Hn : - x <= Rabs x) by (rewrite <- Rabs_Ropp; apply Rle_abs).
    lra.
  - apply Rle_trans with (Rabs x); [apply Rle_abs | exact H].
Qed.

Lemma one_plus_u_ge_1 : 1 <= 1 + u.
Proof. lra. Qed.

Lemma pow_ge_1 : forall n, 1 <= (1 + u) ^ n.
Proof.
  induction n as [| n IH]; simpl.
  - lra.
  - (* 1 <= (1+u) * (1+u)^n, from 0 <= u and the IH. Nonlinear, so nra. *)
    nra.
Qed.

Lemma gamma_nonneg : forall n, 0 <= gamma n.
Proof.
  intros n. unfold gamma.
  assert (H := pow_ge_1 (S n)). lra.
Qed.

Lemma adot_nonneg : forall l, 0 <= adot l.
Proof.
  induction l as [| [a b] t IH]; simpl.
  - lra.
  - assert (0 <= Rabs (a * b)) by apply Rabs_pos. lra.
Qed.

Lemma dot_le_adot : forall l, Rabs (dot l) <= adot l.
Proof.
  induction l as [| [a b] t IH]; simpl.
  - rewrite Rabs_R0. apply Rle_refl.
  - apply Rle_trans with (Rabs (a * b) + Rabs (dot t)).
    + apply Rabs_triang.
    + apply Rplus_le_compat_l. exact IH.
Qed.

(* ------------------------------------------------------------ main result *)

Theorem dot_error :
  forall l s, computes l s ->
    Rabs (s - dot l) <= gamma (length l) * adot l.
Proof.
  intros l s H. induction H as [| a b t p st s Hp Hc IH Hs].
  - (* empty list: nothing computed, nothing to bound *)
    simpl. rewrite Rminus_0_r, Rabs_R0. unfold gamma. simpl. lra.
  - (* one more term *)
    destruct Hp as [dm [Hdm Hpe]].
    destruct Hs as [da [Hda Hse]].
    simpl length. simpl dot. simpl adot.
    set (P := a * b). set (D := dot t). set (A := adot t).
    set (n := length t).

    (* The computed value, expanded. *)
    assert (Hval : s - (P + D) =
                   P * ((1 + dm) * (1 + da) - 1) + D * da + (st - D) * (1 + da)).
    { rewrite Hse, Hpe. unfold P, D. ring. }

    rewrite Hval.

    (* Bound each of the three contributions. *)
    assert (HE : Rabs (st - D) <= gamma n * A) by exact IH.
    assert (HAnn : 0 <= A) by apply adot_nonneg.
    assert (HDA : Rabs D <= A) by apply dot_le_adot.
    (* Turn both |d| <= u facts into plain two-sided bounds once, up front. *)
    assert (Hdm' : - u <= dm <= u) by (apply abs_bound; exact Hdm).
    assert (Hda' : - u <= da <= u) by (apply abs_bound; exact Hda).

    assert (Hda1 : Rabs (1 + da) <= 1 + u).
    { apply Rabs_le. lra. }
    assert (Hcross : Rabs ((1 + dm) * (1 + da) - 1) <= (1 + u) ^ 2 - 1).
    { apply Rabs_le. simpl. nra. }

    eapply Rle_trans. apply Rabs_triang.
    eapply Rle_trans. apply Rplus_le_compat_r. apply Rabs_triang.

    (* |P*c| + |D*da| + |E*(1+da)| *)
    rewrite !Rabs_mult.
    assert (HP : 0 <= Rabs P) by apply Rabs_pos.

    assert (B1 : Rabs P * Rabs ((1 + dm) * (1 + da) - 1)
                 <= Rabs P * ((1 + u) ^ 2 - 1)).
    { apply Rmult_le_compat_l; assumption. }
    assert (B2 : Rabs D * Rabs da <= A * u).
    { apply Rmult_le_compat; try apply Rabs_pos; assumption. }
    assert (B3 : Rabs (st - D) * Rabs (1 + da) <= (gamma n * A) * (1 + u)).
    { apply Rmult_le_compat; try apply Rabs_pos; assumption. }

    eapply Rle_trans.
    { apply Rplus_le_compat; [apply Rplus_le_compat; [exact B1 | exact B2] | exact B3]. }

    (* Now pure algebra. Writing v = 1+u, q = (1+u)^n, p = |P|:
         RHS - LHS  =  p * v^2 * (q - 1)
       The A terms cancel exactly -- that is why the constant is (1+u)^(n+1)-1
       and not something looser -- and the P term is non-negative because
       q >= 1. nra needs that last fact supplied; it cannot do induction. *)
    unfold gamma in *. simpl in *.
    assert (Hq : 1 <= (1 + u) ^ n) by apply pow_ge_1.

    (* Writing v = 1+u, q = (1+u)^n, p = |P|, the goal is
         p(v^2-1) + Au + (vq-1)Av  <=  (v^2 q - 1)(p + A)
       and the difference is exactly
         RHS - LHS = p * v^2 * (q - 1).
       The A terms cancel identically -- that is why the constant is
       (1+u)^(n+1) - 1 and not something looser. So the whole step reduces to
       one non-negative product.

       nra cannot get there on its own: p * v^2 * (q-1) is a product of THREE
       hypothesis-derived quantities and nra only multiplies pairs. Supplying
       the product and the ring identity turns it into linear arithmetic. *)
    assert (Hkey : 0 <= Rabs P * ((1 + u) * (1 + u)) * ((1 + u) ^ n - 1)).
    { apply Rmult_le_pos.
      - apply Rmult_le_pos; [apply Rabs_pos | nra].
      - lra. }

    assert (Hid :
      ((1 + u) * ((1 + u) * (1 + u) ^ n) - 1) * (Rabs P + A)
      - (Rabs P * ((1 + u) * ((1 + u) * 1) - 1) + A * u
         + ((1 + u) * (1 + u) ^ n - 1) * A * (1 + u))
      = Rabs P * ((1 + u) * (1 + u)) * ((1 + u) ^ n - 1)) by ring.

    lra.
Qed.

(* ====================================================================== *)
(* The loop as actually written                                            *)
(*                                                                         *)
(* `computes` above folds right to left. mu_matmul accumulates left to      *)
(* right:                                                                   *)
(*                                                                          *)
(*     val = 0;  for (j = 0; j < n; j++) val += w[j] * x[j];               *)
(*                                                                          *)
(* The bound is the same either way, but proving it for the wrong           *)
(* association and claiming it covers the code would be sleight of hand.    *)
(* So here is the accumulator version, which is the loop verbatim.          *)
(* ====================================================================== *)

Inductive computes_from : R -> list (R * R) -> R -> Prop :=
| cf_nil  : forall acc, computes_from acc [] acc
| cf_cons : forall acc a b t p s r,
    rounded (a * b) p ->        (* val_j = w[j] * x[j], rounded  *)
    rounded (acc + p) s ->      (* val   += that,        rounded  *)
    computes_from s t r ->      (* carry on with the new accumulator *)
    computes_from acc ((a, b) :: t) r.

Lemma pow_mono_S : forall n, (1 + u) ^ n <= (1 + u) ^ (S n).
Proof.
  intros n. simpl. assert (H := pow_ge_1 n). nra.
Qed.

(* The accumulator carries its own error forward, which is why it appears in
   the bound. Starting from an exact zero that term vanishes. *)
Theorem dot_error_loop :
  forall acc l r, computes_from acc l r ->
    Rabs (r - (acc + dot l))
      <= Rabs acc * ((1 + u) ^ (length l) - 1) + gamma (length l) * adot l.
Proof.
  intros acc l r H.
  induction H as [acc | acc a b t p s r Hp Hs Hc IH].
  - (* nothing left to add *)
    simpl. rewrite Rplus_0_r.
    replace (acc - acc) with 0 by ring. rewrite Rabs_R0.
    unfold gamma. simpl. lra.
  - destruct Hp as [dm [Hdm Hpe]].
    destruct Hs as [da [Hda Hse]].
    assert (Hdm' : - u <= dm <= u) by (apply abs_bound; exact Hdm).
    assert (Hda' : - u <= da <= u) by (apply abs_bound; exact Hda).
    simpl length. simpl dot. simpl adot.
    set (P := a * b). set (D := dot t).
    (* A and n are deliberately NOT abstracted: simpl unfolds them only
       partway, leaving lra with two atoms for the same quantity. *)

    assert (HAnn : 0 <= adot t) by apply adot_nonneg.
    assert (HP  : 0 <= Rabs P) by apply Rabs_pos.
    assert (Hac : 0 <= Rabs acc) by apply Rabs_pos.
    assert (Hq  : 1 <= (1 + u) ^ (length t)) by apply pow_ge_1.

    (* split the error into "what the tail did" and "what this add did" *)
    assert (Hsplit : r - (acc + (P + D)) = (r - (s + D)) + (s - (acc + P)))
      by ring.

    (* This step's rounding error.  s - (acc+P) = acc*da + P*((1+dm)(1+da)-1) *)
    assert (Hstep : s - (acc + P) = acc * da + P * ((1 + dm) * (1 + da) - 1)).
    { rewrite Hse, Hpe. unfold P. ring. }
    assert (Hcross : Rabs ((1 + dm) * (1 + da) - 1) <= (1 + u) ^ 2 - 1).
    { apply Rabs_le. simpl. nra. }
    assert (HstepB : Rabs (s - (acc + P))
                     <= Rabs acc * u + Rabs P * ((1 + u) ^ 2 - 1)).
    { rewrite Hstep.
      eapply Rle_trans; [apply Rabs_triang |].
      rewrite !Rabs_mult.
      apply Rplus_le_compat.
      - apply Rmult_le_compat_l; [apply Rabs_pos | exact Hda].
      - apply Rmult_le_compat_l; [apply Rabs_pos | exact Hcross]. }

    (* Magnitude of the new accumulator.
       The bound must be (|acc| + |P|(1+u))(1+u), NOT (|acc| + |P|)(1+u):
       the product has already been rounded once before the add, so it carries
       its own (1+u). With the looser form the induction does not close --
       the accumulator terms come out negative. *)
    assert (HsB : Rabs s <= (Rabs acc + Rabs P * (1 + u)) * (1 + u)).
    { rewrite Hse, Hpe. rewrite Rabs_mult.
      assert (Hin : Rabs (acc + a * b * (1 + dm)) <= Rabs acc + Rabs P * (1 + u)).
      { eapply Rle_trans; [apply Rabs_triang |].
        rewrite Rabs_mult. unfold P.
        assert (Rabs (1 + dm) <= 1 + u) by (apply Rabs_le; lra).
        assert (0 <= Rabs (a * b)) by apply Rabs_pos. nra. }
      assert (Hd1 : Rabs (1 + da) <= 1 + u) by (apply Rabs_le; lra).
      apply Rmult_le_compat;
        [apply Rabs_pos | apply Rabs_pos | exact Hin | exact Hd1]. }

    rewrite Hsplit.
    eapply Rle_trans; [apply Rabs_triang |].
    eapply Rle_trans; [apply Rplus_le_compat; [exact IH | exact HstepB] |].

    (* now bound |s| in the tail term and finish with algebra *)
    assert (Hmu : 0 <= (1 + u) ^ (length t) - 1) by lra.
    assert (Htail : Rabs s * ((1 + u) ^ (length t) - 1)
                    <= ((Rabs acc + Rabs P * (1 + u)) * (1 + u))
                       * ((1 + u) ^ (length t) - 1)).
    { apply Rmult_le_compat_r; [exact Hmu | exact HsB]. }

    eapply Rle_trans;
      [apply Rplus_le_compat_r; apply Rplus_le_compat_r; exact Htail |].

    unfold gamma in *. simpl in *.

    (* Writing v = 1+u, q = (1+u)^len, a = |acc|, p = |P|, A = adot t, the
       accumulator terms cancel identically and so do the |P| terms. What is
       left over is one non-negative quantity:
           RHS - LHS = A * v * q * u
       That is a product of four hypothesis-derived factors, which is past what
       nra will try, so supply it and the ring identity and finish linearly. *)
    assert (Kpos : 0 <= adot t * (1 + u) * (1 + u) ^ (length t) * u).
    { repeat apply Rmult_le_pos; lra. }

    assert (Hid :
      (Rabs acc * ((1 + u) * (1 + u) ^ (length t) - 1)
       + ((1 + u) * ((1 + u) * (1 + u) ^ (length t)) - 1) * (Rabs P + adot t))
      - ((Rabs acc + Rabs P * (1 + u)) * (1 + u) * ((1 + u) ^ (length t) - 1)
         + ((1 + u) * (1 + u) ^ (length t) - 1) * adot t
         + (Rabs acc * u + Rabs P * ((1 + u) * ((1 + u) * 1) - 1)))
      = adot t * (1 + u) * (1 + u) ^ (length t) * u) by ring.

    lra.
Qed.

(* Starting from an exact zero, which is what the C loop does. *)
Corollary dot_error_loop_from_zero :
  forall l r, computes_from 0 l r ->
    Rabs (r - dot l) <= gamma (length l) * adot l.
Proof.
  intros l r H.
  assert (HB := dot_error_loop 0 l r H).
  rewrite Rabs_R0 in HB. rewrite Rmult_0_l in HB.
  replace (0 + dot l) with (dot l) in HB by ring.
  lra.
Qed.

End DotProductError.
