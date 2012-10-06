(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Xavier Leroy, INRIA Paris-Rocquencourt                     *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(* *********************************************************************)

(** Translation from Csharpminor to Cminor. *)

Require Import FSets.
Require FSetAVL.
Require Import Coqlib.
Require Import Errors.
Require Import Maps.
Require Import Ordered.
Require Import AST.
Require Import Integers.
Require Import Floats.
Require Import Memdata.
Require Import Csharpminor.
Require Import Cminor.

Local Open Scope string_scope.
Local Open Scope error_monad_scope.

(** The main task in translating Csharpminor to Cminor is to explicitly
  stack-allocate local variables whose address is taken: these local
  variables become sub-blocks of the Cminor stack data block for the
  current function.  Taking the address of such a variable becomes
  a [Oaddrstack] operation with the corresponding offset.  Accessing
  or assigning such a variable becomes a load or store operation at
  that address.  Only scalar local variables whose address is never
  taken in the Csharpminor code can be mapped to Cminor local
  variable, since the latter do not reside in memory.  

  Another task performed during the translation to Cminor is to eliminate
  redundant casts to small numerical types (8- and 16-bit integers,
  single-precision floats).  

  Finally, the Clight-like [switch] construct of Csharpminor
  is transformed into the simpler, lower-level [switch] construct
  of Cminor.
*)

(** * Handling of variables *)

Definition for_var (id: ident) : ident := xO id.
Definition for_temp (id: ident) : ident := xI id.

(** Compile-time information attached to each Csharpminor
  variable: global variables, local variables, function parameters.
  [Var_local] denotes a scalar local variable whose address is not
  taken; it will be translated to a Cminor local variable of the
  same name.  [Var_stack_scalar] and [Var_stack_array] denote
  local variables that are stored as sub-blocks of the Cminor stack
  data block.  [Var_global_scalar] and [Var_global_array] denote
  global variables, stored in the global symbols with the same names. *)

Inductive var_info: Type :=
  | Var_local (chunk: memory_chunk)
  | Var_stack_scalar (chunk: memory_chunk) (ofs: Z)
  | Var_stack_array (ofs sz al: Z)
  | Var_global_scalar (chunk: memory_chunk)
  | Var_global_array.

Definition compilenv := PMap.t var_info.

(** * Helper functions for code generation *)

(** When the translation of an expression is stored in memory,
  one or several casts at the toplevel of the expression can be redundant
  with that implicitly performed by the memory store.
  [store_arg] detects this case and strips away the redundant cast. *)

Function uncast_int (m: int) (e: expr) {struct e} : expr :=
  match e with
  | Eunop (Ocast8unsigned|Ocast8signed) e1 =>
      if Int.eq (Int.and (Int.repr 255) m) m then uncast_int m e1 else e
  | Eunop (Ocast16unsigned|Ocast16signed) e1 =>
      if Int.eq (Int.and (Int.repr 65535) m) m then uncast_int m e1 else e
  | Ebinop Oand e1 (Econst (Ointconst n)) =>
      if Int.eq (Int.and n m) m then uncast_int m e1 else e
  | Ebinop Oshru e1 (Econst (Ointconst n)) =>
      if Int.eq (Int.shru (Int.shl m n) n) m
      then Ebinop Oshru (uncast_int (Int.shl m n) e1) (Econst (Ointconst n))
      else e
  | Ebinop Oshr e1 (Econst (Ointconst n)) =>
      if Int.eq (Int.shru (Int.shl m n) n) m
      then Ebinop Oshr (uncast_int (Int.shl m n) e1) (Econst (Ointconst n))
      else e
  | _ => e
  end.

Definition uncast_int8 (e: expr) : expr := uncast_int (Int.repr 255) e.

Definition uncast_int16 (e: expr) : expr := uncast_int (Int.repr 65535) e.

Function uncast_float32 (e: expr) : expr :=
  match e with
  | Eunop Osingleoffloat e1 => uncast_float32 e1
  | _ => e
  end.

Function store_arg (chunk: memory_chunk) (e: expr) : expr :=
  match chunk with
  | Mint8signed | Mint8unsigned => uncast_int8 e
  | Mint16signed | Mint16unsigned => uncast_int16 e
  | Mfloat32 => uncast_float32 e
  | _ => e
  end.

Definition make_store (chunk: memory_chunk) (e1 e2: expr): stmt :=
  Sstore chunk e1 (store_arg chunk e2).

Definition make_stackaddr (ofs: Z): expr :=
  Econst (Oaddrstack (Int.repr ofs)).

Definition make_globaladdr (id: ident): expr :=
  Econst (Oaddrsymbol id Int.zero).

Definition make_unop (op: unary_operation) (e: expr): expr :=
  match op with
  | Ocast8unsigned => Eunop Ocast8unsigned (uncast_int8 e)
  | Ocast8signed => Eunop Ocast8signed (uncast_int8 e)
  | Ocast16unsigned => Eunop Ocast16unsigned (uncast_int16 e)
  | Ocast16signed => Eunop Ocast16signed (uncast_int16 e)
  | Osingleoffloat => Eunop Osingleoffloat (uncast_float32 e)
  | _ => Eunop op e
  end.

(** * Optimization of casts *)

(** To remove redundant casts, we perform a modest static analysis
  on the values of expressions, classifying them into the following
  ranges. *)

Inductive approx : Type :=
  | Any                   (**r any value *)
  | Int1                  (**r [0] or [1] *)
  | Int7                  (**r [[0,127]] *)
  | Int8s                 (**r [[-128,127]] *)
  | Int8u                 (**r [[0,255]] *)
  | Int15                 (**r [[0,32767]] *)
  | Int16s                (**r [[-32768,32767]] *)
  | Int16u                (**r [[0,65535]] *)
  | Float32.               (**r single-precision float *)

Module Approx.

Definition bge (x y: approx) : bool :=
  match x, y with
  | Any, _ => true
  | Int1, Int1 => true
  | Int7, (Int1 | Int7) => true
  | Int8s, (Int1 | Int7 | Int8s) => true
  | Int8u, (Int1 | Int7 | Int8u) => true
  | Int15, (Int1 | Int7 | Int8u | Int15) => true
  | Int16s, (Int1 | Int7 | Int8s | Int8u | Int15 | Int16s) => true
  | Int16u, (Int1 | Int7 | Int8u | Int15 | Int16u) => true
  | Float32, Float32 => true
  | _, _ => false
  end.

Definition of_int (n: int) :=
  if Int.eq_dec n Int.zero || Int.eq_dec n Int.one then Int1
  else if Int.eq_dec n (Int.zero_ext 7 n) then Int7
  else if Int.eq_dec n (Int.zero_ext 8 n) then Int8u
  else if Int.eq_dec n (Int.sign_ext 8 n) then Int8s
  else if Int.eq_dec n (Int.zero_ext 15 n) then Int15
  else if Int.eq_dec n (Int.zero_ext 16 n) then Int16u
  else if Int.eq_dec n (Int.sign_ext 16 n) then Int16s
  else Any.

Definition of_float (n: float) :=
  if Float.eq_dec n (Float.singleoffloat n) then Float32 else Any.

Definition of_chunk (chunk: memory_chunk) :=
  match chunk with
  | Mint8signed => Int8s
  | Mint8unsigned => Int8u
  | Mint16signed => Int16s
  | Mint16unsigned => Int16u
  | Mint32 => Any
  | Mfloat32 => Float32
  | Mfloat64 => Any
  | Mfloat64al32 => Any
  end.

Definition unop (op: unary_operation) (a: approx) :=
  match op with
  | Ocast8unsigned => Int8u
  | Ocast8signed => Int8s
  | Ocast16unsigned => Int16u
  | Ocast16signed => Int16s
  | Osingleoffloat => Float32
  | _ => Any
  end.

Definition unop_is_redundant (op: unary_operation) (a: approx) :=
  match op with
  | Ocast8unsigned => bge Int8u a
  | Ocast8signed => bge Int8s a
  | Ocast16unsigned => bge Int16u a
  | Ocast16signed => bge Int16s a
  | Osingleoffloat => bge Float32 a
  | _ => false
  end.

Definition bitwise_and (a1 a2: approx) :=
  if bge Int1 a1 || bge Int1 a2 then Int1
  else if bge Int8u a1 || bge Int8u a2 then Int8u
  else if bge Int16u a1 || bge Int16u a2 then Int16u
  else Any.

Definition bitwise_or (a1 a2: approx) :=
  if bge Int1 a1 && bge Int1 a2 then Int1
  else if bge Int8u a1 && bge Int8u a2 then Int8u
  else if bge Int16u a1 && bge Int16u a2 then Int16u
  else Any.

Definition binop (op: binary_operation) (a1 a2: approx) :=
  match op with
  | Oand => bitwise_and a1 a2
  | Oor | Oxor => bitwise_or a1 a2
  | Ocmp _ => Int1
  | Ocmpu _ => Int1
  | Ocmpf _ => Int1
  | _ => Any
  end.

End Approx.

(** * Translation of expressions and statements. *)

(** Generation of a Cminor expression for reading a Csharpminor variable. *)

Definition var_get (cenv: compilenv) (id: ident): res (expr * approx) :=
  match PMap.get id cenv with
  | Var_local chunk =>
      OK(Evar (for_var id), Approx.of_chunk chunk)
  | Var_stack_scalar chunk ofs =>
      OK(Eload chunk (make_stackaddr ofs), Approx.of_chunk chunk)
  | Var_global_scalar chunk =>
      OK(Eload chunk (make_globaladdr id), Approx.of_chunk chunk)
  | _ =>
      Error(msg "Cminorgen.var_get")
  end.

(** Generation of a Cminor expression for taking the address of
  a Csharpminor variable. *)

Definition var_addr (cenv: compilenv) (id: ident): res (expr * approx) :=
  match PMap.get id cenv with
  | Var_local chunk => Error(msg "Cminorgen.var_addr")
  | Var_stack_scalar chunk ofs => OK (make_stackaddr ofs, Any)
  | Var_stack_array ofs sz al => OK (make_stackaddr ofs, Any)
  | _ => OK (make_globaladdr id, Any)
  end.

(** Generation of a Cminor statement performing an assignment to
  a variable.  The value being assigned is normalized according to
  its chunk type, as guaranteed by C#minor semantics. *)

Definition var_set (cenv: compilenv)
                   (id: ident) (rhs: expr): res stmt :=
  match PMap.get id cenv with
  | Var_local chunk =>
      OK(Sassign (for_var id) rhs)
  | Var_stack_scalar chunk ofs =>
      OK(make_store chunk (make_stackaddr ofs) rhs)
  | Var_global_scalar chunk =>
      OK(make_store chunk (make_globaladdr id) rhs)
  | _ =>
      Error(msg "Cminorgen.var_set")
  end.

(** A variant of [var_set] used for initializing function parameters.
  The value to be stored already resides in the Cminor variable called [id]. *)

Definition var_set_self (cenv: compilenv) (id: ident) (k: stmt): res stmt :=
  match PMap.get id cenv with
  | Var_local chunk =>
      OK k
  | Var_stack_scalar chunk ofs =>
      OK (Sseq (make_store chunk (make_stackaddr ofs) (Evar (for_var id))) k)
  | Var_stack_array ofs sz al =>
      OK (Sseq (Sbuiltin None (EF_memcpy sz al)
                         (make_stackaddr ofs :: Evar (for_var id) :: nil)) k)
  | _ =>
      Error(msg "Cminorgen.var_set_self")
  end.

(** Translation of constants. *)

Definition transl_constant (cst: Csharpminor.constant): (constant * approx) :=
  match cst with
  | Csharpminor.Ointconst n =>
      (Ointconst n, Approx.of_int n)
  | Csharpminor.Ofloatconst n =>
      (Ofloatconst n, Approx.of_float n)
  end.

(** Translation of expressions.  Return both a Cminor expression and
  a compile-time approximation of the value of the original
  C#minor expression, which is used to remove redundant casts. *)

Fixpoint transl_expr (cenv: compilenv) (e: Csharpminor.expr)
                     {struct e}: res (expr * approx) :=
  match e with
  | Csharpminor.Evar id =>
      var_get cenv id
  | Csharpminor.Etempvar id =>
      OK (Evar (for_temp id), Any)
  | Csharpminor.Eaddrof id =>
      var_addr cenv id
  | Csharpminor.Econst cst =>
      let (tcst, a) := transl_constant cst in OK (Econst tcst, a)
  | Csharpminor.Eunop op e1 =>
      do (te1, a1)  <- transl_expr cenv e1;
      if Approx.unop_is_redundant op a1
      then OK (te1, a1)
      else OK (make_unop op te1, Approx.unop op a1)
  | Csharpminor.Ebinop op e1 e2 =>
      do (te1, a1) <- transl_expr cenv e1;
      do (te2, a2) <- transl_expr cenv e2;
      OK (Ebinop op te1 te2, Approx.binop op a1 a2)
  | Csharpminor.Eload chunk e =>
      do (te, a) <- transl_expr cenv e;
      OK (Eload chunk te, Approx.of_chunk chunk)
  end.

Fixpoint transl_exprlist (cenv: compilenv) (el: list Csharpminor.expr)
                     {struct el}: res (list expr) :=
  match el with
  | nil =>
      OK nil
  | e1 :: e2 =>
      do (te1, a1) <- transl_expr cenv e1;
      do te2 <- transl_exprlist cenv e2;
      OK (te1 :: te2)
  end.

(** To translate [switch] statements, we wrap the statements associated with
  the various cases in a cascade of nested Cminor blocks.
  The multi-way branch is performed by a Cminor [switch]
  statement that exits to the appropriate case.  For instance:
<<
switch (e) {        --->    block { block { block {
  case N1: s1;                switch (e) { N1: exit 0; N2: exit 1; default: exit 2; }
  case N2: s2;                } ; s1  // with exits shifted by 2
  default: s;                 } ; s2  // with exits shifted by 1
}                             } ; s   // with exits unchanged
>>
  To shift [exit] statements appropriately, we use a second
  compile-time environment, of type [exit_env], which
  records the blocks inserted during the translation.
  A [true] element means the block was present in the original code;
  a [false] element, that it was inserted during translation.
*)

Definition exit_env := list bool.

Fixpoint shift_exit (e: exit_env) (n: nat) {struct e} : nat :=
  match e, n with
  | nil, _ => n
  | false :: e', _ => S (shift_exit e' n)
  | true :: e', O => O
  | true :: e', S m => S (shift_exit e' m)
  end.

Fixpoint switch_table (ls: lbl_stmt) (k: nat) {struct ls} : list (int * nat) :=
  match ls with
  | LSdefault _ => nil
  | LScase ni _ rem => (ni, k) :: switch_table rem (S k)
  end.

Fixpoint switch_env (ls: lbl_stmt) (e: exit_env) {struct ls}: exit_env :=
  match ls with
  | LSdefault _ => e
  | LScase _ _ ls' => false :: switch_env ls' e
  end.

(** Translation of statements.  The nonobvious part is
  the translation of [switch] statements, outlined above. *)

Definition typ_of_opttyp (ot: option typ) :=
  match ot with None => Tint | Some t => t end.

Fixpoint transl_stmt (ret: option typ) (cenv: compilenv) 
                     (xenv: exit_env) (s: Csharpminor.stmt)
                     {struct s}: res stmt :=
  match s with
  | Csharpminor.Sskip =>
      OK Sskip
  | Csharpminor.Sassign id e =>
      do (te, a) <- transl_expr cenv e;
      var_set cenv id te
  | Csharpminor.Sset id e =>
      do (te, a) <- transl_expr cenv e;
      OK (Sassign (for_temp id) te)
  | Csharpminor.Sstore chunk e1 e2 =>
      do (te1, a1) <- transl_expr cenv e1;
      do (te2, a2) <- transl_expr cenv e2;
      OK (make_store chunk te1 te2)
  | Csharpminor.Scall optid sig e el =>
      do (te, a) <- transl_expr cenv e;
      do tel <- transl_exprlist cenv el;
      OK (Scall (option_map for_temp optid) sig te tel)
  | Csharpminor.Sbuiltin optid ef el =>
      do tel <- transl_exprlist cenv el;
      OK (Sbuiltin (option_map for_temp optid) ef tel)
  | Csharpminor.Sseq s1 s2 =>
      do ts1 <- transl_stmt ret cenv xenv s1;
      do ts2 <- transl_stmt ret cenv xenv s2;
      OK (Sseq ts1 ts2)
  | Csharpminor.Sifthenelse e s1 s2 =>
      do (te, a) <- transl_expr cenv e;
      do ts1 <- transl_stmt ret cenv xenv s1;
      do ts2 <- transl_stmt ret cenv xenv s2;
      OK (Sifthenelse te ts1 ts2)
  | Csharpminor.Sloop s =>
      do ts <- transl_stmt ret cenv xenv s;
      OK (Sloop ts)
  | Csharpminor.Sblock s =>
      do ts <- transl_stmt ret cenv (true :: xenv) s;
      OK (Sblock ts)
  | Csharpminor.Sexit n =>
      OK (Sexit (shift_exit xenv n))
  | Csharpminor.Sswitch e ls =>
      let cases := switch_table ls O in
      let default := length cases in
      do (te, a) <- transl_expr cenv e;
      transl_lblstmt ret cenv (switch_env ls xenv) ls (Sswitch te cases default)
  | Csharpminor.Sreturn None =>
      OK (Sreturn None)
  | Csharpminor.Sreturn (Some e) =>
      do (te, a) <- transl_expr cenv e;
      OK (Sreturn (Some te))
  | Csharpminor.Slabel lbl s =>
      do ts <- transl_stmt ret cenv xenv s; OK (Slabel lbl ts)
  | Csharpminor.Sgoto lbl =>
      OK (Sgoto lbl)
  end

with transl_lblstmt (ret: option typ) (cenv: compilenv)
                    (xenv: exit_env) (ls: Csharpminor.lbl_stmt) (body: stmt)
                    {struct ls}: res stmt :=
  match ls with
  | Csharpminor.LSdefault s =>
      do ts <- transl_stmt ret cenv xenv s;
      OK (Sseq (Sblock body) ts)
  | Csharpminor.LScase _ s ls' =>
      do ts <- transl_stmt ret cenv xenv s;
      transl_lblstmt ret cenv (List.tail xenv) ls' (Sseq (Sblock body) ts)
  end.

(** * Stack layout *)

(** Computation of the set of variables whose address is taken in
  a piece of Csharpminor code. *)

Module Identset := FSetAVL.Make(OrderedPositive).

Fixpoint addr_taken_expr (e: Csharpminor.expr): Identset.t :=
  match e with
  | Csharpminor.Evar id => Identset.empty
  | Csharpminor.Etempvar id => Identset.empty
  | Csharpminor.Eaddrof id => Identset.add id Identset.empty
  | Csharpminor.Econst cst => Identset.empty
  | Csharpminor.Eunop op e1 => addr_taken_expr e1
  | Csharpminor.Ebinop op e1 e2 =>
      Identset.union (addr_taken_expr e1) (addr_taken_expr e2)
  | Csharpminor.Eload chunk e => addr_taken_expr e
  end.

Fixpoint addr_taken_exprlist (e: list Csharpminor.expr): Identset.t :=
  match e with
  | nil => Identset.empty
  | e1 :: e2 =>
      Identset.union (addr_taken_expr e1) (addr_taken_exprlist e2)
  end.

Fixpoint addr_taken_stmt (s: Csharpminor.stmt): Identset.t :=
  match s with
  | Csharpminor.Sskip => Identset.empty
  | Csharpminor.Sassign id e => addr_taken_expr e
  | Csharpminor.Sset id e => addr_taken_expr e
  | Csharpminor.Sstore chunk e1 e2 =>
      Identset.union (addr_taken_expr e1) (addr_taken_expr e2)
  | Csharpminor.Scall optid sig e el =>
      Identset.union (addr_taken_expr e) (addr_taken_exprlist el)
  | Csharpminor.Sbuiltin optid ef el =>
      addr_taken_exprlist el
  | Csharpminor.Sseq s1 s2 =>
      Identset.union (addr_taken_stmt s1) (addr_taken_stmt s2)
  | Csharpminor.Sifthenelse e s1 s2 =>
      Identset.union (addr_taken_expr e)
        (Identset.union (addr_taken_stmt s1) (addr_taken_stmt s2))
  | Csharpminor.Sloop s => addr_taken_stmt s
  | Csharpminor.Sblock s => addr_taken_stmt s
  | Csharpminor.Sexit n => Identset.empty
  | Csharpminor.Sswitch e ls =>
      Identset.union (addr_taken_expr e) (addr_taken_lblstmt ls)
  | Csharpminor.Sreturn None => Identset.empty
  | Csharpminor.Sreturn (Some e) => addr_taken_expr e
  | Csharpminor.Slabel lbl s => addr_taken_stmt s
  | Csharpminor.Sgoto lbl => Identset.empty
  end

with addr_taken_lblstmt (ls: Csharpminor.lbl_stmt): Identset.t :=
  match ls with
  | Csharpminor.LSdefault s => addr_taken_stmt s
  | Csharpminor.LScase _ s ls' => Identset.union (addr_taken_stmt s) (addr_taken_lblstmt ls')
  end.

