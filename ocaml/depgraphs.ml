(** Dependence Graphs. We currently support the program dependence
    graph (PDG), a data dependence graph (DDG), and the control
    dependence graph (CDG). 
*)

open Cfg

module MakeCDG (C: CFG) = 
struct
  module G = C.G

  module Dbg = Debug.Make(struct let name = "CDG" and default=`NoDebug end)
  open Dbg

  (* the graph we will return *)
(*  module CDG =   Graph.Persistent.Digraph.Concrete(G.V) *)
(*  include CDG *)

  (* reverse graph  *)
  module G' = struct
    type t = G.t
    module V = G.V

    let pred c n = 
      match G.V.label n with
	  BB_Entry -> (C.find_vertex c BB_Exit)::(G.succ c n)
	| _ -> G.succ c n 
    let succ = G.pred
    let nb_vertex = G.nb_vertex
    let fold_vertex = G.fold_vertex
    let iter_vertex = G.iter_vertex

  end 

  (* inverse dominators module *)
  module D = Dominator.Make(G') 
    

    
  (** This function computes control dependencies.
      This implements the algorithm in the Tiger Book p.454 (ML
      version) with the exception we do not add a new node before
      entry. Therefore all nodes are control dependent on BB_Entry.
      
      Note that BB_Exit will not be control dependent on anything,
      thus a lone node in the graph (you can prune it away if you want
      using other utilities in BAP)

      @return a map from a node to its parents in the CDG tree.

  *)
  let compute_cd cfg =
    (* Note that we don't add an extra entry node, so everything is control
       dependent on the entry node of the CFG *)
    let exit_node = C.find_vertex cfg  BB_Exit in 
    let () = dprintf "compute_cdg: computing idom" in
    let idom = D.compute_idom cfg exit_node in
    let () = dprintf "compute_cdg: computing dom tree" in
    let dom_tree = D.idom_to_dom_tree cfg idom in
    let () = dprintf "compute_cdg: computing dom frontier" in
      D.compute_dom_frontier cfg dom_tree idom 

(** computes the control dependence graph (cdg), which turns the
    result of [compute_cd] below into a graph*)
  let compute_cdg cfg  = 
    let df = compute_cd cfg in 
    let vertices =  C.G.fold_vertex (fun v g -> C.add_vertex g v) cfg (C.empty ()) in
      C.G.fold_vertex
	(fun v g ->
	   if C.G.in_degree cfg v > 0
	   then List.fold_left (fun g v' -> C.add_edge g v' v) g (df v)
	   else g (* can't compute DF for lonely nodes *)
	)
	cfg vertices

end

(** control dependence graphs for SSA graphs *)
module CDG_SSA = MakeCDG(Cfg.SSA)

(** control dependence graphs for AST graphs *)
module CDG_AST = MakeCDG(Cfg.AST)


module DDG_SSA = 
struct

  (** a location in the CFG program.  *)
  type location = Cfg.SSA.G.V.t * int

  module Dbg = Debug.Make(struct let name = "DDG" and default=`NoDebug end)
  open Dbg
  module VH = Var.VarHash
  module VS = Var.VarSet

  (** [compute_dd cfg] the tuple vars,fd,fu. vars is the set of
      variables used by the graph.  fd is a hashtbl from vars to the
      definition location.  fu is a hashtbl from vars to their use
      locations.  Unlike graphs such as DDG and PDG (below), we do not
      assume that vars are defined on entry and used on exit.  *)
  let compute_dd cfg = 
    let defs:(location) VH.t = VH.create 65535 in 
    let uses = VH.create 65535 in 
    let vars = ref VS.empty in 
    let update_def_uses s (loc:SSA.G.V.t * int) =
      let () = 
	match s with
	  | Ssa.Move (lv, _, _) -> VH.add defs lv loc
	  | _ -> ()
      in
      let stmt_uses = ref VS.empty in 
      let vis =  object(self)
	inherit Ssa_visitor.nop
	method visit_rvar v = stmt_uses := VS.add v !stmt_uses; `DoChildren
	method visit_value v = 
	  match v with
	      Ssa.Var(v') -> vars := VS.add v' !vars; `DoChildren
	    | _ -> `DoChildren
      end
      in
	ignore (Ssa_visitor.stmt_accept vis s);
	VS.iter (fun v -> 
		   let prev = try VH.find uses v with Not_found -> [] in 
		     VH.replace uses v (loc::prev)
		) !stmt_uses
    in
      SSA.G.iter_vertex 
	(fun v ->
	   ignore(List.fold_left 
		    (fun idx s -> update_def_uses s (v,idx); idx+1)
		    0 (SSA.get_stmts cfg v)
		 )
	) cfg;
      (!vars,defs,uses)

  let compute_ddg cfg = 
    let vars,defs,uses = compute_dd cfg in 
      (* the following 2 statements copy only the cfg verticies  *)
    let ddg = SSA.copy cfg in 
    let ddg = SSA.G.fold_edges 
	(fun src dst cfg' -> 
	    let s = SSA.find_vertex cfg' (SSA.G.V.label src) in 
	    let d = SSA.find_vertex cfg' (SSA.G.V.label dst) in 
	      SSA.remove_edge cfg' s d
	) cfg ddg
    in
    let entryv = SSA.find_vertex ddg BB_Entry in 
      (* fd and fu implement assumption all vars are defined on entry
	 and used on exit *)
    let fd v = try VH.find defs v with Not_found -> (entryv,0) in 
    let cfg_to_ddg_vertex ddg cfg_vertex : SSA.G.V.t = 
      let lbl = SSA.G.V.label cfg_vertex in 
	SSA.find_vertex ddg lbl
    in
      VH.fold
	(fun var uselst ddg -> 
	   let (cfg_dv,_) = fd var in 
	   let ddg_dv = cfg_to_ddg_vertex ddg cfg_dv in
	     List.fold_left 
	       (fun ddg (cfg_uv,_) -> 
		  SSA.add_edge ddg 
		    (cfg_to_ddg_vertex ddg cfg_uv) ddg_dv) ddg uselst 
	) uses ddg 


  (** convert a cfg whose nodes contain any number of SSA stmts, to a
      cfg whose nodes contain a single SSA stmt in the node stmt
      list. This will make subsequent graphs more precise as an edge
      corresponds to a def/use statement, instead of a def/use block.
  *)
  let stmtlist_to_single_stmt cfg = 
    let translate_block old_v g : SSA.G.t= 
      let v = (SSA.find_vertex g (SSA.G.V.label old_v)) in 
      match (SSA.get_stmts g v)  with
	  [] -> g
	| s::[] -> g (* the first element in the list gets the original
			block id. Thus, we need to do nothing. *)
	| s::ss -> 
	    let origsucclst = SSA.G.succ g v in 
	    let g' = List.fold_left 
	      (fun g' dst -> SSA.remove_edge g' v dst) g origsucclst 
	    in 
	    let v',g' = 
	      List.fold_left 
		(fun (pred,g') s ->
		   let g',v' = SSA.create_vertex g' [s] in 
		   let () = dprintf "Created vertex %s for %s"
		     (bbid_to_string (SSA.G.V.label v'))
		     (Pp.ssa_stmt_to_string s) in 
		   let g' = SSA.add_edge g' pred v' in 
		     (v',g')
		) (v,g') ss 
	    in
	    let g' = SSA.set_stmts g' v [s] in 
	      List.fold_left
		(fun g' dst -> SSA.add_edge g' v' dst) g'  origsucclst
    in
    let g = SSA.copy  cfg in 
      SSA.G.fold_vertex translate_block cfg g
end

  (* A DDG implementation for ASTs *)

type var = Var of Var.t | Novar | Gamma

type instance = var * Cfg.AST.G.V.t * int

module SS = Set.Make (struct
                       type t = AST.G.V.t * int
                       let compare = Pervasives.compare
                      end)

module DDG_AST = 
struct

  (** a location in the CFG program.  *)
  type location = Cfg.AST.G.V.t * int

  module Dbg = Debug.Make(struct let name = "DDG" and default=`NoDebug end)
  open Dbg
  module VH = Var.VarHash
  module VS = Var.VarSet
  module GS = Set.Make (struct 
                         type t = AST.G.V.t 
                         let compare = Pervasives.compare
                        end)
  module GE = Set.Make (struct 
                         type t = AST.G.V.t * AST.G.V.t
                         let compare = Pervasives.compare
                        end)


  (* Computing the definition and use sites of variables. *)
  let compute_dd cfg = 
    let defs:(location) VH.t = VH.create 65535 in 
    let uses = VH.create 65535 in 
    let vars = ref VS.empty in 
    let update_def_uses s (loc:AST.G.V.t * int) =
      let stmt_uses = ref VS.empty in 
      let vis = object(self)
	inherit Ast_visitor.nop
        method visit_avar v = VH.add defs v loc ; `DoChildren
	method visit_rvar v = stmt_uses := VS.add v !stmt_uses; `DoChildren
	method visit_exp v = 
	  match v with
	      Ast.Var(v') -> vars := VS.add v' !vars; `DoChildren
	    | _ -> `DoChildren
      end
      in
	ignore (Ast_visitor.stmt_accept vis s);
	VS.iter (fun v -> 
		   let prev = try VH.find uses v with Not_found -> [] in 
		     VH.replace uses v (loc::prev)
		) !stmt_uses
    in
      AST.G.iter_vertex 
	(fun v ->
	   ignore(List.fold_left 
		    (fun idx s -> update_def_uses s (v,idx); idx+1)
		    0 (AST.get_stmts cfg v)
		 )
	) cfg;
      (!vars,defs,uses)

  (* Computing the ddg and a hashtbl containing the data dependencies *)
  let compute_ddg_data cfg = 
    let vars,defs,uses = compute_dd cfg in 
      (* the following 2 statements copy only the cfg vertices  *)
    let ddg = AST.copy cfg in 
    let entryv = AST.find_vertex ddg BB_Entry in 
      (* fd and fu implement assumption all vars are defined on entry
	 and used on exit *)
    let fd v = (entryv,0) :: (try VH.find_all defs v with Not_found -> [])
    in 
    let cfg_to_ddg_vertex ddg cfg_vertex : AST.G.V.t = 
      let lbl = AST.G.V.label cfg_vertex in 
	AST.find_vertex ddg lbl
    in
    (* dropping all up to the nth list elements *)
    let rec drop n l = 
      match n,l with
        | 0,_::t -> t
        | _,[] -> []
        | n,_::t -> drop (n-1) t
    in
    let edges = ref GE.empty in
    (* The ud Hashtbl represents the relation describing all the data *
     * dependencies                                                   *)
    let ud = Hashtbl.create 5700 in
    
    let find_all_uses v info node ss =
      let visited = ref GS.empty in
      let rec find_uses var info node stmts lin = 
        let init,line = info in
        let stop = ref false in
        let id = ref lin in
        let vis = object(self)
  	  inherit Ast_visitor.nop
          method visit_avar v = 
            if v = var
            then (stop := true ; `SkipChildren)
            else `DoChildren
	  method visit_rvar v = 
            if v = var
            then (Hashtbl.add ud (Var var,node,!id) (Var var,init,line) ;
                  edges := GE.add (node,init) !edges ; 
                  `DoChildren
                  )
            else `DoChildren
        end
        in
        List.iter
          (fun stmt ->
            if not !stop then ignore (Ast_visitor.stmt_accept vis stmt) ;
            id := !id + 1
           ) stmts ;
        if !stop
        then ()
        else 
        (
          AST.G.iter_succ
            (fun succ -> 
              if not (GS.mem succ !visited)
              then (
                visited := GS.add succ !visited ;
                find_uses var info succ (AST.get_stmts ddg succ) 0
                   )
            ) ddg node
        )
      in
       find_uses v info node ss (snd info + 1)
    in
      (* For each variable definition find all the potential uses *)
      VS.iter
        (fun var ->
          let vdefs = fd var in
          List.iter 
            (fun (v,n) ->
                let stmts = drop n (AST.get_stmts ddg v) in
                find_all_uses var (v,n) v stmts
            ) vdefs
        ) vars ; 
      (* Remove all the pre-existing CFG edges from the DDG *)
      let ddg = AST.G.fold_edges 
	(fun src dst cfg' -> 
	    let s = AST.find_vertex cfg' (AST.G.V.label src) in 
	    let d = AST.find_vertex cfg' (AST.G.V.label dst) in 
	      AST.remove_edge cfg' s d
	) cfg ddg
      in
      (* Add the computed data dependencies to the DDG *)
      let ddg =
        GE.fold (fun (v1,v2) ddg' -> 
                  let v1' = cfg_to_ddg_vertex ddg v1 
                  and v2' = cfg_to_ddg_vertex ddg v2 in
                    AST.add_edge ddg' v1' v2'
                 ) !edges ddg
      in
      (ddg, ud)

  let compute_ddg cfg = fst (compute_ddg_data cfg)

  let compute_dds cfg h =
    Hashtbl.iter
      (fun (_,v1,n1) (_,v2,n2) ->
        Hashtbl.add h (v1,n1) (v2,n2) 
      ) (snd (compute_ddg_data cfg))

(*let slice ddg _src _trg = ddg*)

   end

(* A PDG implementation for ASTs *)

module PDG_AST = 
struct

  module Dbg = Debug.Make(struct let name = "PDG" and default=`NoDebug end)
  open Dbg

  let compute_pdg cfg =
    let cdg = CDG_AST.compute_cdg cfg in
    let ddg = DDG_AST.compute_ddg cfg in
    (* Constructing the PDG *)
    (* Getting the vertices *)
    let pdg = 
       AST.G.fold_vertex 
         (fun v g -> AST.add_vertex g v) 
         cfg (AST.empty()) 
    in
    (* Adding true/data dependence edges *)
    let pdg =
      AST.G.fold_edges
        (fun v1 v2 g ->
          let edge = AST.G.E.create v1 (Some true) v2 in
          AST.add_edge_e g edge
        ) ddg pdg
    in
    (* Adding false/control dependence edges *)
    let pdg =
      AST.G.fold_edges
        (fun v1 v2 g ->
          if AST.G.mem_edge g v1 v2
          then g 
          else let edge = AST.G.E.create v1 (Some false) v2 in
               AST.add_edge_e g edge
        ) cdg pdg
    in pdg
    
end

(* A module to perform chopping on ASTs *)

module CHOP_AST =
struct

 (* Test-printing of ASTs TODO:remove *)
 (* TODO: Create a new file only for chopping *)

  module TG =
  struct 
    type t = Cfg.AST.G.t
    module V = Cfg.AST.G.V
    let iter_vertex = Cfg.AST.G.iter_vertex
    let fold_vertex = Cfg.AST.G.fold_vertex
    let iter_succ = Cfg.AST.G.iter_succ
    let fold_succ = Cfg.AST.G.fold_succ
  end

 module Traverse = Graph.Traverse.Dfs(TG)

  let print_cfg cfg = 
   let print_stmts v =
    let stmts = AST.get_stmts cfg v in
    List.iter
     (fun s -> 
       Printf.printf "%s\n" (Pp.ast_stmt_to_string s)
     ) stmts
   in
   Traverse.prefix print_stmts cfg
    
(* Simple chopping implementation *)

module SG =
struct
 type t = Cfg.AST.G.t
 module V = Cfg.AST.G.V
 let iter_vertex = Cfg.AST.G.iter_vertex
 let iter_succ = Cfg.AST.G.iter_succ
end

module Comp = Graph.Components.Make(SG);;

(* Calculating the strongly connected component *)
 let get_scc cfg src trg = 
 (* Adding a temporary back-edge *)
  let (edgeadded,cfg) = 
   if AST.G.mem_edge cfg trg src then (false,cfg)
   else (true,AST.add_edge cfg trg src) in
   (* Keeping the strongly connected component *)
   let sccs = Comp.scc_list cfg in
   let scclist = List.find (List.mem src) sccs in
   if not (List.mem trg scclist) then failwith "sink node unreachable" ;
   let scc = 
    AST.G.fold_vertex 
     (fun v g -> 
       if not (List.mem v scclist) then AST.remove_vertex g v
       else g
     ) cfg cfg
   in
   (* Removing the back-edge *)
   if edgeadded then AST.remove_edge scc trg src else scc

 let compute_cds cfg h =
  let cdg = CDG_AST.compute_cdg cfg in
   Cfg.AST.G.iter_edges
    (fun v1 v2 ->
      let ss1 = AST.get_stmts cfg v1 in
      let ss2 = AST.get_stmts cfg v2 in
      let num = (List.length ss1) - 1 in
      ignore 
       (List.fold_left
        (fun id _ ->
          Hashtbl.add h (v2,id) (v1,num) ;
          id + 1
        ) 0 ss2
       )
    ) cdg

(* Adding jump stmts that are not directly control-dependent
 * on conditional jumps to get a more precise slice.
 * We use the conservative algorithm presented in Figure 13 of
 * 'On Slicing Programs with Jump Statements'
 * --> http://portal.acm.org/citation.cfm?id=178456            *)
 let add_jmp_stmts cfg dds =
  Cfg.AST.G.iter_edges
   (fun v1 v2 ->
     try
      let stmts1 = AST.get_stmts cfg v1 in
      match List.hd (List.rev stmts1) with
      | Ast.CJmp _ ->
        let num = List.length stmts1 - 1 in
        let stmts2 = AST.get_stmts cfg v2 in
        ignore
        (List.fold_left
         (fun id s ->
           match s with 
           | Ast.Jmp _ -> Hashtbl.add dds (v2,id) (v1,num) ; id + 1
           | _ -> id + 1
         ) 0 stmts2
        )
      | _ -> ()
     with Failure "hd" -> ()
   ) cfg

 let get_dds cfg =
  let dds = Hashtbl.create 5700 in
  DDG_AST.compute_dds cfg dds ;
  compute_cds cfg dds ;
  add_jmp_stmts cfg dds ;
  dds
  
  (* Slicing the cfg *)
  let slice cfg node stmt =
   let deps = get_dds cfg in
   let rec get_reachable visited wl =
    match wl with
    | [] -> 
      visited
    | x::worklist ->
      if SS.mem x visited then get_reachable visited worklist
      else 
       let next = Hashtbl.find_all deps x in
       get_reachable (SS.add x visited) (next@worklist)
   in
   let vis = get_reachable SS.empty [(node,stmt)] in
   let not_changable = function
    | Ast.Label _ | Ast.Comment _ -> true
    | _ -> false
   in
   let tmp = AST.G.fold_vertex
    (fun v g ->
      let _,newstmts = 
       List.fold_left
        (fun (id,acc) s -> 
         if not_changable s || SS.mem (v,id) vis then (id+1,s::acc)
         else (id+1,acc)
        ) (0,[]) (AST.get_stmts cfg v)
      in
      AST.set_stmts g v (List.rev newstmts)
    ) cfg cfg
   in
   print_cfg tmp ;
   tmp

  (* Performing chopping from a source to a sink *)
 let chop cfg srcbb _srcn trgbb trgn = 
  let get_v num = 
   try AST.find_vertex cfg (BB num)
   with Not_found -> 
    failwith "input does not correspond to basic blocks"
  in
  let src = get_v srcbb 
  and trg = get_v trgbb in
  let scc = get_scc cfg src trg in
 (* Adding entry and exit nodes *)
  let entry = AST.find_vertex cfg BB_Entry 
  and exit = AST.find_vertex cfg BB_Exit in
  let scc = AST.add_vertex scc entry in
  let scc = AST.add_vertex scc exit in
  let scc = AST.add_edge scc entry src in
  let scc = AST.add_edge scc trg exit in
  slice scc trg trgn
end

