open Flx_util
open Flx_ast
open Flx_types
open Flx_set
open Flx_mtypes2
open Flx_print
open Flx_typing
open Flx_mbind
open Flx_srcref
open List
open Flx_unify
open Flx_treg
open Flx_exceptions
open Flx_maps
open Flx_prop
open Flx_beta

let null_table = Hashtbl.create 3

let add_inst syms bbdfns ref_insts1 (i,ts) =
    (*
    print_endline ("Attempt to register instance " ^ si i ^ "[" ^
    catmap ", " (sbt syms.dfns) ts ^ "]");
    *)
  let sr = "_dummy_[add_inst]",0,0,0,0 in
  let ts = map (fun t -> beta_reduce syms sr t) ts in

  let i,ts = Flx_typeclass.fixup_typeclass_instance syms bbdfns i ts in
    (*
    print_endline ("remapped to instance " ^ si i ^ "[" ^
    catmap ", " (sbt syms.dfns) ts ^ "]");
    *)
  let x = i, map (fun t -> reduce_type (lstrip syms.dfns t)) ts in
  let has_variables =
    fold_left
    (fun truth t -> truth ||
      try var_occurs t
      with _ -> failwith ("[add_inst] metatype in var_occurs for " ^ sbt syms.dfns t)
    )
    false
    ts
  in
  if has_variables then
  failwith
  (
    "Attempt to register instance " ^ si i ^ "[" ^
    catmap ", " (sbt syms.dfns) ts ^
    "] with type variable in a subscript"
  )
  ;
  if not (FunInstSet.mem x !ref_insts1)
  && not (Hashtbl.mem syms.instances x)
  then begin
    ref_insts1 := FunInstSet.add x !ref_insts1
  end

let rec process_expr syms bbdfns ref_insts1 hvarmap sr ((e,t) as be) =
  (*
  print_endline ("Process expr " ^ sbe syms.dfns be ^ " .. raw type " ^ sbt syms.dfns t);
  print_endline (" .. instantiated type " ^ string_of_btypecode syms.dfns (varmap_subst hvarmap t));
  *)
  let ue e = process_expr syms bbdfns ref_insts1 hvarmap sr e in
  let ui i ts = add_inst syms bbdfns ref_insts1 (i,ts) in
  let ut t = register_type_r ui syms bbdfns [] sr t in
  let vs t = varmap_subst hvarmap t in
  let t' = vs t in
  ut t'
  ;
  (* CONSIDER DOING THIS WITH A MAP! *)
  begin match e with
  | `BEXPR_parse (e,ii) ->
    ue e; iter (fun i -> ui i []) ii

  | `BEXPR_deref e
  | `BEXPR_get_n (_,e)
  | `BEXPR_match_case (_,e)
  | `BEXPR_case_arg (_,e)
  | `BEXPR_case_index e
    -> ue e

  | `BEXPR_get_named (i,((oe,ot) as obj)) ->
    (*
    print_endline "Get named: class member";
    *)
    ue obj;
    (*
    print_endline "Register object expr";
    *)
    (* instantiate member with binding for class type parameters *)
    begin match ot with
    | `BTYP_inst (j,ts)
