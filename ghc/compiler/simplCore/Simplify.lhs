%
% (c) The AQUA Project, Glasgow University, 1993-1996
%
\section[Simplify]{The main module of the simplifier}

\begin{code}
#include "HsVersions.h"

module Simplify ( simplTopBinds, simplExpr, simplBind ) where

IMPORT_1_3(List(partition))

IMP_Ubiq(){-uitous-}
#if defined(__GLASGOW_HASKELL__) && __GLASGOW_HASKELL__ <= 201
IMPORT_DELOOPER(SmplLoop)		-- paranoia checking
#endif

import BinderInfo
import CmdLineOpts	( SimplifierSwitch(..) )
import ConFold		( completePrim )
import CoreUnfold	( Unfolding, SimpleUnfolding, mkFormSummary, exprIsTrivial, whnfOrBottom, FormSummary(..) )
import CostCentre 	( isSccCountCostCentre, cmpCostCentre, costsAreSubsumed, useCurrentCostCentre )
import CoreSyn
import CoreUtils	( coreExprType, nonErrorRHSs, maybeErrorApp,
			  unTagBinders, squashableDictishCcExpr
			)
import Id		( idType, idWantsToBeINLINEd, idMustNotBeINLINEd, addIdArity, getIdArity,
			  getIdDemandInfo, addIdDemandInfo,
			  GenId{-instance NamedThing-}
			)
import Name		( isExported )
import IdInfo		( willBeDemanded, noDemandInfo, DemandInfo, ArityInfo(..),
			  atLeastArity, unknownArity )
import Literal		( isNoRepLit )
import Maybes		( maybeToBool )
import PprType		( GenType{-instance Outputable-}, GenTyVar{- instance Outputable -} )
#if __GLASGOW_HASKELL__ <= 30
import PprCore		( GenCoreArg, GenCoreExpr )
#endif
import TyVar		( GenTyVar {- instance Eq -} )
import Pretty		--( ($$) )
import PrimOp		( primOpOkForSpeculation, PrimOp(..) )
import SimplCase	( simplCase, bindLargeRhs )
import SimplEnv
import SimplMonad
import SimplVar		( completeVar )
import Unique		( Unique )
import SimplUtils
import Type		( mkTyVarTy, mkTyVarTys, mkAppTy, applyTy, mkFunTys,
			  splitFunTy, splitFunTyExpandingDicts, getFunTy_maybe, eqTy
			)
import TysWiredIn	( realWorldStateTy )
import Outputable	( PprStyle(..), Outputable(..) )
import Util		( SYN_IE(Eager), appEager, returnEager, runEager, mapEager,
			  isSingleton, zipEqual, zipWithEqual, mapAndUnzip, panic, pprPanic, assertPanic, pprTrace )
\end{code}

The controlling flags, and what they do
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

passes:
------
-fsimplify		= run the simplifier
-ffloat-inwards		= runs the float lets inwards pass
-ffloat			= runs the full laziness pass
			  (ToDo: rename to -ffull-laziness)
-fupdate-analysis	= runs update analyser
-fstrictness		= runs strictness analyser
-fsaturate-apps		= saturates applications (eta expansion)

options:
-------
-ffloat-past-lambda	= OK to do full laziness.
			  (ToDo: remove, as the full laziness pass is
				 useless without this flag, therefore
				 it is unnecessary. Just -ffull-laziness
				 should be kept.)

-ffloat-lets-ok		= OK to float lets out of lets if the enclosing
			  let is strict or if the floating will expose
			  a WHNF [simplifier].

-ffloat-primops-ok	= OK to float out of lets cases whose scrutinee
			  is a primop that cannot fail [simplifier].

-fcode-duplication-ok	= allows the previous option to work on cases with
			  multiple branches [simplifier].

-flet-to-case		= does let-to-case transformation [simplifier].

-fcase-of-case		= does case of case transformation [simplifier].

-fpedantic-bottoms  	= does not allow:
			     case x of y -> e  ===>  e[x/y]
			  (which may turn bottom into non-bottom)


			NOTES ON INLINING
			~~~~~~~~~~~~~~~~~

Inlining is one of the delicate aspects of the simplifier.  By
``inlining'' we mean replacing an occurrence of a variable ``x'' by
the RHS of x's definition.  Thus

	let x = e in ...x...	===>   let x = e in ...e...

We have two mechanisms for inlining:

1.  Unconditional.  The occurrence analyser has pinned an (OneOcc
FunOcc NoDupDanger NotInsideSCC n) flag on the variable, saying ``it's
certainly safe to inline this variable, and to drop its binding''.
(...Umm... if n <= 1; if n > 1, it is still safe, provided you are
happy to be duplicating code...) When it encounters such a beast, the
simplifer binds the variable to its RHS (in the id_env) and continues.
It doesn't even look at the RHS at that stage.  It also drops the
binding altogether.

2.  Conditional.  In all other situations, the simplifer simplifies
the RHS anyway, and keeps the new binding.  It also binds the new
(cloned) variable to a ``suitable'' Unfolding in the UnfoldEnv.

