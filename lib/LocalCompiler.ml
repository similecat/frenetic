(* metavariable conventions
   - a, b, c, actions
   - s, t, u, action sets
   - x, y, z, patterns
   - xs, ys, zs, pattern sets
   - p, q, local
   - r, atoms
   - g, groups

   - A = Action 
*)

open Core.Std
open Sexplib.Conv

(* utility function *)
let map_option f = function
  | None -> None
  | Some x -> Some (f x)

let collection_to_string fold f sep x : string = 
  fold 
    x
    ~init:""
    ~f:(fun acc e -> 
        f e ^ 
        if acc = "" then "" else sep ^ acc)

let header_val_map_to_string eq sep m =
  NetKAT_Types.HeaderMap.fold
    (fun h v acc ->
      Printf.sprintf "%s%s%s%s"
        (NetKAT_Pretty.header_to_string h)
        eq
        (NetKAT_Pretty.value_to_string v)
        (if acc = "" then "" else sep ^ acc))
    m ""

module Action : sig 
  type t = NetKAT_Types.header_val_map
  val to_string : t -> string
  module Set : Set.S with type Elt.t = t
  val set_to_string : Set.t -> string
  type group
  val group_compare : group -> group -> int
  val group_equal : group -> group -> bool
  val group_to_string : group -> string
  val mk_group : Set.t list -> group
  val group_crossproduct : group -> group -> group
  val group_union : group -> group -> group
  val group_fold : group -> init:'a -> f:('a -> Set.t -> 'a) -> 'a
  val group_map : group -> f:(Set.t -> 'a) -> 'a list
  val group_is_drop : group -> bool
  val id : Set.t
  val drop : Set.t
  val is_id : Set.t -> bool
  val is_drop : Set.t -> bool
  val seq_act : t -> t -> t
  val seq_acts : t -> Set.t -> Set.t
  val seq_group : t -> group -> group
  val to_netkat : t -> NetKAT_Types.policy
  val set_to_netkat : Set.t -> NetKAT_Types.policy
  val group_to_netkat : group -> NetKAT_Types.policy
end = struct
  type t = NetKAT_Types.header_val_map sexp_opaque with sexp 
      
  type this_t = t with sexp

  let this_compare = 
    NetKAT_Types.HeaderMap.compare Pervasives.compare      

  let to_string (a:t) : string =
    if NetKAT_Types.HeaderMap.is_empty a then 
      "id"
    else 
      header_val_map_to_string ":=" "; " a
    
  module Set = Set.Make(struct
    type t = this_t with sexp
    let compare = this_compare
  end)

  let set_to_string (s:Set.t) : string =
    Printf.sprintf "{%s}" 
      (collection_to_string 
         Set.fold 
         to_string 
         ", " 
         s)

  type group = Set.t list

  let group_compare (g1:group) (g2:group) : int = 
    List.compare g1 g2 ~cmp:Set.compare

  let group_equal (g1:group) (g2:group) : bool = 
    group_compare g1 g2 = 0
        
  let group_to_string (g:group) : string =    
    Printf.sprintf "[%s]"
      (collection_to_string
         List.fold_left
         set_to_string
         "; "
         g)

  let mk_group (g:Set.t list) : group =
    List.rev
      (List.fold g ~init:[]
	 ~f:(fun acc si ->
	   if List.exists acc ~f:(Set.equal si) then 
	     acc
	   else
	     si::acc))

  let group_crossproduct (g1:group) (g2:group) : group =
    let n1 = List.length g1 in 
    let n2 = List.length g2 in 
    if n1 >= n2 then 
      mk_group
        (List.rev
           (List.fold g1 ~init:[]
              ~f:(fun acc s1i ->
	        List.fold g2 ~init:acc
		  ~f:(fun acc s2j ->
                    Set.union s1i s2j::acc))))
    else 
      mk_group
        (List.fold g1 ~init:[]
           ~f:(fun acc s1i ->
	     List.fold g2 ~init:acc
	       ~f:(fun acc s2j ->
                 Set.union s1i s2j::acc)))

  let group_union (g1:group) (g2:group) : group =
    let r = mk_group (g1 @ g2) in 
    (* Printf.printf "GROUP_UNION\n%s\n%s\n%s\n\n"  *)
    (*   (group_to_string g1) (group_to_string g2) (group_to_string r); *)
    r

  let id : Set.t =
    Set.singleton (NetKAT_Types.HeaderMap.empty)

  let drop : Set.t =
    Set.empty

  let is_id (s:Set.t) : bool =
    Set.length s = 1 &&
    (NetKAT_Types.HeaderMap.is_empty (Set.choose_exn s))

  let is_drop (s:Set.t) : bool =
    Set.is_empty s

  let group_is_drop (g:group) : bool = 
    match g with 
      | [s] -> is_drop s
      | _ -> false

  let group_fold g = List.fold g

  let group_map g = List.map g

  let seq_act (a1:t) (a2:t) : t =
    let f h vo1 vo2 = match vo1, vo2 with
      | (_, Some v2) ->
        Some v2
      | _ ->
        vo1 in
    NetKAT_Types.HeaderMap.merge f a1 a2

  let seq_acts (a:t) (s:Set.t) : Set.t =
    Set.map s (seq_act a) 

  let seq_group (a:t) (g:group) : group =
    List.rev
      (List.fold g ~init:[]
         ~f:(fun acc si -> seq_acts a si::acc))

  let to_netkat (a:t) : NetKAT_Types.policy =
    if NetKAT_Types.HeaderMap.is_empty a then 
      NetKAT_Types.Filter NetKAT_Types.True
    else 
      let h_port = NetKAT_Types.Header SDN_Types.InPort in 
      let f h v pol' = 
	if h = h_port then 
	  NetKAT_Types.Seq (pol', NetKAT_Types.Mod (h, v)) 
	else 
	  NetKAT_Types.Seq (NetKAT_Types.Mod (h, v), pol') in
      let (h, v) = NetKAT_Types.HeaderMap.min_binding a in
      let a' = NetKAT_Types.HeaderMap.remove h a in
      NetKAT_Types.HeaderMap.fold f a' (NetKAT_Types.Mod (h, v))
	
  let set_to_netkat (s:Set.t) : NetKAT_Types.policy =
    if Set.is_empty s then
      NetKAT_Types.Filter NetKAT_Types.False
    else
      let f pol' a = NetKAT_Types.Par (pol', to_netkat a) in
      let a = Set.min_elt_exn s in
      let s' = Set.remove s a in
      Set.fold s' ~f:f ~init:(to_netkat a)

  let group_to_netkat (g:group) : NetKAT_Types.policy =
    match g with
      | [] ->
        NetKAT_Types.Filter NetKAT_Types.False
      | [s] ->
        set_to_netkat s
      | s::g' ->
        let f pol' s = NetKAT_Types.Choice (pol', set_to_netkat s) in
        List.fold g' ~init:(set_to_netkat s) ~f:f
end

module Pattern = struct
  exception Empty_pat

  type t = (SDN_Types.field * VInt.t) list sexp_opaque with sexp

  type this_t = t sexp_opaque with sexp

  let compare_field_val (f1,v1) (f2,v2) = 
    let cmp1 = compare f1 f2 in 
    if cmp1 <> 0 then cmp1
    else compare v1 v2 

  let compare x y = List.compare x y ~cmp:compare_field_val

  module Set = Set.Make(struct
    type t = this_t sexp_opaque with sexp
    let compare = compare
  end)

  let to_string (x:t) : string =
    match x with 
      | [] -> "true"
      | _ -> 
        List.fold x ~init:""
          ~f:(fun acc (f, v) ->
            Printf.sprintf "%s%s=%s"
              (if acc = "" then "" else ", " ^ acc)
              (NetKAT_Pretty.string_of_field f)
              (NetKAT_Pretty.value_to_string v))
        
  let set_to_string (xs:Set.t) : string =
    Printf.sprintf "{%s}"
      (Set.fold xs ~init:""
         ~f:(fun acc x -> (if acc = "" then "" else acc ^ ", ") ^ to_string x))

  let tru : t = []

  let is_tru (x:t) : bool = x = []
      
  let rec subseteq_pat (x:t) (y:t) : bool = 
    match x,y with 
      | _,[] -> true
      | [],_::_ -> false
      | (f1,v1)::x1, (f2,v2)::y2 -> 
        let n = Pervasives.compare f1 f2 in  
        if n = 0 then 
          v1 = v2 && subseteq_pat x1 y2
        else if n < 0 then 
          subseteq_pat x1 y
        else (* n > 0 *)
          false
	
  let rec seq_pat (x : t) (y : t) : t option =
    let rec loop x y k = 
      match x,y with 
        | _,[] -> 
          k (Some x)
        | [],_ -> 
          k (Some y)
        | (f1,v1)::x1, (f2,v2)::y2 -> 
          let n = Pervasives.compare f1 f2 in  
          if n = 0 then 
            if v1 = v2 then
              loop x1 y2 (fun o -> k (map_option (fun l -> (f1,v1)::l) o))
            else 
              k None
          else if n < 0 then 
            loop x1 y (fun o -> k (map_option (fun l -> (f1,v1)::l) o))
          else (* n > 0 *)
            loop x y2 (fun o -> k (map_option (fun l -> (f2,v2)::l) o)) in 
    let r = loop x y (fun x -> x) in 
    (* Printf.printf "SEQ_PAT\nX=%s\nY=%s\nR=%s\n\n" *)
    (*   (to_string x) *)
    (*   (to_string y) *)
    (*   (match r with | None -> "None" | Some r -> to_string r); *)
    r

  let rec seq_act_pat (x:t) (a:Action.t) (y:t) : t option =
    let rec loop x y k = 
      match x,y with 
        | _,[] -> 
          k (Some x)
        | [],(f2,v2)::y2 -> 
          begin try 
            let va = NetKAT_Types.HeaderMap.find (NetKAT_Types.Header f2) a in 
            if va = v2 then 
              loop x y2 k
            else
              k None
          with Not_found -> 
            loop x y2 (fun o -> k (map_option (fun l -> (f2,v2)::l) o))
          end
        | (f1,v1)::x1,(f2,v2)::y2 -> 
          let n = Pervasives.compare f1 f2 in  
          if n = 0 then 
            try 
              let va = NetKAT_Types.HeaderMap.find (NetKAT_Types.Header f1) a in 
              if va = v2 then 
                loop x1 y2 (fun o -> k (map_option (fun l -> (f1,v1)::l) o))
              else
                k None
            with Not_found -> 
              if v1 = v2 then 
                loop x1 y2 (fun o -> k (map_option (fun l -> (f1,v1)::l) o))
              else 
                k None
          else if n < 0 then 
            loop x1 y (fun o -> k (map_option (fun l -> (f1,v1)::l) o))
          else (* n > 0 *)
            loop x y2 (fun o -> k (map_option (fun l -> (f2,v2)::l) o)) in 
    let r = loop x y (fun x -> x) in 
    (* Printf.printf "SEQ_ACT_PAT\nX=%s\nA=%s\nY=%s\nR=%s\n\n" *)
    (*   (to_string x) *)
    (*   (Action.to_string a) *)
    (*   (to_string y) *)
    (*   (match r with | None -> "None" | Some r -> to_string r); *)
    r

  let to_netkat (x:t) : NetKAT_Types.pred =
    let rec loop x k = 
      match x with 
        | [] -> 
          k NetKAT_Types.True
        | [(f,v)] -> 
          k (NetKAT_Types.Test (NetKAT_Types.Header f,v))
        | (f,v)::x1 -> 
          loop x1 (fun pr -> NetKAT_Types.And(NetKAT_Types.Test(NetKAT_Types.Header f,v),pr)) in 
    loop x (fun x -> x)

  let set_to_netkat (xs:Set.t) : NetKAT_Types.pred =
    match Set.choose xs with 
      | None -> 
        NetKAT_Types.False
      | Some x -> 
        let xs' = Set.remove xs x in
        let f pol x = NetKAT_Types.Or(pol, to_netkat x) in
        Set.fold xs' ~init:(to_netkat x) ~f:f
end

module Atom = struct
  exception Empty_atom

  type t = Pattern.Set.t * Pattern.t with sexp

  type this_t = t with sexp

  let to_string ((xs,x):t) : string =
    Printf.sprintf "%s,%s"
      (Pattern.set_to_string xs) (Pattern.to_string x)

  let shadows (xs1,x1) (xs2,x2) = 
    let ys = 
      Pattern.Set.fold xs1 ~init:Pattern.Set.empty 
        ~f:(fun acc xi -> 
          match Pattern.seq_pat x1 xi with
            | None -> acc
            | Some x1_xi -> Pattern.Set.add acc x1_xi) in 
    Pattern.Set.mem ys x2

  let compare ((xs1,x1) as r1) ((xs2,x2) as r2) = 
    let r = 
      if shadows r2 r1 then 
        -1
      else if shadows r1 r2 then 
        1
      else 
        let cmp = Pattern.Set.compare xs1 xs2 in 
        if cmp = 0 then 
          Pattern.compare x1 x2 
        else 
          cmp in 
    (* Printf.printf "COMPARE %s %s = %d\n%!" (to_string (xs1,x1)) (to_string (xs2,x2)) r; *)
    r

  let subseteq (r1:t) (r2:t) = 
    let (xs1,x1) = r1 in 
    let (xs2,x2) = r2 in 
    Pattern.subseteq_pat x1 x2 &&
    Pattern.Set.for_all xs2 ~f:(fun x2j -> 
      Pattern.Set.exists xs1 ~f:(fun x1i -> 
        Pattern.subseteq_pat x2j x1i))

  module Set = Set.Make (struct
    type t = this_t with sexp

    let compare = compare
  end)

  module Map = Map.Make (struct
    type t = this_t with sexp

    let compare = compare
  end)

  let to_string ((xs,x):t) : string =
    Printf.sprintf "%s,%s"
      (Pattern.set_to_string xs) (Pattern.to_string x)

  let set_to_string (rs:Set.t) : string =
    Printf.sprintf "{%s}"
      (Set.fold rs ~init:""
         ~f:(fun acc ri -> (if acc = "" then acc else acc ^ ", ") ^ to_string ri))

  let tru : t =
    (Pattern.Set.empty, Pattern.tru)

  let fls : t =
    (Pattern.Set.singleton Pattern.tru, Pattern.tru)

    (* "smart" constructor *)
  let mk ((xs,x):t) : t option =
    (* TODO(jnf): replace this *)
    try
      let xs' =
	Pattern.Set.fold xs 
          ~init:Pattern.Set.empty
	  ~f:(fun acc xi ->
	    if Pattern.subseteq_pat x xi then 
	      raise Empty_atom
	    else if 
		Pattern.Set.exists xs
		  ~f:(fun xj -> 
                    Pattern.compare xi xj <> 0 &&
		      Pattern.subseteq_pat xi xj) 
	    then 
	      acc
	    else
	      Pattern.Set.add acc xi) in 
      Some (xs',x)
    with Empty_atom ->
      None

  let seq_atom ((xs1,x1):t) ((xs2,x2):t) : t option =
    match Pattern.seq_pat x1 x2 with
      | Some x12 ->
        mk (Pattern.Set.union xs1 xs2, x12)
      | None ->
        None

  let seq_act_atom ((xs1,x1):t) (a:Action.t) ((xs2,x2):t) : t option =
    let r = match Pattern.seq_act_pat x1 a x2 with
      | Some x1ax2 ->
        let xs =
          Pattern.Set.fold xs2 
            ~init:xs1
            ~f:(fun acc xs2i ->
              match Pattern.seq_act_pat Pattern.tru a xs2i with
                | Some truaxs2i ->
                  Pattern.Set.add acc truaxs2i
                | None ->
                  acc) in 
        mk (xs, x1ax2)  
      | None ->
        None in 
    (* Printf.printf "SEQ_ACT_ATOM\nR1=%s\nR2=%s\nR=%s\n\n" *)
    (*   (to_string (xs1,x1)) *)
    (*   (to_string (xs2,x2)) *)
    (*   (match r with | None -> "None" | Some r -> to_string r); *)
    r

  let diff_atom ((xs1,x1):t) ((xs2,x2):t) : Set.t =
    let acc0 =
      match mk (Pattern.Set.add xs1 x2, x1) with
        | None ->
	  Set.empty
        | Some r ->
	  Set.singleton r in
    Pattern.Set.fold xs2 ~init:acc0
      ~f:(fun acc x2i ->
        match Pattern.seq_pat x1 x2i with
	  | None ->
	    acc
	  | Some x12i ->
            begin match mk (xs1, x12i) with
              | None ->
		acc
              | Some ri ->
		Set.add acc ri
	    end)
end

module Optimize = struct
  let mk_and pr1 pr2 = 
    match pr1, pr2 with 
      | NetKAT_Types.True, _ -> pr2
      | _, NetKAT_Types.True -> pr1
      | NetKAT_Types.False, _ -> NetKAT_Types.False
      | _, NetKAT_Types.False -> NetKAT_Types.False
      | _ -> NetKAT_Types.And(pr1, pr2)

  let mk_or pr1 pr2 = 
    match pr1, pr2 with 
      | NetKAT_Types.True, _ -> NetKAT_Types.True
      | _, NetKAT_Types.True -> NetKAT_Types.True
      | NetKAT_Types.False, _ -> pr2
      | _, NetKAT_Types.False -> pr2
      | _ -> NetKAT_Types.Or(pr1, pr2)

  let mk_not pat =
    match pat with
      | NetKAT_Types.False -> NetKAT_Types.True
      | NetKAT_Types.True -> NetKAT_Types.False
      | _ -> NetKAT_Types.Neg(pat) 

  let mk_par pol1 pol2 = 
    match pol1, pol2 with
      | NetKAT_Types.Filter NetKAT_Types.False, _ -> pol2
      | _, NetKAT_Types.Filter NetKAT_Types.False -> pol1
      | _ -> NetKAT_Types.Par(pol1,pol2) 

  let mk_seq pol1 pol2 =
    match pol1, pol2 with
      | NetKAT_Types.Filter NetKAT_Types.True, _ -> pol2
      | _, NetKAT_Types.Filter NetKAT_Types.True -> pol1
      | NetKAT_Types.Filter NetKAT_Types.False, _ -> pol1
      | _, NetKAT_Types.Filter NetKAT_Types.False -> pol2
      | _ -> NetKAT_Types.Seq(pol1,pol2) 

  let mk_choice pol1 pol2 =
    match pol1, pol2 with
      | _ -> NetKAT_Types.Choice(pol1,pol2) 

  let mk_star pol = 
    match pol with 
      | NetKAT_Types.Filter NetKAT_Types.True -> pol
      | NetKAT_Types.Filter NetKAT_Types.False -> NetKAT_Types.Filter NetKAT_Types.True
      | NetKAT_Types.Star(pol1) -> pol
      | _ -> NetKAT_Types.Star(pol)
  
  let specialize_pred sw pr = 
    let rec loop pr k = 
      match pr with
        | NetKAT_Types.True ->
          k pr
        | NetKAT_Types.False ->
          k pr
        | NetKAT_Types.Neg pr1 ->
          loop pr1 (fun pr -> k (mk_not pr))
        | NetKAT_Types.Test (NetKAT_Types.Switch, v) ->
          if v = sw then 
            k NetKAT_Types.True
          else
            k NetKAT_Types.False
        | NetKAT_Types.Test (h, v) ->
          k pr
        | NetKAT_Types.And (pr1, pr2) ->
          loop pr1 (fun p1 -> loop pr2 (fun p2 -> k (mk_and p1 p2)))
        | NetKAT_Types.Or (pr1, pr2) ->
          loop pr1 (fun p1 -> loop pr2 (fun p2 -> k (mk_or p1 p2))) in 
    loop pr (fun x -> x)

  let specialize_pol sw pol = 
    let rec loop pol k = 
      match pol with  
        | NetKAT_Types.Filter pr ->
          k (NetKAT_Types.Filter (specialize_pred sw pr))
        | NetKAT_Types.Mod (h, v) ->
          k pol 
        | NetKAT_Types.Par (pol1, pol2) ->
          loop pol1 (fun p1 -> loop pol2 (fun p2 -> k (mk_par p1 p2)))
        | NetKAT_Types.Choice (pol1, pol2) ->
          loop pol1 (fun p1 -> loop pol2 (fun p2 -> k (mk_choice p1 p2)))
        | NetKAT_Types.Seq (pol1, pol2) ->
          loop pol1 (fun p1 -> loop pol2 (fun p2 -> k (mk_seq p1 p2)))
        | NetKAT_Types.Star pol ->
          loop pol (fun p -> k (mk_star p))
        | NetKAT_Types.Link(sw,pt,sw',pt') ->
	  failwith "Not a local policy" in 
    loop pol (fun x -> x) 
end

module Local = struct
  type t = Action.group Atom.Map.t

  let to_string (p:t) : string =
    Atom.Map.fold p ~init:""
      ~f:(fun ~key:r ~data:g acc ->
        Printf.sprintf "%s(%s) => %s\n"
          (if acc = "" then "" else "" ^ acc)
          (Atom.to_string r) (Action.group_to_string g))

  let extend (r:Atom.t) (g:Action.group) (p:t) : t =
    if Action.group_is_drop g then 
      p 
    else 
      match Atom.mk r with 
        | None -> 
	  p
        | Some (xs,x) ->
	  if Atom.Map.mem p r then
            let msg = Printf.sprintf "Local.extend: overlap on atom %s" (Atom.to_string r) in 
            failwith msg
          else
            Atom.Map.add p r g

  let intersect (op:Action.group -> Action.group -> Action.group) (p:t) (q:t) : t =
    if Atom.Map.is_empty p || Atom.Map.is_empty q then
      Atom.Map.empty
    else
      Atom.Map.fold p ~init:Atom.Map.empty
        ~f:(fun ~key:r1 ~data:g1 acc ->
          Atom.Map.fold q ~init:acc 
            ~f:(fun ~key:r2 ~data:g2 acc ->
              match Atom.seq_atom r1 r2 with
                | None ->
                  acc
                | Some r1_seq_r2 ->
                  extend r1_seq_r2 (op g1 g2) acc))  

  let difference (p:t) (q:t) : t =
    if Atom.Map.is_empty q then
      p
    else
      Atom.Map.fold p ~init:Atom.Map.empty
        ~f:(fun ~key:r1 ~data:g1 acc ->
          let rs =
            Atom.Map.fold q ~init:(Atom.Set.singleton r1)
              ~f:(fun ~key:r2 ~data:_ rs ->
                Atom.Set.fold rs ~init:Atom.Set.empty
                  ~f:(fun acc r1i -> Atom.Set.union (Atom.diff_atom r1i r2) acc)) in
          Atom.Set.fold rs ~init:acc ~f:(fun acc r1i -> extend r1i g1 acc)) 

  let rec bin_local (op:Action.group -> Action.group -> Action.group) (p:t) (q:t) : t =
    if Atom.Map.is_empty p then 
      q
    else if Atom.Map.is_empty q then 
      p 
    else 
      let p_inter_q = intersect op p q in
      let p_only = difference p p_inter_q in
      let q_only = difference q p_inter_q in
      let f ~key:r v = 
        match v with 
          | `Left v1 -> Some v1
          | `Right v2 -> Some v2
          | `Both (v1,v2) -> 
            failwith (Printf.sprintf "Local.bin_local: overlap on %s in bin_local" (Atom.to_string r)) in 
      let r = Atom.Map.merge ~f:f p_inter_q (Atom.Map.merge ~f:f p_only q_only) in 
      r  

  let par_local (p:t) (q:t) : t =
    (* Printf.printf "### PAR [%d %d] ###\n%!" (Atom.Map.length p) (Atom.Map.length q); *)
    let r = bin_local Action.group_crossproduct p q in
      (* Printf.printf *)
      (* 	"PAR_LOCAL\n%s\n%s\n%s\n\n%!" *)
      (* 	(to_string p) (to_string q) (to_string r); *)
    r  

  let choice_local (p:t) (q:t) : t =
    (* Printf.printf "### CHOICE [%d %d] ###\n%!" (Atom.Map.length p) (Atom.Map.length q); *)
    let r = bin_local Action.group_union p q in
      (* Printf.printf *)
      (* 	"CHOICE_LOCAL\n%s\n%s\n%s\n\n%!" *)
      (* 	(to_string p) (to_string q) (to_string r); *)
    r

  let cross_merge ~key:_ v =
    match v with 
      | `Left g1 -> Some g1
      | `Right g2 -> Some g2
      | `Both (g1,g2) -> Some (Action.group_crossproduct g1 g2)

  let union_merge ~key:_ v = 
    match v with 
      | `Left g1 -> Some g1
      | `Right g2 -> Some g2
      | `Both (g1,g2) -> Some (Action.group_union g1 g2)
      
  let seq_atom_acts_local (r1:Atom.t) (s1:Action.Set.t) (q:t) : t =
    let seq_act (a:Action.t) : t =
      Atom.Map.fold q ~init:Atom.Map.empty
        ~f:(fun ~key:r2 ~data:g2 acc ->
          match Atom.seq_act_atom r1 a r2 with
            | None ->
              acc
            | Some r12 ->
              extend r12 (Action.seq_group a g2) acc) in 
    Action.Set.fold
      s1 
      ~f:(fun acc a -> Atom.Map.merge ~f:cross_merge acc (seq_act a))
      ~init:Atom.Map.empty
	  
  let seq_local (p:t) (q:t) : t =
    (* Printf.printf "### SEQ [%d %d] ###\n%!" (Atom.Map.length p) (Atom.Map.length q); *)
    let r =
      Atom.Map.fold p ~init:Atom.Map.empty
        ~f:(fun ~key:r1 ~data:g1 acc ->
	  Action.group_fold g1 ~init:acc
            ~f:(fun acc si -> 
	      Atom.Map.merge ~f:union_merge acc (seq_atom_acts_local r1 si q))) in 
      (* Printf.printf *)
      (* 	"SEQ_LOCAL\n%s\n%s\n%s\n\n%!" *)
      (* 	(to_string p) (to_string q) (to_string r); *)
    r

  (* precondition: t is a predicate *)
  let negate (p:t) : t =
    let rs = 
      Atom.Map.fold p ~init:(Atom.Set.singleton Atom.tru)
        ~f:(fun ~key:r ~data:g acc ->
	  Atom.Set.fold acc ~init:Atom.Set.empty
	    ~f:(fun acc ri -> Atom.Set.union (Atom.diff_atom ri r) acc)) in 
    Atom.Set.fold rs ~init:Atom.Map.empty
      ~f:(fun acc ri -> extend ri (Action.mk_group [Action.id]) acc) 

  let rec of_pred (sw:SDN_Types.fieldVal) (pr:NetKAT_Types.pred) : t =
    let rec loop pr k = 
      match pr with
      | NetKAT_Types.True ->
        k (Atom.Map.singleton Atom.tru (Action.mk_group [Action.id]))
      | NetKAT_Types.False ->
        k (Atom.Map.empty)
      | NetKAT_Types.Neg pr ->
        loop pr (fun (p:t) -> k (negate p))
      | NetKAT_Types.Test (NetKAT_Types.Switch, v) ->
        if v = sw then 
          loop NetKAT_Types.True k
        else
          loop NetKAT_Types.False k
      | NetKAT_Types.Test (NetKAT_Types.Header f, v) ->
        let p = [(f,v)] in 
        k (Atom.Map.singleton (Pattern.Set.empty, p) (Action.mk_group [Action.id]))
      | NetKAT_Types.And (pr1, pr2) ->
        loop pr1 (fun p1 -> loop pr2 (fun p2 -> k (seq_local p1 p2)))
      | NetKAT_Types.Or (pr1, pr2) ->
        loop pr1 (fun p1 -> loop pr2 (fun p2 -> k (par_local p1 p2))) in 
    loop pr (fun x -> x)

  let star_local (p:t) : t =
    (* Printf.printf "### STAR [%d] ###\n%!" (Atom.Map.cardinal p); *)
    let rec loop acc pi =
      (* Printf.printf "### STAR LOOP ###\n%!"; *)
      let psucci = seq_local p pi in
      let acc' = par_local acc psucci in
      if Atom.Map.compare Action.group_compare acc acc' = 0 then
        acc
      else
        loop acc' psucci in
    let p0 = Atom.Map.singleton Atom.tru (Action.mk_group [Action.id]) in
    let r = loop p0 p0 in 
    (* Printf.printf *)
    (*   "STAR_LOCAL\n%s\n%s\n\n%!" *)
    (*   	(to_string p) (to_string r); *)
    r


  let of_policy (sw:SDN_Types.fieldVal) (pol:NetKAT_Types.policy) : t =
    let rec loop pol k =  
      match pol with
        | NetKAT_Types.Filter pr ->
          k (of_pred sw pr)
        | NetKAT_Types.Mod (h, v) ->
          k (Atom.Map.singleton Atom.tru 
               (Action.mk_group [Action.Set.singleton (NetKAT_Types.HeaderMap.singleton h v)]))
        | NetKAT_Types.Par (pol1, pol2) ->
          loop pol1 (fun p1 -> loop pol2 (fun p2 -> k (par_local p1 p2)))
        | NetKAT_Types.Choice (pol1, pol2) ->
          loop pol1 (fun p1 -> loop pol2 (fun p2 -> k (choice_local p1 p2)))
        | NetKAT_Types.Seq (pol1, pol2) ->
          loop pol1 (fun p1 -> loop pol2 (fun p2 -> k (seq_local p1 p2)))
        | NetKAT_Types.Star pol ->
          loop pol (fun p -> k (star_local p))
        | NetKAT_Types.Link(sw,pt,sw',pt') ->
	  failwith "Not a local policy" in 
    loop pol (fun x -> 
      (* Printf.printf "### DONE ###\n%!";  *)
      x)

  let to_netkat (p:t) : NetKAT_Types.policy =
    let open Optimize in 
    let rec loop p =
      match Atom.Map.min_elt p with 
        | None -> 
          NetKAT_Types.Filter NetKAT_Types.False
        | Some (r,g) -> 
          let p' = Atom.Map.remove p r in
          let _ = assert (not (Atom.Map.equal Action.group_equal p p')) in 
          let (xs,x) = r in
          let nc_pred = mk_and (mk_not (Pattern.set_to_netkat xs)) (Pattern.to_netkat x) in
          let nc_pred_acts = mk_seq (NetKAT_Types.Filter nc_pred) (Action.group_to_netkat g) in
          mk_par nc_pred_acts  (loop p') in
    loop p
end

module RunTime = struct

  let to_action (a:Action.t) (pto: VInt.t option) : SDN_Types.seq =
    let port = 
      try 
        NetKAT_Types.HeaderMap.find (NetKAT_Types.Header SDN_Types.InPort) a 
      with Not_found -> 
        begin match pto with 
          | Some pt -> pt
          | None -> raise (Invalid_argument "Action.to_action: indeterminate port")
        end in 
    let mods = NetKAT_Types.HeaderMap.remove (NetKAT_Types.Header SDN_Types.InPort) a in
    let mk_mod h v act =
      match h with
        | NetKAT_Types.Switch -> 
	  raise (Invalid_argument "Action.to_action: got switch update")
        | NetKAT_Types.Header h' -> 
	  (SDN_Types.SetField (h', v)) :: act in
      NetKAT_Types.HeaderMap.fold mk_mod mods [SDN_Types.OutputPort port]  

  let set_to_action (s:Action.Set.t) (pto : VInt.t option) : SDN_Types.par =
    let f par a = (to_action a pto)::par in
    Action.Set.fold s ~f:f ~init:[]

  let group_to_action (g:Action.group) (pto:VInt.t option) : SDN_Types.group =
    Action.group_map g ~f:(fun s -> set_to_action s pto) 

  let to_pattern (x:Pattern.t) : SDN_Types.pattern =
    List.fold x ~init:SDN_Types.FieldMap.empty
      ~f:(fun acc (f,v) -> SDN_Types.FieldMap.add f v acc)
      
  type i = Local.t

  let compile (sw:SDN_Types.fieldVal) (pol:NetKAT_Types.policy) : i =
    let pol' = Optimize.specialize_pol sw pol in 
    let n,n' = Semantics.size pol, Semantics.size pol' in 
    Printf.printf "Compression: %d -> %d = %.3f" 
      n n' (Float.of_int n' /. Float.of_int n);
    (* Printf.printf "POLICY: %s" (NetKAT_Pretty.string_of_policy pol'); *)
    let r = Local.of_policy sw pol' in 
    (* Printf.printf "COMPILE\n%s\n%s\n%!" *)
    (*   (NetKAT_Pretty.string_of_policy pol) *)
    (*   (Local.to_string r); *)
    r

  let decompile (p:i) : NetKAT_Types.policy =
    Local.to_netkat p

  let simpl_flow (p : SDN_Types.pattern) (a : SDN_Types.group) : SDN_Types.flow = {
    SDN_Types.pattern = p;
    SDN_Types.action = a;
    SDN_Types.cookie = 0L;
    SDN_Types.idle_timeout = SDN_Types.Permanent;
    SDN_Types.hard_timeout = SDN_Types.Permanent
  }

  (* Prunes out rules that apply to other switches. *)
  let to_table (p:i) : SDN_Types.flowTable =
    let add_flow x g l =
      let pto = 
        try 
          Some (List.Assoc.find_exn x SDN_Types.InPort)
        with Not_found -> 
          None in 
      simpl_flow (to_pattern x) (group_to_action g pto) :: l in
    let rec loop (p:i) acc cover =
      match Atom.Map.min_elt p with 
        | None -> 
          acc 
        | Some (r,g) -> 
          (* let _ = Printf.printf "R => G\n   %s => %s\n" (Atom.to_string r) (Action.group_to_string g) in *)
          let (xs,x) = r in
          (* assert (not (Pattern.Set.mem cover x)); *)
          let p' = Atom.Map.remove p r in
          let ys = Pattern.Set.fold
            xs ~init:Pattern.Set.empty
            ~f:(fun acc xi -> 
              match Pattern.seq_pat xi x with 
              | None -> acc
              | Some xi_x -> Pattern.Set.add acc xi_x) in 
        let zs = 
          Pattern.Set.fold ys ~init:Pattern.Set.empty
            ~f:(fun acc yi -> 
              if Pattern.Set.exists cover ~f:(Pattern.subseteq_pat yi) then 
                acc
              else
                Pattern.Set.add acc yi) in 
        let acc' = Pattern.Set.fold zs ~init:acc ~f:(fun acc x -> add_flow x (Action.mk_group [Action.drop]) acc) in
        let acc'' = add_flow x g acc' in
        let cover' = Pattern.Set.add (Pattern.Set.union zs cover) x in
        (* assert (not (Atom.Map.equal Action.group_equal p p')); *)
        loop p' acc'' cover' in
    List.rev (loop p [] Pattern.Set.empty)
end

(* exports *)
type t = RunTime.i

let of_policy = Local.of_policy
let to_netkat = Local.to_netkat
let compile = RunTime.compile
let decompile = RunTime.decompile
let to_table = RunTime.to_table