(** Layout of the Cminor stack data block and construction of the 
  compilation environment.  Csharpminor local variables that are
  arrays or whose address is taken are allocated a slot in the Cminor
  stack data.  Sufficient padding is inserted to ensure adequate alignment
  of addresses. *)

Definition array_alignment (sz: Z) : Z :=
  if zlt sz 2 then 1
  else if zlt sz 4 then 2
  else if zlt sz 8 then 4 else 8.

Definition assign_variable
    (atk: Identset.t)
    (id_lv: ident * var_kind)
    (cenv_stacksize: compilenv * Z) : compilenv * Z :=
  let (cenv, stacksize) := cenv_stacksize in
  match id_lv with
  | (id, Varray sz al) =>
      let ofs := align stacksize (array_alignment sz) in
      (PMap.set id (Var_stack_array ofs sz al) cenv, ofs + Zmax 0 sz)
  | (id, Vscalar chunk) =>
      if Identset.mem id atk then
        let sz := size_chunk chunk in
        let ofs := align stacksize sz in
        (PMap.set id (Var_stack_scalar chunk ofs) cenv, ofs + sz)
      else
        (PMap.set id (Var_local chunk) cenv, stacksize)
  end.

Fixpoint assign_variables
    (atk: Identset.t)
    (id_lv_list: list (ident * var_kind))
    (cenv_stacksize: compilenv * Z)
    {struct id_lv_list}: compilenv * Z :=
  match id_lv_list with
  | nil => cenv_stacksize
  | id_lv :: rem =>
      assign_variables atk rem (assign_variable atk id_lv cenv_stacksize)
  end.