(*    | `BTYP_lvalue (`BTYP_inst (j,ts)) *)
      ->
      (*
      print_endline ("Register member " ^ si i^ ", ts=" ^ catmap "," (sbt syms.dfns) ts);
      *)
      let ts = map vs ts in
      ui i ts
    | _ ->
      syserr sr (
        "[flx_inst:process_expr:BEXPR_get_named] unexpected object type " ^
        sbt syms.dfns ot
      )
    end

  | `BEXPR_apply_prim (index,ts,a)
  | `BEXPR_apply_direct (index,ts,a)
  | `BEXPR_apply_struct (index,ts,a)
  | `BEXPR_apply_stack (index,ts,a)
  | `BEXPR_apply ((`BEXPR_closure (index,ts),_),a) ->
    (*
    print_endline "apply direct";
    *)
    let id,parent,sr2,entry =
      try Hashtbl.find bbdfns index
      with _ -> failwith ("[process_expr(apply instance)] Can't find index " ^ si index)
    in
    begin match entry with
    (* function type not needed for direct call *)
    | `BBDCL_fun _
    | `BBDCL_callback _
    | `BBDCL_function _
    | `BBDCL_nonconst_ctor _
      ->
      let ts = map vs ts in
      ui index ts; ue a
    | `BBDCL_procedure _ ->
      failwith "Use of mangled procedure in expression! (should have been lifted out)"

    (* the remaining cases are struct/variant type constructors,
    which probably don't need types either .. fix me!
    *)
    (* | _ -> ue f; ue a *)
    | _ ->
      (*
      print_endline "struct component?";
      *)
      ui index ts; ue a
    end

  | `BEXPR_apply_method_direct (obj,meth,ts,a)
  | `BEXPR_apply_method_stack (obj,meth,ts,a)
  | `BEXPR_apply ((`BEXPR_method_closure (obj,meth,ts),_),a) ->
    (*
    print_endline "method apply";
    *)
    ue obj;
    ui meth ts;
    ue a

  | `BEXPR_apply (e1,e2) ->
    (*
    print_endline "Simple apply";
    *)
    ue e1; ue e2

  | `BEXPR_tuple es ->
    iter ue es;
    register_tuple syms (vs t)

  | `BEXPR_record es ->
    let ss,es = split es in
    iter ue es;
    register_tuple syms (vs t)

  | `BEXPR_variant (s,e) ->
    ue e

  | `BEXPR_case (_,t) -> ut (vs t)

  | `BEXPR_ref (i,ts)
  | `BEXPR_name (i,ts)
  | `BEXPR_closure (i,ts)
    ->
    (* substitute out display variables *)
    (*
    print_endline ("Raw Variable " ^ si i ^ "[" ^ catmap "," (sbt syms.dfns) ts ^ "]");
    *)
    let ts = map vs ts in
    (*
    print_endline ("Variable with mapped ts " ^ si i ^ "[" ^ catmap "," (sbt syms.dfns) ts ^ "]");
    *)
    ui i ts;
    (*
    print_endline "Instance done";
    *)
    iter ut ts
    (*
    ;
    print_endline "ts done";
    *)

  | `BEXPR_not e -> ue e
  | `BEXPR_new e -> ue e
  | `BEXPR_likely e -> ue e
  | `BEXPR_unlikely e -> ue e

  | `BEXPR_method_closure (e,i,ts) ->
    (*
    print_endline "method closure";
    *)
    ue e;
    let ts = map vs ts in
    ui i ts; iter ut ts

  | `BEXPR_literal _ -> ()
  | `BEXPR_expr (_,t) -> ut t
  | `BEXPR_range_check (e1,e2,e3) -> ue e1; ue e2; ue e3
  | `BEXPR_coerce (e,t) -> ue e; ut t
  end

and process_exe syms bbdfns ref_insts1 ts hvarmap (exe:bexe_t) =
  let ue sr e = process_expr syms bbdfns ref_insts1 hvarmap sr e in
  let uis i ts = add_inst syms bbdfns ref_insts1 (i,ts) in
  let ui i = uis i ts in
  (*
  print_endline ("processing exe " ^ string_of_bexe syms.dfns bbdfns 0 exe);
  print_endline ("With ts = " ^ catmap "," (sbt syms.dfns) ts);
  *)
  (* TODO: replace with a map *)
  match exe with
  | `BEXE_axiom_check _ -> assert false
  | `BEXE_call_prim (sr,i,ts,e2)
  | `BEXE_call_direct (sr,i,ts,e2)
  | `BEXE_jump_direct (sr,i,ts,e2)
  | `BEXE_call_stack (sr,i,ts,e2)
    ->
    let ut t = register_type_r uis syms bbdfns [] sr t in
    let vs t = varmap_subst hvarmap t in
    let ts = map vs ts in
    iter ut ts;
    uis i ts;
    ue sr e2

  | `BEXE_call_method_direct (sr,obj,meth,ts,a)
  | `BEXE_call_method_stack (sr,obj,meth,ts,a) ->
    let ut t = register_type_r uis syms bbdfns [] sr t in
    let vs t = varmap_subst hvarmap t in
    let ts = map vs ts in
    ue sr obj;
    iter ut ts;
    uis meth ts;
    ue sr a

  | `BEXE_apply_ctor (sr,i1,i2,ts,i3,e2)
  | `BEXE_apply_ctor_stack (sr,i1,i2,ts,i3,e2)
    ->
    let ut t = register_type_r uis syms bbdfns [] sr t in
    let vs t = varmap_subst hvarmap t in
    let ts = map vs ts in
    iter ut ts;
    ui i1; (* this is wrong?: initialisation is not use .. *)
    uis i2 ts;
    (*
    print_endline ("INSTANTIATING CLASS " ^ si i2 ^ "<"^catmap "," (sbt syms.dfns) ts^">");
    *)
    uis i3 ts;
    (*
    print_endline ("INSTANTIATING CONSTRUCTOR " ^ si i3 ^ "<"^catmap "," (sbt syms.dfns) ts^">");
    *)
    ue sr e2

  | `BEXE_call (sr,e1,e2)
  | `BEXE_jump (sr,e1,e2)
    -> ue sr e1; ue sr e2

  | `BEXE_assert (sr,e)
  | `BEXE_loop (sr,_,e)
  | `BEXE_ifgoto (sr,e,_)
  | `BEXE_fun_return (sr,e)
  | `BEXE_yield (sr,e)
    ->
      ue sr e

  | `BEXE_assert2 (sr,_,e1,e2)
    ->
     begin match e1 with Some e -> ue sr e | None -> () end;
     ue sr e2

  | `BEXE_init (sr,i,e) ->
    (*
    print_endline ("[flx_inst] Initialisation " ^ si i ^ " := " ^ sbe syms.dfns bbdfns e);
    *)
    let vs' = get_vs bbdfns i in
    (*
    print_endline ("vs=" ^ catmap "," (fun (s,i)-> s^ "<" ^ si i ^ ">") vs');
    print_endline ("Input ts = " ^ catmap "," (sbt syms.dfns) ts);
    print_endline ("Varmap = " ^ Hashtbl.fold
      (fun i k acc -> acc ^ "\n"^si i ^ " |-> " ^ sbt syms.dfns k )
      hvarmap ""
    );
    *)
    let ts = map (fun (s,i) -> `BTYP_var (i,`BTYP_type 0)) vs' in
    let ts = map (varmap_subst hvarmap) ts in
    uis i ts; (* this is wrong?: initialisation is not use .. *)
    ue sr e

  | `BEXE_assign (sr,e1,e2) -> ue sr e1; ue sr e2

  | `BEXE_svc (sr,i) ->
    let vs' = get_vs bbdfns i in
    let ts = map (fun (s,i) -> `BTYP_var (i,`BTYP_type 0)) vs' in
    let ts = map (varmap_subst hvarmap) ts in
    uis i ts

  | `BEXE_label _
  | `BEXE_halt _
  | `BEXE_trace _
  | `BEXE_goto _
  | `BEXE_code _
  | `BEXE_nonreturn_code _
  | `BEXE_comment _
  | `BEXE_nop _
  | `BEXE_proc_return _
  | `BEXE_begin
  | `BEXE_end
    -> ()

and process_exes syms bbdfns ref_insts1 ts hvarmap exes =
  iter (process_exe syms bbdfns ref_insts1 ts hvarmap) exes

and process_function syms bbdfns hvarmap ref_insts1 index sr argtypes ret exes ts =
  (*
  print_endline ("Process function " ^ si index);
  *)
  process_exes syms bbdfns ref_insts1 ts hvarmap exes ;
  (*
  print_endline ("Done Process function " ^ si index);
  *)

and process_production syms bbdfns ref_insts1 p ts =
  let uses_symbol (_,nt) = match nt with
  | `Nonterm ii -> iter (fun i -> add_inst syms bbdfns ref_insts1 (i,ts)) ii
  | `Term i -> () (* HACK! This is a union constructor name  we need to 'use' the union type!! *)
  in
  iter uses_symbol p

and process_inst syms bbdfns instps ref_insts1 i ts inst =
  let uis i ts = add_inst syms bbdfns ref_insts1 (i,ts) in
  let ui i = uis i ts in
  let id,parent,sr,entry =
    try Hashtbl.find bbdfns i
    with Not_found -> failwith ("[process_inst] Can't find index " ^ si i)
  in
  let do_reqs vs reqs =
    iter (
      fun (i,ts)->
      if i = 0 then
        clierr sr ("Entity " ^ id ^ " has uninstantiable requirements");
      uis i( map vs ts)
    )
    reqs
  in
  let ue hvarmap e = process_expr syms bbdfns ref_insts1 hvarmap sr e in
  let rtr t = register_type_r uis syms bbdfns [] sr t in
  let rtnr t = register_type_nr syms (reduce_type (lstrip syms.dfns t)) in
  if syms.compiler_options.print_flag then
  print_endline ("//Instance "^si inst ^ "="^id^"<" ^ si i ^ ">[" ^ catmap "," (string_of_btypecode syms.dfns) ts ^ "]");
  match entry with
  | `BBDCL_glr (props,vs,ret, (p,exes)) ->
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    process_function syms bbdfns null_table ref_insts1 i sr [] ret exes ts;
    process_production syms bbdfns ref_insts1 p ts

  | `BBDCL_regmatch (props,vs,(ps,traint),ret,(_,_,h,_))  ->
    let argtypes = map (fun {ptyp=t}->t) ps in
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    Hashtbl.iter
    (fun _ e -> ue hvarmap e)
    h;
    iter (fun {pindex=i} -> ui i) ps

   | `BBDCL_reglex (props,vs,(ps,traint),le,ret,(_,_,h,_)) ->
    let argtypes = map (fun {ptyp=t}->t) ps in
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    Hashtbl.iter
    (fun _ e -> ue hvarmap e)
    h;
    iter (fun {pindex=i} -> ui i) ps;
    ui le; (* lexeme end .. *)
    ui i

  | `BBDCL_function (props,vs,(ps,traint),ret,exes) ->
    let argtypes = map (fun {ptyp=t}->t) ps in
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    if instps || mem `Cfun props then
      iter (fun {pindex=i; ptyp=t} ->
        ui i;
        rtr (varmap_subst hvarmap t)
      )
      ps
    ;
    (*
    print_endline ("Instantiating function " ^ id);
    print_endline ("vs=" ^ catmap "," (fun (s,i)-> s^ "<" ^ si i ^ ">") vs);
    print_endline ("Input ts = " ^ catmap "," (sbt syms.dfns) ts);
    print_endline ("Varmap = " ^ Hashtbl.fold
      (fun i k acc -> acc ^ "\n"^si i ^ " |-> " ^ sbt syms.dfns k )
      hvarmap ""
    );
    *)
    process_function syms bbdfns hvarmap ref_insts1 i sr argtypes ret exes ts

  | `BBDCL_procedure (props,vs,(ps,traint), exes) ->
    let argtypes = map (fun {ptyp=t}->t) ps in
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    if instps || mem `Cfun props then
      iter (fun {pindex=i; ptyp=t} ->
        ui i;
        rtr (varmap_subst hvarmap t)
      )
      ps
    ;
    process_function syms bbdfns hvarmap ref_insts1 i sr argtypes `BTYP_void exes ts

  | `BBDCL_class (props,vs) ->
    assert (length vs = length ts);
    (*
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    *)

    rtnr (`BTYP_inst (i,ts));

    (*
    print_endline "Registering class object";
    *)
    ui i

  | `BBDCL_union (vs,ps) ->
    let argtypes = map (fun (_,_,t)->t) ps in
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let tss = map (varmap_subst hvarmap) argtypes in
    iter rtr tss;
    rtnr (`BTYP_inst (i,ts))


  | `BBDCL_struct (vs,ps)
  | `BBDCL_cstruct (vs,ps)
    ->
    let argtypes = map snd ps in
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let tss = map (varmap_subst hvarmap) argtypes in
    iter rtr tss;
    rtnr (`BTYP_inst (i,ts))

  | `BBDCL_newtype (vs,t) ->
    rtnr t;
    rtnr (`BTYP_inst (i,ts))

  | `BBDCL_cclass (vs,ps)
    ->
    (*
    let argtypes = map (function
      | `BMemberVal (_,t)
      | `BMemberVar (_,t)
      | `BMemberFun (_,_,t)
      | `BMemberProc (_,_,t)
      | `BMemberCtor (_,t)  -> t
    ) ps in
    *)
    assert (length vs = length ts);
    (*
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let tss = map (varmap_subst hvarmap) argtypes in
    iter rtr tss;
    *)
    rtnr (`BTYP_inst (i,ts))

  | `BBDCL_val (vs,t)
  | `BBDCL_var (vs,t)
  | `BBDCL_ref (vs,t)
  | `BBDCL_tmp (vs,t)
    ->
    (*
    print_endline "Registering variable";
    *)
    if length vs <> length ts
    then syserr sr
    (
      "ts/vs mismatch instantiating variable " ^ id ^ "<"^si i^">, inst "^si inst^": vs = [" ^
      catmap ";" (fun (s,i)-> s ^"<"^si i^">") vs ^ "], " ^
      "ts = [" ^
      catmap ";" (fun t->sbt syms.dfns t) ts ^ "]"
    );
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let t = varmap_subst hvarmap t in
    rtr t

  | `BBDCL_const (props,vs,t,_,reqs) ->
    (*
    print_endline "Register const";
    *)
    assert (length vs = length ts);
    (*
    if length vs <> length ts
    then syserr sr
    (
      "ts/vs mismatch index "^si i^", inst "^si inst^": vs = [" ^
      catmap ";" (fun (s,i)-> s ^"<"^si i^">") vs ^ "], " ^
      "ts = [" ^
      catmap ";" (fun t->sbt syms.dfns t) ts ^ "]"
    );
    *)
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let t = varmap_subst hvarmap t in
    rtr t;
    let vs t = varmap_subst hvarmap t in
    do_reqs vs reqs

  (* shortcut -- header and body can only require other header and body *)
  | `BBDCL_insert (vs,s,ikind,reqs)
    ->
    (*
    print_endline ("Handling requirements of header/body " ^ s);
    *)
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let vs t = varmap_subst hvarmap t in
    do_reqs vs reqs


  | `BBDCL_fun (props,vs,argtypes,ret,_,reqs,_) ->
    (*
    print_endline ("Handling requirements of fun " ^ id);
    *)
    if length vs <> length ts then
      print_endline ("For fun " ^ id ^ " vs=" ^ print_bvs vs ^
      ", but ts=" ^ catmap "," (sbt syms.dfns) ts)
    ;
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let vs t = varmap_subst hvarmap t in
    do_reqs vs reqs;
    process_function syms bbdfns hvarmap ref_insts1 i sr argtypes ret [] ts

  | `BBDCL_callback (props,vs,argtypes_cf,argtypes_c,k,ret,reqs,_) ->
    (*
    print_endline ("Handling requirements of callback " ^ id);
    *)
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let vs t = varmap_subst hvarmap t in
    do_reqs vs reqs;

    let ret = varmap_subst hvarmap ret in
    rtr ret;

    (* prolly not necessary .. *)
    let tss = map (varmap_subst hvarmap) argtypes_cf in
    iter rtr tss;

    (* just to register 'address' .. lol *)
    let tss = map (varmap_subst hvarmap) argtypes_c in
    iter rtr tss

  | `BBDCL_proc (props,vs,argtypes,_,reqs) ->
    (*
    print_endline ("[flx_inst] Handling requirements of proc " ^ id);
    print_endline ("vs = " ^ catmap "," (fun (s,i) -> s ^ "<" ^ si i ^ ">") vs);
    print_endline ("ts = " ^ catmap "," (sbt syms.dfns) ts);
    *)
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let vs t = varmap_subst hvarmap t in
    do_reqs vs reqs;
    process_function syms bbdfns hvarmap ref_insts1 i sr argtypes `BTYP_void [] ts

  | `BBDCL_abs (vs,_,_,reqs)
    ->
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let vs t = varmap_subst hvarmap t in
    do_reqs vs reqs

  | `BBDCL_nonconst_ctor (vs,uidx,udt, ctor_idx, ctor_argt, evs, etraint) ->
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in

    (* we don't register the union .. it's a uctor anyhow *)
    let ctor_argt = varmap_subst hvarmap ctor_argt in
    rtr ctor_argt

   | `BBDCL_typeclass _ -> ()
   | `BBDCL_instance (props,vs,con,tc,ts) -> ()

(*
  This routine creates the instance tables.
  There are 2 tables: instance types and function types (including procs)

  The type registry holds the types used.
  The instance registry holds a pair:
  (index, types)
  where index is the function or procedure index,
  and types is a list of types to instantiated it.

  The algorithm starts with a list of roots, being
  the top level init routine and any exported functions.
  These must be non-generic.

  It puts these into a set of functions to be examined.
  Then it begins examining the set by chosing one function
  and moving it to the 'examined' set.

  It registers the function type, and then
  examines the body.

  In the process of examining the body,
  every function or procedure call is examined.

  The function being called is added to the
  to be examined list with the calling type arguments.
  Note that these type arguments may include type variables
  which have to be replaced by their instances which are
  passed to the examination routine.

  The process continues until there are no unexamined
  functions left. The effect is to instantiate every used
  type and function.
*)

let instantiate syms bbdfns instps (root:bid_t) (bifaces:biface_t list) =
  Hashtbl.clear syms.instances;
  Hashtbl.clear syms.registry;

  (* empty instantiation registry *)
  let insts1 = ref FunInstSet.empty in

  begin
    (* append routine to add an instance *)
    let add_cand i ts = insts1 := FunInstSet.add (i,ts) !insts1 in

    (* add the root *)
    add_cand root [];

    (* add exported functions, and register exported types *)
    let ui i ts = add_inst syms bbdfns insts1 (i,ts) in
    iter
    (function
      | `BIFACE_export_python_fun (_,x,_)
      | `BIFACE_export_fun (_,x,_) ->
        let _,_,sr,entry = Hashtbl.find bbdfns x in
        begin match entry with
        | `BBDCL_procedure (props,_,(ps,_),_)
        | `BBDCL_function (props,_,(ps,_),_,_) ->
        begin match ps with
        | [] -> ()
        | [{ptyp=t}] -> register_type_r ui syms bbdfns [] sr t
        | _ ->
          let t =
            `BTYP_tuple
            (
              map
              (fun {ptyp=t} -> t)
              ps
            )
          in
          register_type_r ui syms bbdfns [] sr t;
          register_type_nr syms t;
        end
        | _ -> assert false
        end
        ;
        add_cand x []

      | `BIFACE_export_type (sr,t,_) ->
        register_type_r ui syms bbdfns [] sr t
    )
    bifaces
  end
  ;

  (* NEW: if a symbol is monomorphic use its index as its instance! *)
  (* this is a TRICK .. saves remapping the root/exports, since they
     have to be monomorphic anyhow
  *)
  let add_instance i ts =
    let n =
      match ts with
      | [] -> i
      | _ -> let n = !(syms.counter) in incr (syms.counter); n
    in
    Hashtbl.add syms.instances (i,ts) n;
    n
  in

  while not (FunInstSet.is_empty !insts1) do
    let (index,vars) as x = FunInstSet.choose !insts1 in
    insts1 := FunInstSet.remove x !insts1;
    let inst = add_instance index vars in
    process_inst syms bbdfns instps insts1 index vars inst
  done


(* BUG!!!!! Abstract type requirements aren't handled!! *)