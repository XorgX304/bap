(** Implementation of [efse] algorithm from DWP paper. *)

module CA = Cfg.AST
module VM = Var.VarMap
type var = Ast.var
type exp = Ast.exp

type stmt = | Assign of (var * exp)
            | Assert of exp
            | Ite of (exp * prog * prog)
and prog = stmt list

let rec stmt_to_string = function
  | Assign(v,e) -> Printf.sprintf "%s = %s" (Var.name v) (Pp.ast_exp_to_string e)
  | Assert e -> Printf.sprintf "Assert %s" (Pp.ast_exp_to_string e)
  | Ite(e, s1, s2) -> Printf.sprintf "If %s Then (%s) Else (%s)" (Pp.ast_exp_to_string e) (prog_to_string s1) (prog_to_string s2)
and prog_to_string = function
  | [] -> "/* Skip */"
  | x::[] -> stmt_to_string x
  | x::tl -> (stmt_to_string x)^"; "^(prog_to_string tl)

module ToEfse = struct
  let of_rev_straightline stmts =
    let rec f acc = function
      | [] -> acc
      | Ast.Move(v,e,_)::tl -> f (Assign(v,e)::acc) tl
      | Ast.Assert(e,_)::tl -> f (Assert(e)::acc) tl
      | Ast.Label _::tl
      | Ast.Comment _::tl -> f acc tl
      | s::_ -> failwith (Printf.sprintf "Found unexpected statement in straightline code: %s" (Pp.ast_stmt_to_string s))
    in
    f [] stmts

  let of_straightline stmts = of_rev_straightline (List.rev stmts)

  let of_astcfg ?entry ?exit cfg =
    let cgcl_to_fse s =
    (* k is a continuation *)
      let rec c s (k : prog -> prog) = match s with
        | Gcl.CChoice(cond, e1, e2) ->
          c e1 (fun ce1 ->
            c e2 (fun ce2 ->
              k [Ite(cond, ce1, ce2)]))
        | Gcl.Cunchoice(e1, e2) ->
          failwith "Unguarded choices not allowed"
        | Gcl.CSeq [] ->
          k []
        | Gcl.CSeq(e::es) ->
        (* dprintf "l: %d" (List.length (e::es)); *)
          c e (fun ce -> c (Gcl.CSeq es) (fun ces -> k ce@ces))
        | Gcl.CAssign b ->
          let bb_s = Cfg.AST.get_stmts cfg b in
          let e = match List.rev bb_s with
            | [] -> []
            | (Ast.Jmp _ | Ast.CJmp _ | Ast.Halt _)::rest -> of_rev_straightline rest
            | _ -> of_straightline bb_s
          in
          k e
      in
      c s Util.id
    in
    cgcl_to_fse (Gcl.gclhelp_of_astcfg ?entry ?exit cfg)

  let passified_of_ssa ?entry ?exit cfg =
    let ast = Cfg_ssa.to_astcfg ~dsa:true cfg in
    let convert = function
      | Some v -> Some(CA.find_vertex ast (Cfg.SSA.G.V.label v))
      | None -> None
    in
    let entry = convert entry and exit = convert exit in
    of_astcfg ?entry ?exit ast

  let passified_of_astcfg ?entry ?exit cfg =
    let {Cfg_ssa.cfg=ssa; to_ssavar=tossa} = Cfg_ssa.trans_cfg cfg in
    let convert = function
      | Some v -> Some(Cfg.SSA.find_vertex ssa (CA.G.V.label v))
      | None -> None
    in
    let entry = convert entry and exit = convert exit in
    let g = passified_of_ssa ?entry ?exit ssa in
    (g,tossa)


end
include ToEfse

module type Delta =
sig
  type t
  val create : unit -> t
  val set : t -> var -> exp -> t
  (** Setter method *)
  val get : t -> var -> exp
  (** Getter method.  Raises [Not_found] exception if variable is
      not set. *)
end

module VMDelta =
struct
  type t = exp VM.t
  let create () =
    VM.empty
  let set h v e =
    VM.add v e h
  let get h v =
    VM.find v h
end

module Make(D:Delta) =
struct

  (* Substitute any reference to a variable with it's value in
     delta.

     XXX: Support Let bindings.
  *)
  let sub_eval delta e =
    let v = object(self)
      inherit Ast_visitor.nop
      (* We can't use rvar because we need to return an exp. *)
      method visit_exp = function
        | Ast.Var v ->
          (try
          (* do NOT do children, because expressions are already
             evaluated. *)
            `ChangeTo (D.get delta v)
          with Not_found ->
            `DoChildren)
        | _ -> `DoChildren
    end in
    Ast_visitor.exp_accept v e

(** Inefficient fse algorithm for unpassified programs. *)
  let fse_unpass p post =
    let rec fse_unpass delta pi = function
      | [] -> pi
      | Assign(v, e)::tl ->
        let value = sub_eval delta e in
        let delta' = D.set delta v value in
        fse_unpass delta' pi tl
      | Assert(e)::tl ->
        let value = sub_eval delta e in
        let pi' = Ast.exp_and pi value in
        fse_unpass delta pi' tl
      | Ite(e, s1, s2)::tl ->
        let value_t = sub_eval delta e in
        let pi_t = Ast.exp_and pi value_t in
        let value_f = Ast.exp_not value_t in
        let pi_f = Ast.exp_and pi value_f in
        let fse_t = fse_unpass delta pi_t (s1@tl) in
        let fse_f = fse_unpass delta pi_f (s2@tl) in
        Ast.exp_or fse_t fse_f
    in
    fse_unpass (D.create ()) post p

(** Inefficient fse algorithm for passified programs. *)
let fse_pass p post =
  let rec fse_pass delta pi = function
    | [] -> pi
    | Assign(v, e)::tl ->
      let value = sub_eval delta e in
      let pi' = Ast.exp_and pi (Ast.exp_eq (Ast.Var v) value) in
      fse_pass delta pi' tl
    | Assert(e)::tl ->
      let value = sub_eval delta e in
      let pi' = Ast.exp_and pi value in
      fse_pass delta pi' tl
    | Ite(e, s1, s2)::tl ->
      let value_t = sub_eval delta e in
      let pi_t = Ast.exp_and pi value_t in
      let value_f = Ast.exp_not value_t in
      let pi_f = Ast.exp_and pi value_f in
      let fse_t = fse_pass delta pi_t (s1@tl) in
      let fse_f = fse_pass delta pi_f (s2@tl) in
      Ast.exp_or fse_t fse_f
  in
  fse_pass (D.create ()) post p

end

module VMBack = Make(VMDelta)
include VMBack

(** Efficient fse algorithm for passified programs. *)
let efse p pi =
  let rec efse pi = function
    | [] -> pi
    | Assign(v, e)::tl ->
      let pi' = Ast.exp_and pi (Ast.exp_eq (Ast.Var v) e) in
      efse pi' tl
    | Assert e::tl ->
      let pi' = Ast.exp_and pi e in
      efse pi' tl
    | Ite(e, s1, s2)::tl ->
      let pi_t = efse e s1 in
      let pi_f = efse (Ast.exp_not e) s2 in
      Ast.exp_and (Ast.exp_and pi (Ast.exp_or pi_t pi_f)) (efse Ast.exp_true tl)
  in
  efse pi p