Definition build_compilenv
          (globenv: compilenv) (f: Csharpminor.function) : compilenv * Z :=
  assign_variables
    (addr_taken_stmt f.(Csharpminor.fn_body))
    (fn_variables f)
    (globenv, 0).

Definition assign_global_variable
     (ce: compilenv) (info: ident * globvar var_kind) : compilenv :=
  match info with
  | (id, mkglobvar vk _ _ _) =>
      PMap.set id (match vk with Vscalar chunk => Var_global_scalar chunk
                               | Varray _ _ => Var_global_array
                   end)
               ce
  end.

Definition build_global_compilenv (p: Csharpminor.program) : compilenv :=
  List.fold_left assign_global_variable 
                 p.(prog_vars) (PMap.init Var_global_array).

(** * Translation of functions *)

(** Function parameters whose address is taken must be stored in their
  stack slots at function entry.  (Cminor passes these parameters in
  local variables.) *)

Fixpoint store_parameters
       (cenv: compilenv) (params: list (ident * var_kind))
       {struct params} : res stmt :=
  match params with
  | nil => OK Sskip
  | (id, vk) :: rem =>
      do s <- store_parameters cenv rem;
      var_set_self cenv id s
  end.

(** Translation of a Csharpminor function.  We must check that the
  required Cminor stack block is no bigger than [Int.max_signed],
  otherwise address computations within the stack block could
  overflow machine arithmetic and lead to incorrect code. *)

