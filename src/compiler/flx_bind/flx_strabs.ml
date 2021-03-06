open Flx_util
open Flx_types
open Flx_btype
open Flx_bparameter
open Flx_bexpr
open Flx_bbdcl
open Flx_print
open Flx_set
open Flx_mtypes2
open Flx_typing
open Flx_mbind
open List
open Flx_unify
open Flx_generic
open Flx_maps
open Flx_exceptions

type strabs_state_t = unit

let make_strabs_state () = ()

let check_inst bsym_table i ts =
(*
print_endline ("Check inst " ^ string_of_int i);
*)
  let entry = 
    try Flx_bsym_table.find_bbdcl bsym_table i 
    with Not_found -> failwith ("can't find entry " ^ string_of_int i ^ " in bsym table")
  in
  match entry with
  | BBDCL_newtype (vs,t) -> 
    let t' = tsubst vs ts t in 
(*
    print_endline ("Downgrading abstract type " ^ string_of_int i ^ 
    "[vs=" ^ catmap "," (fun (s,i)-> s^"<"^string_of_int i^">") vs ^ "]-->" ^ sbt bsym_table t ^ "/" ^
    "[ts=" ^ catmap "," (Flx_print.sbt bsym_table) ts ^ "]" ^
    " to " ^ Flx_print.sbt bsym_table t');
*)
    t'
  | _ -> btyp_inst (i,ts)

let fixtype bsym_table t =
  let chk i ts = check_inst bsym_table i ts in
  let rec f_btype t =
    match Flx_btype.map ~f_btype t with
    | BTYP_inst (i,ts) ->
        let ts = map f_btype ts in
        chk i ts
    | x -> x
  in
  f_btype t

let fixexpr bsym_table e =
  let rec f_bexpr e =
    match Flx_bexpr.map ~f_btype:(fixtype bsym_table) ~f_bexpr e with
    | BEXPR_apply ( (BEXPR_closure(i,_),_),a),_
    | BEXPR_apply_direct (i,_,a),_
    | BEXPR_apply_prim (i,_,a),_
      when (try Flx_bsym_table.is_identity bsym_table i with Not_found -> failwith ("strabs:is_identity checked not found on " ^ string_of_int i)) -> a
    | x -> x
  in
  f_bexpr e

let fixbexe bsym_table x =
  Flx_bexe.map ~f_btype:(fixtype bsym_table) ~f_bexpr:(fixexpr bsym_table) x

let fixbexes bsym_table bexes = map (fixbexe bsym_table) bexes

let fixps bsym_table (ps,traint) =
  List.map (fun p -> { p with ptyp=fixtype bsym_table p.ptyp }) ps,
  (
  match traint with
  | None -> None
  | Some t -> Some (fixexpr bsym_table t)
  )

let strabs_symbol state bsym_table index bsym =
  let ft t = fixtype bsym_table t in
  let fts ts = map (fixtype bsym_table) ts in
  let fe e = fixexpr bsym_table e in
  let fxs xs = fixbexes bsym_table xs in
  let fp bps = fixps bsym_table bps in

  let h bbdcl = Flx_bsym_table.update_bbdcl bsym_table index bbdcl in
  match Flx_bsym.bbdcl bsym with
  | BBDCL_invalid ->
      assert false

  | BBDCL_module ->
      h (bbdcl_module ())

  | BBDCL_fun (props, bvs, bps, ret, bexes) ->
      h (bbdcl_fun (props, bvs, fp bps, ft ret, fxs bexes))

  | BBDCL_val (bvs, t, kind) ->
      h (bbdcl_val (bvs, ft t, kind))

  | BBDCL_newtype (bvs, t) ->
      (* Can't downgrade this newtype yet. *)
      ()

  | BBDCL_external_type (bvs, btqs, c, breqs) ->
      h (bbdcl_external_type (bvs, btqs, c, breqs))

  | BBDCL_external_const (props, bvs, t, c, breqs) ->
      h (bbdcl_external_const (props,  bvs, ft t, c, breqs))

  | BBDCL_external_fun (props, bvs, ts, t, breqs, prec, kind) ->
      (* Ignore identity functions. *)
      if kind = `Code Flx_code_spec.Identity then () else
      let kind =
        match kind with
        | `Callback (ts2, j) -> `Callback (fts ts2, j)
        | _ -> kind
      in
      h (bbdcl_external_fun (props, bvs, fts ts, ft t, breqs, prec, kind))

  | BBDCL_external_code (bvs, c, ikind, breqs) ->
      h (bbdcl_external_code (bvs, c, ikind, breqs))

  | BBDCL_union (bvs, cts) ->
      let cts = map (fun (s,j,t) -> s,j,ft t) cts in
      h (bbdcl_union (bvs, cts))

  | BBDCL_struct (bvs, cts) ->
      let cts = map (fun (s,t) -> s,ft t) cts in
      h (bbdcl_struct (bvs, cts))

  | BBDCL_cstruct (bvs, cts, breqs) ->
      let cts = map (fun (s,t) -> s,ft t) cts in
      h (bbdcl_cstruct (bvs, cts, breqs))

  | BBDCL_typeclass (props, bvs) ->
      h (bbdcl_typeclass (props, bvs))

  | BBDCL_instance (props, bvs, t, j, ts) ->
      h (bbdcl_instance (props, bvs, ft t, j, fts ts))

  | BBDCL_const_ctor (bvs, j, t1, k, evs, etraint) ->
      h (bbdcl_const_ctor (bvs, j, ft t1, k, evs, ft etraint))

  | BBDCL_nonconst_ctor (bvs, j, t1, k,t2, evs, etraint) ->
      h (bbdcl_nonconst_ctor (bvs, j, ft t1, k, ft t2, evs, ft etraint))

  | BBDCL_axiom ->
      h (bbdcl_axiom ())

  | BBDCL_lemma ->
      h (bbdcl_lemma ())

  | BBDCL_reduce ->
      h (bbdcl_reduce ())

let strabs state bsym_table =
  (* Copy the bsym_table since we're going to directly modify it. *)
  let bsym_table' = Flx_bsym_table.copy bsym_table in
  Flx_bsym_table.iter
    (fun bid _ sym -> 
        (*
        print_endline ("Strabs on " ^ string_of_int bid ^ " " ^ sym.Flx_bsym.id);
        *)
        begin try
          strabs_symbol state bsym_table bid sym
        with Not_found ->
          failwith ("Strabs chucked not found processing " ^ string_of_int bid)
        end
(*
        ;
        print_endline ("Strabs on " ^ string_of_int bid ^ " done")
*)
    )
    bsym_table'