Here, ``suitable'' might mean NoUnfolding (if the occurrence
info is ManyOcc and the RHS is not a manifest HNF, or UnfoldAlways (if
the variable has an INLINE pragma on it).  The idea is that anything
in the UnfoldEnv is safe to use, but also has an enclosing binding if
you decide not to use it.

Head normal forms
~~~~~~~~~~~~~~~~~
We *never* put a non-HNF unfolding in the UnfoldEnv except in the
INLINE-pragma case.

At one time I thought it would be OK to put non-HNF unfoldings in for
variables which occur only once [if they got inlined at that
occurrence the RHS of the binding would become dead, so no duplication
would occur].   But consider:
@
	let x = <expensive>
	    f = \y -> ...y...y...y...
	in f x
@
Now, it seems that @x@ appears only once, but even so it is NOT safe
to put @x@ in the UnfoldEnv, because @f@ will be inlined, and will
duplicate the references to @x@.

Because of this, the "unconditional-inline" mechanism above is the
only way in which non-HNFs can get inlined.

INLINE pragmas
~~~~~~~~~~~~~~

When a variable has an INLINE pragma on it --- which includes wrappers
produced by the strictness analyser --- we treat it rather carefully.

For a start, we are careful not to substitute into its RHS, because
that might make it BIG, and the user said "inline exactly this", not
"inline whatever you get after inlining other stuff inside me".  For
example

	let f = BIG
	in {-# INLINE y #-} y = f 3
	in ...y...y...

Here we don't want to substitute BIG for the (single) occurrence of f,
because then we'd duplicate BIG when we inline'd y.  (Exception:
things in the UnfoldEnv with UnfoldAlways flags, which originated in
other INLINE pragmas.)

So, we clean out the UnfoldEnv of all SimpleUnfolding inlinings before
going into such an RHS.

What about imports?  They don't really matter much because we only
inline relatively small things via imports.

We augment the the UnfoldEnv with UnfoldAlways guidance if there's an
INLINE pragma.  We also do this for the RHSs of recursive decls,
before looking at the recursive decls. That way we achieve the effect
of inlining a wrapper in the body of its worker, in the case of a
mutually-recursive worker/wrapper split.


%************************************************************************
%*									*
\subsection[Simplify-simplExpr]{The main function: simplExpr}
%*									*
%************************************************************************

At the top level things are a little different.

  * No cloning (not allowed for exported Ids, unnecessary for the others)
  * Floating is done a bit differently (no case floating; check for leaks; handle letrec)

\begin{code}
simplTopBinds :: SimplEnv -> [InBinding] -> SmplM [OutBinding]

-- Dead code is now discarded by the occurrence analyser,

simplTopBinds env binds
  = mapSmpl (floatBind env True) binds	`thenSmpl` \ binds_s ->
    simpl_top_binds env (concat binds_s)
  where
    simpl_top_binds env [] = returnSmpl []

    simpl_top_binds env (NonRec binder@(in_id,occ_info) rhs : binds)
      =		--- No cloning necessary at top level
        simplRhsExpr env binder rhs in_id				`thenSmpl` \ (rhs',arity) ->
        completeNonRec env binder (in_id `withArity` arity) rhs'	`thenSmpl` \ (new_env, binds1') ->
        simpl_top_binds new_env binds					`thenSmpl` \ binds2' ->
        returnSmpl (binds1' ++ binds2')

    simpl_top_binds env (Rec pairs : binds)
      =		-- No cloning necessary at top level, but we nevertheless
		-- add the Ids to the environment.  This makes sure that
		-- info carried on the Id (such as arity info) gets propagated
		-- to occurrences.
		--
		-- This may seem optional, but I found an occasion when it Really matters.
		-- Consider	foo{n} = ...foo...
		--		baz* = foo
		--
		-- where baz* is exported and foo isn't.  Then when we do "indirection-shorting"
		-- in tidyCore, we need the {no-inline} pragma from foo to attached to the final
		-- thing:	baz*{n} = ...baz...
		--
		-- Sure we could have made the indirection-shorting a bit cleverer, but
		-- propagating pragma info is a Good Idea anyway.
	let
	    env1 = extendIdEnvWithClones env binders ids
	in
        simplRecursiveGroup env1 ids pairs 	`thenSmpl` \ (bind', new_env) ->
        simpl_top_binds new_env binds		`thenSmpl` \ binds' ->
        returnSmpl (Rec bind' : binds')
      where
	binders = map fst pairs
        ids     = map fst binders
\end{code}

%************************************************************************
%*									*
\subsection[Simplify-simplExpr]{The main function: simplExpr}
%*									*
%************************************************************************


\begin{code}
simplExpr :: SimplEnv
	  -> InExpr -> [OutArg]
	  -> OutType		-- Type of (e args); i.e. type of overall result
	  -> SmplM OutExpr
\end{code}

The expression returned has the same meaning as the input expression
applied to the specified arguments.


Variables
~~~~~~~~~
Check if there's a macro-expansion, and if so rattle on.  Otherwise do
the more sophisticated stuff.

\begin{code}
simplExpr env (Var v) args result_ty
  = case (runEager $ lookupId env v) of
      LitArg lit		-- A boring old literal
	-> ASSERT( null args )
	   returnSmpl (Lit lit)

      VarArg var 	-- More interesting!  An id!
	-> completeVar env var args result_ty
	 			-- Either Id is in the local envt, or it's a global.
				-- In either case we don't need to apply the type
				-- environment to it.
\end{code}

Literals
~~~~~~~~

\begin{code}
simplExpr env (Lit l) [] result_ty = returnSmpl (Lit l)
#ifdef DEBUG
simplExpr env (Lit l) _  _ = panic "simplExpr:Lit with argument"
#endif
\end{code}

Primitive applications are simple.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

NB: Prim expects an empty argument list! (Because it should be
saturated and not higher-order. ADR)

\begin{code}
simplExpr env (Prim op prim_args) args result_ty
  = ASSERT (null args)
    mapEager (simplArg env) prim_args	`appEager` \ prim_args' ->
    simpl_op op				`appEager` \ op' ->
    completePrim env op' prim_args'
  where
    -- PrimOps just need any types in them renamed.

    simpl_op (CCallOp label is_asm may_gc arg_tys result_ty)
      = mapEager (simplTy env) arg_tys	`appEager` \ arg_tys' ->
	simplTy env result_ty		`appEager` \ result_ty' ->
	returnEager (CCallOp label is_asm may_gc arg_tys' result_ty')

    simpl_op other_op = returnEager other_op
\end{code}

Constructor applications
~~~~~~~~~~~~~~~~~~~~~~~~
Nothing to try here.  We only reuse constructors when they appear as the
rhs of a let binding (see completeLetBinding).

\begin{code}
simplExpr env (Con con con_args) args result_ty
  = ASSERT( null args )
    mapEager (simplArg env) con_args	`appEager` \ con_args' ->
    returnSmpl (Con con con_args')
\end{code}


Applications are easy too:
~~~~~~~~~~~~~~~~~~~~~~~~~~
Just stuff 'em in the arg stack

\begin{code}
simplExpr env (App fun arg) args result_ty
  = simplArg env arg	`appEager` \ arg' ->
    simplExpr env fun (arg' : args) result_ty
\end{code}

Type lambdas
~~~~~~~~~~~~

First the case when it's applied to an argument.

\begin{code}
simplExpr env (Lam (TyBinder tyvar) body) (TyArg ty : args) result_ty
  = -- ASSERT(not (isPrimType ty))
    tick TyBetaReduction	`thenSmpl_`
    simplExpr (extendTyEnv env tyvar ty) body args result_ty
\end{code}

\begin{code}
simplExpr env tylam@(Lam (TyBinder tyvar) body) [] result_ty
  = cloneTyVarSmpl tyvar		`thenSmpl` \ tyvar' ->
    let
	new_ty  = mkTyVarTy tyvar'
	new_env = extendTyEnv env tyvar new_ty
	new_result_ty = applyTy result_ty new_ty
    in
    simplExpr new_env body [] new_result_ty		`thenSmpl` \ body' ->
    returnSmpl (Lam (TyBinder tyvar') body')

#ifdef DEBUG
simplExpr env (Lam (TyBinder _) _) (_ : _) result_ty
  = panic "simplExpr:TyLam with non-TyArg"
#endif
\end{code}


Ordinary lambdas
~~~~~~~~~~~~~~~~

There's a complication with lambdas that aren't saturated.
Suppose we have:

	(\x. \y. ...x...)

If we did nothing, x is used inside the \y, so would be marked
as dangerous to dup.  But in the common case where the abstraction
is applied to two arguments this is over-pessimistic.
So instead we don't take account of the \y when dealing with x's usage;
instead, the simplifier is careful when partially applying lambdas.

\begin{code}
simplExpr env expr@(Lam (ValBinder binder) body) orig_args result_ty
  = go 0 env expr orig_args
  where
    go n env (Lam (ValBinder binder) body) (val_arg : args)
      | isValArg val_arg		-- The lambda has an argument
      = tick BetaReduction	`thenSmpl_`
        go (n+1) (extendIdEnvWithAtom env binder val_arg) body args

    go n env expr@(Lam (ValBinder binder) body) args
      	-- The lambda is un-saturated, so we must zap the occurrence info
 	-- on the arguments we've already beta-reduced into the body of the lambda
      = ASSERT( null args )	-- Value lambda must match value argument!
        let
	    new_env = markDangerousOccs env (take n orig_args)
        in
        simplValLam new_env expr 0 {- Guaranteed applied to at least 0 args! -} result_ty 
				`thenSmpl` \ (expr', arity) ->
	returnSmpl expr'

    go n env non_val_lam_expr args     	-- The lambda had enough arguments
      = simplExpr env non_val_lam_expr args result_ty
\end{code}


Let expressions
~~~~~~~~~~~~~~~

\begin{code}
simplExpr env (Let bind body) args result_ty
  = simplBind env bind (\env -> simplExpr env body args result_ty) result_ty
\end{code}

Case expressions
~~~~~~~~~~~~~~~~

\begin{code}
simplExpr env expr@(Case scrut alts) args result_ty
  = simplCase env scrut alts (\env rhs -> simplExpr env rhs args result_ty) result_ty
\end{code}


Coercions
~~~~~~~~~
\begin{code}
simplExpr env (Coerce coercion ty body) args result_ty
  = simplCoerce env coercion ty body args result_ty
\end{code}


Set-cost-centre
~~~~~~~~~~~~~~~

1) Eliminating nested sccs ...
We must be careful to maintain the scc counts ...

\begin{code}
simplExpr env (SCC cc1 (SCC cc2 expr)) args result_ty
  | not (isSccCountCostCentre cc2) && case cmpCostCentre cc1 cc2 of { EQ_ -> True; _ -> False }
    	-- eliminate inner scc if no call counts and same cc as outer
  = simplExpr env (SCC cc1 expr) args result_ty

  | not (isSccCountCostCentre cc2) && not (isSccCountCostCentre cc1)
    	-- eliminate outer scc if no call counts associated with either ccs
  = simplExpr env (SCC cc2 expr) args result_ty
\end{code}

2) Moving sccs inside lambdas ...
  
\begin{code}
simplExpr env (SCC cc (Lam binder@(ValBinder _) body)) args result_ty
  | not (isSccCountCostCentre cc)
	-- move scc inside lambda only if no call counts
  = simplExpr env (Lam binder (SCC cc body)) args result_ty

simplExpr env (SCC cc (Lam binder body)) args result_ty
	-- always ok to move scc inside type/usage lambda
  = simplExpr env (Lam binder (SCC cc body)) args result_ty
\end{code}

3) Eliminating dict sccs ...

\begin{code}
simplExpr env (SCC cc expr) args result_ty
  | squashableDictishCcExpr cc expr
    	-- eliminate dict cc if trivial dict expression
  = simplExpr env expr args result_ty
\end{code}

4) Moving arguments inside the body of an scc ...
This moves the cost of doing the application inside the scc
(which may include the cost of extracting methods etc)

\begin{code}
simplExpr env (SCC cost_centre body) args result_ty
  = let
	new_env = setEnclosingCC env cost_centre
    in
    simplExpr new_env body args result_ty		`thenSmpl` \ body' ->
    returnSmpl (SCC cost_centre body')
\end{code}

%************************************************************************
%*									*
\subsection{Simplify RHS of a Let/Letrec}
%*									*
%************************************************************************

simplRhsExpr does arity-expansion.  That is, given:

	* a right hand side /\ tyvars -> \a1 ... an -> e
	* the information (stored in BinderInfo) that the function will always
	  be applied to at least k arguments

it transforms the rhs to

	/\tyvars -> \a1 ... an b(n+1) ... bk -> (e b(n+1) ... bk)

This is a Very Good Thing!

\begin{code}
simplRhsExpr
	:: SimplEnv
	-> InBinder
	-> InExpr
	-> OutId		-- The new binder (used only for its type)
	-> SmplM (OutExpr, ArityInfo)

-- First a special case for variable right-hand sides
--	v = w
-- It's OK to simplify the RHS, but it's often a waste of time.  Often
-- these v = w things persist because v is exported, and w is used 
-- elsewhere.  So if we're not careful we'll eta expand the rhs, only
-- to eta reduce it in competeNonRec.
--
-- If we leave the binding unchanged, we will certainly replace v by w at 
-- every occurrence of v, which is good enough.  
--
-- In fact, it's better to replace v by w than to inline w in v's rhs,
-- even if this is the only occurrence of w.  Why? Because w might have
-- IdInfo (like strictness) that v doesn't.

simplRhsExpr env binder@(id,occ_info) (Var v) new_id
 = case (runEager $ lookupId env v) of
      LitArg lit -> returnSmpl (Lit lit, ArityExactly 0)
      VarArg v'	 -> returnSmpl (Var v', getIdArity v')

simplRhsExpr env binder@(id,occ_info) rhs new_id
  = 	-- Deal with the big lambda part
    ASSERT( null uvars )	-- For now

    mapSmpl cloneTyVarSmpl tyvars			`thenSmpl` \ tyvars' ->
    let
	rhs_ty   = idType new_id
	new_tys  = mkTyVarTys tyvars'
	body_ty  = foldl applyTy rhs_ty new_tys
	lam_env  = extendTyEnvList rhs_env (zipEqual "simplRhsExpr" tyvars new_tys)
    in
	-- Deal with the little lambda part
	-- Note that we call simplLam even if there are no binders,
	-- in case it can do arity expansion.
    simplValLam lam_env body (getBinderInfoArity occ_info) body_ty	`thenSmpl` \ (lambda', arity) ->

	-- Put on the big lambdas, trying to float out any bindings caught inside
    mkRhsTyLam tyvars' lambda'					`thenSmpl` \ rhs' ->

    returnSmpl (rhs', arity)
  where
    rhs_env | idWantsToBeINLINEd id  	-- Don't ever inline in a INLINE thing's rhs
	    = switchOffInlining env1	-- See comments with switchOffInlining
	    | otherwise	
            = env1

	-- The top level "enclosing CC" is "SUBSUMED".  But the enclosing CC
	-- for the rhs of top level defs is "OST_CENTRE".  Consider
	--	f = \x -> e
	--	g = \y -> let v = f y in scc "x" (v ...)
	-- Here we want to inline "f", since its CC is SUBSUMED, but we don't
	-- want to inline "v" since its CC is dynamically determined.

    current_cc = getEnclosingCC env
    env1 | costsAreSubsumed current_cc = setEnclosingCC env useCurrentCostCentre
	 | otherwise		       = env

    (uvars, tyvars, body) = collectUsageAndTyBinders rhs
\end{code}


%************************************************************************
%*									*
\subsection{Simplify a lambda abstraction}
%*									*
%************************************************************************

Simplify (\binders -> body) trying eta expansion and reduction, given that
the abstraction will always be applied to at least min_no_of_args.

\begin{code}
simplValLam env expr min_no_of_args expr_ty
  | not (switchIsSet env SimplDoLambdaEtaExpansion) ||	-- Bale out if eta expansion off

    exprIsTrivial expr 				    ||  -- or it's a trivial RHS
	-- No eta expansion for trivial RHSs
	-- It's rather a Bad Thing to expand
	--	g = f alpha beta
	-- to
	-- 	g = \a b c -> f alpha beta a b c
	--
	-- The original RHS is "trivial" (exprIsTrivial), because it generates
	-- no code (renames f to g).  But the new RHS isn't.

    null potential_extra_binder_tys		    ||	-- or ain't a function
    no_of_extra_binders <= 0				-- or no extra binders needed
  = cloneIds env binders		`thenSmpl` \ binders' ->
    let
	new_env = extendIdEnvWithClones env binders binders'
    in
    simplExpr new_env body [] body_ty		`thenSmpl` \ body' ->
    returnSmpl (mkValLam binders' body', final_arity)

  | otherwise				-- Eta expansion possible
  = -- A SSERT( no_of_extra_binders <= length potential_extra_binder_tys )
    (if not ( no_of_extra_binders <= length potential_extra_binder_tys ) then
	pprTrace "simplValLam" (vcat [ppr PprDebug expr, 
					  ppr PprDebug expr_ty,
					  ppr PprDebug binders,
					  int no_of_extra_binders,
					  ppr PprDebug potential_extra_binder_tys])
    else \x -> x) $

    tick EtaExpansion			`thenSmpl_`
    cloneIds env binders	 	`thenSmpl` \ binders' ->
    let
	new_env = extendIdEnvWithClones env binders binders'
    in
    newIds extra_binder_tys						`thenSmpl` \ extra_binders' ->
    simplExpr new_env body (map VarArg extra_binders') etad_body_ty	`thenSmpl` \ body' ->
    returnSmpl (
      mkValLam (binders' ++ extra_binders') body',
      final_arity
    )

  where
    (binders,body)	       = collectValBinders expr
    no_of_binders	       = length binders
    (arg_tys, res_ty)	       = splitFunTyExpandingDicts expr_ty
    potential_extra_binder_tys = (if not (no_of_binders <= length arg_tys) then
					pprTrace "simplValLam" (vcat [ppr PprDebug expr, 
									  ppr PprDebug expr_ty,
									  ppr PprDebug binders])
				  else \x->x) $
				 drop no_of_binders arg_tys
    body_ty		       = mkFunTys potential_extra_binder_tys res_ty

	-- Note: it's possible that simplValLam will be applied to something
	-- with a forall type.  Eg when being applied to the rhs of
	--		let x = wurble
	-- where wurble has a forall-type, but no big lambdas at the top.
	-- We could be clever an insert new big lambdas, but we don't bother.

    etad_body_ty	= mkFunTys (drop no_of_extra_binders potential_extra_binder_tys) res_ty
    extra_binder_tys    = take no_of_extra_binders potential_extra_binder_tys
    final_arity		= atLeastArity (no_of_binders + no_of_extra_binders)

    no_of_extra_binders =	-- First, use the info about how many args it's
				-- always applied to in its scope; but ignore this
				-- info for thunks. To see why we ignore it for thunks,
				-- consider  	let f = lookup env key in (f 1, f 2)
				-- We'd better not eta expand f just because it is 
				-- always applied!
			   (min_no_of_args - no_of_binders)

				-- Next, try seeing if there's a lambda hidden inside
				-- something cheap.
				-- etaExpandCount can reuturn a huge number (like 10000!) if
				-- it finds that the body is a call to "error"; hence
				-- the use of "min" here.
			   `max`
			   (etaExpandCount body `min` length potential_extra_binder_tys)

				-- Finally, see if it's a state transformer, in which
				-- case we eta-expand on principle! This can waste work,
				-- but usually doesn't
			   `max`
			   case potential_extra_binder_tys of
				[ty] | ty `eqTy` realWorldStateTy -> 1
				other				  -> 0
\end{code}



%************************************************************************
%*									*
\subsection[Simplify-coerce]{Coerce expressions}
%*									*
%************************************************************************

\begin{code}
-- (coerce (case s of p -> r)) args ==> case s of p -> (coerce r) args
simplCoerce env coercion ty expr@(Case scrut alts) args result_ty
  = simplCase env scrut alts (\env rhs -> simplCoerce env coercion ty rhs args result_ty) result_ty

-- (coerce (let defns in b)) args  ==> let defns' in (coerce b) args
simplCoerce env coercion ty (Let bind body) args result_ty
  = simplBind env bind (\env -> simplCoerce env coercion ty body args result_ty) result_ty

-- Default case
simplCoerce env coercion ty expr args result_ty
  = simplTy env ty			`appEager` \ ty' ->
    simplTy env expr_ty			`appEager` \ expr_ty' ->
    simplExpr env expr [] expr_ty'	`thenSmpl` \ expr' ->
    returnSmpl (mkGenApp (mkCoerce coercion ty' expr') args)
  where
    expr_ty = coreExprType (unTagBinders expr)	-- Rather like simplCase other_scrut

	-- Try cancellation; we do this "on the way up" because
	-- I think that's where it'll bite best
    mkCoerce (CoerceOut con1) ty1 (Coerce (CoerceIn  con2) ty2 body) | con1 == con2 = body
    mkCoerce coercion ty  body = Coerce coercion ty body
\end{code}


%************************************************************************
%*									*
\subsection[Simplify-let]{Let-expressions}
%*									*
%************************************************************************

\begin{code}
simplBind :: SimplEnv
	  -> InBinding
	  -> (SimplEnv -> SmplM OutExpr)
	  -> OutType
	  -> SmplM OutExpr
\end{code}

When floating cases out of lets, remember this:

	let x* = case e of alts
	in <small expr>

where x* is sure to be demanded or e is a cheap operation that cannot
fail, e.g. unboxed addition.  Here we should be prepared to duplicate
<small expr>.  A good example:

	let x* = case y of
		   p1 -> build e1
		   p2 -> build e2
	in
	foldr c n x*
==>
	case y of
	  p1 -> foldr c n (build e1)
	  p2 -> foldr c n (build e2)

NEW: We use the same machinery that we use for case-of-case to
*always* do case floating from let, that is we let bind and abstract
the original let body, and let the occurrence analyser later decide
whether the new let should be inlined or not. The example above
becomes:

==>
      let join_body x' = foldr c n x'
	in case y of
	p1 -> let x* = build e1
		in join_body x*
	p2 -> let x* = build e2
		in join_body x*

note that join_body is a let-no-escape.
In this particular example join_body will later be inlined,
achieving the same effect.
ToDo: check this is OK with andy



\begin{code}
-- Dead code is now discarded by the occurrence analyser,

simplBind env (NonRec binder@(id,occ_info) rhs) body_c body_ty
  | idWantsToBeINLINEd id
  = complete_bind env rhs	-- Don't mess about with floating or let-to-case on
				-- INLINE things
  | otherwise
  = simpl_bind env rhs
  where
    -- Try let-to-case; see notes below about let-to-case
    simpl_bind env rhs | try_let_to_case &&
			 will_be_demanded &&
		         (rhs_is_bot ||
			  not rhs_is_whnf &&
		          singleConstructorType rhs_ty
				-- Only do let-to-case for single constructor types. 
				-- For other types we defer doing it until the tidy-up phase at
				-- the end of simplification.
			 )
      = tick Let2Case				`thenSmpl_`
        simplCase env rhs (AlgAlts [] (BindDefault binder (Var id)))
			  (\env rhs -> complete_bind env rhs) body_ty
		-- OLD COMMENT:  [now the new RHS is only "x" so there's less worry]
		-- NB: it's tidier to call complete_bind not simpl_bind, else
		-- we nearly end up in a loop.  Consider:
		-- 	let x = rhs in b
		-- ==>  case rhs of (p,q) -> let x=(p,q) in b
		-- This effectively what the above simplCase call does.
		-- Now, the inner let is a let-to-case target again!  Actually, since
		-- the RHS is in WHNF it won't happen, but it's a close thing!

    -- Try let-from-let
    simpl_bind env (Let bind rhs) | let_floating_ok
      = tick LetFloatFromLet                    `thenSmpl_`
	simplBind env (fix_up_demandedness will_be_demanded bind)
		      (\env -> simpl_bind env rhs) body_ty

    -- Try case-from-let; this deals with a strict let of error too
    simpl_bind env (Case scrut alts) | case_floating_ok scrut
      = tick CaseFloatFromLet				`thenSmpl_`

	-- First, bind large let-body if necessary
	if ok_to_dup || isSingleton (nonErrorRHSs alts)
	then
	    simplCase env scrut alts (\env rhs -> simpl_bind env rhs) body_ty
	else
	    bindLargeRhs env [binder] body_ty body_c	`thenSmpl` \ (extra_binding, new_body) ->
	    let
		body_c' = \env -> simplExpr env new_body [] body_ty
		case_c  = \env rhs -> simplBind env (NonRec binder rhs) body_c' body_ty
	    in
	    simplCase env scrut alts case_c body_ty	`thenSmpl` \ case_expr ->
	    returnSmpl (Let extra_binding case_expr)

    -- None of the above; simplify rhs and tidy up
    simpl_bind env rhs = complete_bind env rhs
 
    complete_bind env rhs
      = cloneId env binder			`thenSmpl` \ new_id ->
	simplRhsExpr env binder rhs new_id	`thenSmpl` \ (rhs',arity) ->
	completeNonRec env binder 
		(new_id `withArity` arity) rhs'	`thenSmpl` \ (new_env, binds) ->
        body_c new_env				`thenSmpl` \ body' ->
        returnSmpl (mkCoLetsAny binds body')


	-- All this stuff is computed at the start of the simpl_bind loop
    float_lets       	      = switchIsSet env SimplFloatLetsExposingWHNF
    float_primops    	      = switchIsSet env SimplOkToFloatPrimOps
    ok_to_dup	     	      = switchIsSet env SimplOkToDupCode
    always_float_let_from_let = switchIsSet env SimplAlwaysFloatLetsFromLets
    try_let_to_case           = switchIsSet env SimplLetToCase
    no_float		      = switchIsSet env SimplNoLetFromStrictLet

    demand_info	     = getIdDemandInfo id
    will_be_demanded = willBeDemanded demand_info
    rhs_ty 	     = idType id

    form	= mkFormSummary rhs
    rhs_is_bot  = case form of
			BottomForm -> True
			other	   -> False
    rhs_is_whnf = case form of
			VarForm -> True
			ValueForm -> True
			other -> False

    float_exposes_hnf = floatExposesHNF float_lets float_primops ok_to_dup rhs

    let_floating_ok  = (will_be_demanded && not no_float) ||
		       always_float_let_from_let ||
		       float_exposes_hnf

    case_floating_ok scrut = (will_be_demanded && not no_float) || 
			     (float_exposes_hnf && is_cheap_prim_app scrut && float_primops)
	-- See note below 
\end{code}

Float switches
~~~~~~~~~~~~~~
The booleans controlling floating have to be set with a little care.
Here's one performance bug I found:

	let x = let y = let z = case a# +# 1 of {b# -> E1}
			in E2
		in E3
	in E4

Now, if E2, E3 aren't HNFs we won't float the y-binding or the z-binding.
Before case_floating_ok included float_exposes_hnf, the case expression was floated
*one level per simplifier iteration* outwards.  So it made th s

Let to case: two points
~~~~~~~~~~~

Point 1.  We defer let-to-case for all data types except single-constructor
ones.  Suppose we change

	let x* = e in b
to
	case e of x -> b

It can be the case that we find that b ultimately contains ...(case x of ..)....
and this is the only occurrence of x.  Then if we've done let-to-case
we can't inline x, which is a real pain.  On the other hand, we lose no
transformations by not doing this transformation, because the relevant
case-of-X transformations are also implemented by simpl_bind.

If x is a single-constructor type, then we go ahead anyway, giving

	case e of (y,z) -> let x = (y,z) in b

because now we can squash case-on-x wherever they occur in b.

We do let-to-case on multi-constructor types in the tidy-up phase
(tidyCoreExpr) mainly so that the code generator doesn't need to
spot the demand-flag.


Point 2.  It's important to try let-to-case before doing the
strict-let-of-case transformation, which happens in the next equation
for simpl_bind.

	let a*::Int = case v of {p1->e1; p2->e2}
	in b

(The * means that a is sure to be demanded.)
If we do case-floating first we get this:

	let k = \a* -> b
	in case v of
		p1-> let a*=e1 in k a
		p2-> let a*=e2 in k a

Now watch what happens if we do let-to-case first:

	case (case v of {p1->e1; p2->e2}) of
	  Int a# -> let a*=I# a# in b
===>
	let k = \a# -> let a*=I# a# in b
	in case v of
		p1 -> case e1 of I# a# -> k a#
		p1 -> case e2 of I# a# -> k a#

The latter is clearly better.  (Remember the reboxing let-decl for a
is likely to go away, because after all b is strict in a.)

We do not do let to case for WHNFs, e.g.

	  let x = a:b in ...
	  =/=>
	  case a:b of x in ...

as this is less efficient.  but we don't mind doing let-to-case for
"bottom", as that will allow us to remove more dead code, if anything:

	  let x = error in ...
	  ===>
	  case error  of x -> ...
	  ===>
	  error

Notice that let to case occurs only if x is used strictly in its body
(obviously).


Letrec expressions
~~~~~~~~~~~~~~~~~~

Simplify each RHS, float any let(recs) from the RHSs (if let-floating is
on and it'll expose a HNF), and bang the whole resulting mess together
into a huge letrec.

1. Any "macros" should be expanded.  The main application of this
macro-expansion is:

	letrec
		f = ....g...
		g = ....f...
	in
	....f...

Here we would like the single call to g to be inlined.

We can spot this easily, because g will be tagged as having just one
occurrence.  The "inlineUnconditionally" predicate is just what we want.

A worry: could this lead to non-termination?  For example:

	letrec
		f = ...g...
		g = ...f...
		h = ...h...
	in
	..h..

Here, f and g call each other (just once) and neither is used elsewhere.
But it's OK:

* the occurrence analyser will drop any (sub)-group that isn't used at
  all.

* If the group is used outside itself (ie in the "in" part), then there
  can't be a cyle.

** IMPORTANT: check that NewOccAnal has the property that a group of
   bindings like the above has f&g dropped.! ***


2. We'd also like to pull out any top-level let(rec)s from the
rhs of the defns:

	letrec
		f = let h = ... in \x -> ....h...f...h...
	in
	...f...
====>
	letrec
		h = ...
		f = \x -> ....h...f...h...
	in
	...f...

But floating cases is less easy?  (Don't for now; ToDo?)


3.  We'd like to arrange that the RHSs "know" about members of the
group that are bound to constructors.  For example:

    let rec
       d.Eq      = (==,/=)
       f a b c d = case d.Eq of (h,_) -> let x = (a,b); y = (c,d) in not (h x y)
       /= a b    = unpack tuple a, unpack tuple b, call f
    in d.Eq

here, by knowing about d.Eq in f's rhs, one could get rid of
the case (and break out the recursion completely).
[This occurred with more aggressive inlining threshold (4),
nofib/spectral/knights]

How to do it?
	1: we simplify constructor rhss first.
	2: we record the "known constructors" in the environment
	3: we simplify the other rhss, with the knowledge about the constructors



\begin{code}
simplBind env (Rec pairs) body_c body_ty
  =	-- Do floating, if necessary
    floatBind env False (Rec pairs)	`thenSmpl` \ [Rec pairs'] ->
    let
	binders = map fst pairs'
    in
    cloneIds env binders			`thenSmpl` \ ids' ->
    let
       env_w_clones = extendIdEnvWithClones env binders ids'
    in
    simplRecursiveGroup env_w_clones ids' pairs'	`thenSmpl` \ (pairs', new_env) ->

    body_c new_env				`thenSmpl` \ body' ->

    returnSmpl (Let (Rec pairs') body')
\end{code}

\begin{code}
-- The env passed to simplRecursiveGroup already has 
-- bindings that clone the variables of the group.
simplRecursiveGroup env new_ids []
  = returnSmpl ([], env)

simplRecursiveGroup env (new_id : new_ids) ((binder@(_, occ_info), rhs) : pairs)
  = simplRhsExpr env binder rhs new_id		`thenSmpl` \ (new_rhs, arity) ->
    let
	new_id' = new_id `withArity` arity
    
	-- ToDo: this next bit could usefully share code with completeNonRec

        new_env 
	  | idMustNotBeINLINEd new_id		-- Occurrence analyser says "don't inline"
	  = env

	  | is_atomic eta'd_rhs 		-- If rhs (after eta reduction) is atomic
	  = extendIdEnvWithAtom env binder the_arg

	  | otherwise				-- Non-atomic
	  = extendEnvGivenBinding env occ_info new_id new_rhs
						-- Don't eta if it doesn't eliminate the binding

        eta'd_rhs = etaCoreExpr new_rhs
        the_arg   = case eta'd_rhs of
			  Var v -> VarArg v
			  Lit l -> LitArg l
    in
    simplRecursiveGroup new_env new_ids pairs	`thenSmpl` \ (new_pairs, final_env) ->
    returnSmpl ((new_id', new_rhs) : new_pairs, final_env)   
\end{code}


@completeLet@ looks at the simplified post-floating RHS of the
let-expression, and decides what to do.  There's one interesting
aspect to this, namely constructor reuse.  Consider
@
	f = \x -> case x of
		    (y:ys) -> y:ys
		    []     -> ...
@
Is it a good idea to replace the rhs @y:ys@ with @x@?  This depends a
bit on the compiler technology, but in general I believe not. For
example, here's some code from a real program:
@
const.Int.max.wrk{-s2516-} =
    \ upk.s3297#  upk.s3298# ->
	let {
	  a.s3299 :: Int
	  _N_ {-# U(P) #-}
	  a.s3299 = I#! upk.s3297#
	} in
	  case (const.Int._tagCmp.wrk{-s2513-} upk.s3297# upk.s3298#) of {
	    _LT -> I#! upk.s3298#
	    _EQ -> a.s3299
	    _GT -> a.s3299
	  }
@
The a.s3299 really isn't doing much good.  We'd be better off inlining
it.  (Actually, let-no-escapery means it isn't as bad as it looks.)

So the current strategy is to inline all known-form constructors, and
only do the reverse (turn a constructor application back into a
variable) when we find a let-expression:
@
	let x = C a1 .. an
	in
	... (let y = C a1 .. an in ...) ...
@
where it is always good to ditch the binding for y, and replace y by
x.  That's just what completeLetBinding does.


\begin{code}
{- FAILED CODE
   The trouble is that we keep transforming
		let x = coerce e
		    y = coerce x
		in ...
   to
		let x' = coerce e
		    y' = coerce x'
		in ...
   and counting a couple of ticks for this non-transformation

	-- We want to ensure that all let-bound Coerces have 
	-- atomic bodies, so they can freely be inlined.
completeNonRec env binder new_id (Coerce coercion ty rhs)
  | not (is_atomic rhs)
  = newId (coreExprType rhs)				`thenSmpl` \ inner_id ->
    completeNonRec env 
		   (inner_id, dangerousArgOcc) inner_id rhs `thenSmpl` \ (env1, binds1) ->
	-- Dangerous occ because, like constructor args,
	-- it can be duplicated easily
    let
	atomic_rhs = case runEager $ lookupId env1 inner_id of
		  	LitArg l -> Lit l
			VarArg v -> Var v
    in
    completeNonRec env1 binder new_id
		   (Coerce coercion ty atomic_rhs)	`thenSmpl` \ (env2, binds2) ->

    returnSmpl (env2, binds1 ++ binds2)
-}


	-- Right hand sides that are constructors
	--	let v = C args
	--	in
	--- ...(let w = C same-args in ...)...
	-- Then use v instead of w.	 This may save
	-- re-constructing an existing constructor.
completeNonRec env binder new_id rhs@(Con con con_args)
  | switchIsSet env SimplReuseCon && 
    maybeToBool maybe_existing_con &&
    not (isExported new_id)		-- Don't bother for exported things
					-- because we won't be able to drop
					-- its binding.
  = tick ConReused		`thenSmpl_`
    returnSmpl (extendIdEnvWithAtom env binder (VarArg it), [NonRec new_id rhs])
  where
    maybe_existing_con = lookForConstructor env con con_args
    Just it 	       = maybe_existing_con


	-- Default case
	-- Check for atomic right-hand sides.
	-- We used to have a "tick AtomicRhs" in here, but it causes more trouble
	-- than it's worth.  For a top-level binding a = b, where a is exported,
	-- we can't drop the binding, so we get repeated AtomicRhs ticks
completeNonRec env binder@(id,occ_info) new_id new_rhs
 | is_atomic eta'd_rhs 		-- If rhs (after eta reduction) is atomic
 = returnSmpl (atomic_env , [NonRec new_id eta'd_rhs])

 | otherwise			-- Non atomic rhs (don't eta after all)
 = returnSmpl (non_atomic_env , [NonRec new_id new_rhs])
 where
   atomic_env = extendIdEnvWithAtom env binder the_arg

   non_atomic_env = extendEnvGivenBinding (extendIdEnvWithClone env binder new_id)
					  occ_info new_id new_rhs

   eta'd_rhs = etaCoreExpr new_rhs
   the_arg   = case eta'd_rhs of
		  Var v -> VarArg v
		  Lit l -> LitArg l
\end{code}


\begin{code}
floatBind :: SimplEnv
	  -> Bool				-- True <=> Top level
	  -> InBinding
	  -> SmplM [InBinding]

floatBind env top_level bind
  | not float_lets ||
    n_extras == 0
  = returnSmpl [bind]

  | otherwise      
  = tickN LetFloatFromLet n_extras		`thenSmpl_` 
		-- It's important to increment the tick counts if we
		-- do any floating.  A situation where this turns out
		-- to be important is this:
		-- Float in produces:
		-- 	letrec  x = let y = Ey in Ex
		--	in B
		-- Now floating gives this:
		--	letrec x = Ex
		--	       y = Ey
		--	in B
		--- We now want to iterate once more in case Ey doesn't
		-- mention x, in which case the y binding can be pulled
		-- out as an enclosing let(rec), which in turn gives
		-- the strictness analyser more chance.
    returnSmpl binds'

  where
    (binds', _, n_extras) = fltBind bind	

    float_lets		      = switchIsSet env SimplFloatLetsExposingWHNF
    always_float_let_from_let = switchIsSet env SimplAlwaysFloatLetsFromLets

	-- fltBind guarantees not to return leaky floats
	-- and all the binders of the floats have had their demand-info zapped
    fltBind (NonRec bndr rhs)
      = (binds ++ [NonRec (un_demandify bndr) rhs'], 
	 leakFree bndr rhs', 
	 length binds)
      where
        (binds, rhs') = fltRhs rhs
    
    fltBind (Rec pairs)
      = ([Rec (extras
      	       ++
	       binders `zip` rhss')],
         and (zipWith leakFree binders rhss'),
	 length extras
        )
    
      where
        (binders, rhss)  = unzip pairs
        (binds_s, rhss') = mapAndUnzip fltRhs rhss
	extras		 = concat (map get_pairs (concat binds_s))

        get_pairs (NonRec bndr rhs) = [(bndr,rhs)]
        get_pairs (Rec pairs)       = pairs
    
	-- fltRhs has same invariant as fltBind
    fltRhs rhs
      |  (always_float_let_from_let ||
          floatExposesHNF True False False rhs)
      = fltExpr rhs
    
      | otherwise
      = ([], rhs)
    
    
	-- fltExpr has same invariant as fltBind
    fltExpr (Let bind body)
      | not top_level || binds_wont_leak
            -- fltExpr guarantees not to return leaky floats
      = (binds' ++ body_binds, body')
      where
        (body_binds, body')	     = fltExpr body
        (binds', binds_wont_leak, _) = fltBind bind
    
    fltExpr expr = ([], expr)

-- Crude but effective
leakFree (id,_) rhs = case getIdArity id of
			ArityAtLeast n | n > 0 -> True
			ArityExactly n | n > 0 -> True
			other	               -> whnfOrBottom rhs
\end{code}


%************************************************************************
%*									*
\subsection[Simplify-atoms]{Simplifying atoms}
%*									*
%************************************************************************

\begin{code}
simplArg :: SimplEnv -> InArg -> Eager ans OutArg

simplArg env (LitArg lit) = returnEager (LitArg lit)
simplArg env (TyArg  ty)  = simplTy env ty 	`appEager` \ ty' -> 
			    returnEager (TyArg ty')
simplArg env (VarArg id)  = lookupId env id
\end{code}

%************************************************************************
%*									*
\subsection[Simplify-quickies]{Some local help functions}
%*									*
%************************************************************************


\begin{code}
-- fix_up_demandedness switches off the willBeDemanded Info field
-- for bindings floated out of a non-demanded let
fix_up_demandedness True {- Will be demanded -} bind
   = bind	-- Simple; no change to demand info needed
fix_up_demandedness False {- May not be demanded -} (NonRec binder rhs)
   = NonRec (un_demandify binder) rhs
fix_up_demandedness False {- May not be demanded -} (Rec pairs)
   = Rec [(un_demandify binder, rhs) | (binder,rhs) <- pairs]

un_demandify (id, occ_info) = (id `addIdDemandInfo` noDemandInfo, occ_info)

is_cheap_prim_app (Prim op _) = primOpOkForSpeculation op
is_cheap_prim_app other	      = False

computeResultType :: SimplEnv -> InType -> [OutArg] -> OutType
computeResultType env expr_ty orig_args
  = simplTy env expr_ty		`appEager` \ expr_ty' ->
    let
	go ty [] = ty
	go ty (TyArg ty_arg : args) = go (mkAppTy ty ty_arg) args
	go ty (a:args) | isValArg a = case (getFunTy_maybe ty) of
					Just (_, res_ty) -> go res_ty args
					Nothing	         -> 
					    pprPanic "computeResultType" (vcat [
									ppr PprDebug (a:args),
									ppr PprDebug orig_args,
									ppr PprDebug expr_ty',
									ppr PprDebug ty])
    in
    go expr_ty' orig_args


var `withArity` UnknownArity = var
var `withArity` arity	     = var `addIdArity` arity

is_atomic (Var v) = True
is_atomic (Lit l) = not (isNoRepLit l)
is_atomic other   = False
\end{code}