Definition transl_funbody 
  (cenv: compilenv) (stacksize: Z) (f: Csharpminor.function): res function :=
    do tbody <- transl_stmt f.(fn_return) cenv nil f.(Csharpminor.fn_body);
    do sparams <- store_parameters cenv f.(Csharpminor.fn_params);
       OK (mkfunction
              (Csharpminor.fn_sig f)
              (List.map for_var (Csharpminor.fn_params_names f))
              (List.map for_var (Csharpminor.fn_vars_names f) ++
               List.map for_temp (Csharpminor.fn_temps f))
              stacksize
              (Sseq sparams tbody)).

Definition transl_function
         (gce: compilenv) (f: Csharpminor.function): res function :=
  let (cenv, stacksize) := build_compilenv gce f in
  if zle stacksize Int.max_unsigned
  then transl_funbody cenv stacksize f
  else Error(msg "Cminorgen: too many local variables, stack size exceeded").

Definition transl_fundef (gce: compilenv) (f: Csharpminor.fundef): res fundef :=
  transf_partial_fundef (transl_function gce) f.

Definition transl_globvar (vk: var_kind) := OK tt.

Definition transl_program (p: Csharpminor.program) : res program :=
  let gce := build_global_compilenv p in
  transform_partial_program2 (transl_fundef gce) transl_globvar p.
