(** the control flow automaton module *)
module Make(Domain: Domain.T) =
    struct			
	  (** Abstract data type of nodes of the CFA *)
	  module State =
	    struct

	  (** data type for the decoding context *)
	  type ctx_t = {
	      addr_sz: int; (** size in bits of the addresses *)
	      op_sz  : int; (** size in bits of operands *)
	    }
	   
	  (** abstract data type of a state *)
	  type t = {
	      id: int; 	     		    (** unique identificator of the state *)
	      mutable ip: Data.Address.t;   (** instruction pointer *)
	      mutable v: Domain.t; 	    (** abstract value *)
	      mutable ctx: ctx_t ; 	    (** context of decoding *)
	      mutable stmts: Asm.stmt list; (** list of statements thas has lead to this state *)
	      internal: bool 	     	    (** whenever this node has been added for technical reasons and not because it is a real basic blocks *)
	    }
				   
	  (** the state identificator counter *)
	  let state_cpt = ref 0
			      
	  (** returns a fresh state identificator *)
	  let new_state_id () = state_cpt := !state_cpt + 1; !state_cpt
							      
	  (** state equality returns true whenever they are the physically the same (do not compare the content) *)
	  let equal s1 s2   = s1.id = s2.id
					
	  (** state comparison: returns 0 whenever they are the physically the same (do not compare the content) *)
	  let compare s1 s2 = s1.id - s2.id
	  (** otherwise return a negative integer if the first state has been created before the second one; *)
	  (** a positive integer if it has been created later *)
					
	  (** hashes a state *)
	  let hash b 	= b.id
	    
	end
	  
      (** Abstract data type of edge labels *)
      module Label = 
	struct

	  (** None means no label ; true is used for a if-branch link between states ; false for a else-branch link between states *)
	  type t = Asm.bexp option
			
	  let default = None
			  
	  let compare l1 l2 = 
	    match l1, l2 with
	      None, None 	   -> 0
	    | None, _ 	   	   -> -1
	    | Some b1, Some b2 	   -> compare b1 b2
	    | Some _, None 	   -> 1
					
	end
      (** *)    
	  
      module G = Graph.Imperative.Digraph.ConcreteBidirectionalLabeled(State)(Label)
      open State 
	     
      (** type of a CFA *)
      type t = G.t

      (* utilities for memory and register initialization with respect to the provided configuration *)
      (***********************************************************************************************)
		 
      (* returns the extension of the string b with '0' so that the returned string is of length sz *)
      (* length of b is supposed to be <= sz *)
      (* it is used both for initializing successive memory locations (values and taint) and the taint of registers *)
      let pad b sz =
	let n = String.length b in
	if n = sz then b
	else
	  begin
	    let s = String.make sz '0' in
	    let o = sz - n  in
	    for i = 0 to n-1 do
	      Bytes.set s (i+o) (String.get b i)
	    done;
	    s
	  end
		     
      (* return the given domain updated by the initial values and intitial tainting for registers with respected ti the provided configuration *)
      let init_registers d =
	let check b sz name =
	  if (String.length (Bits.z_to_bit_string b)) > sz then
	       Log.error (Printf.sprintf "Illegal initialisation for register %s" name)
	in
	let check_mask b m sz name =
	 if (String.length (Bits.z_to_bit_string b)) > sz || (String.length (Bits.z_to_bit_string m)) > sz then
	   Log.error (Printf.sprintf "Illegal initialization for register %s" name)
	  in
	(* this function adds leading zero to the tainting value v so that the new value v' has the same length as the register v *)
	let check_tainting_register v r =
	  let sz   = Register.size r in
	  let name = Register.name r in
	  begin
	    match v with
	    | Config.Taint b      -> check b sz name			   
	    | Config.TMask (b, m) -> check_mask b m sz name
	  end;
	  v
	in
	(* checks whether the provided value is compatible with the capacity of the parameter of type Register _r_ and the size of words *)
	let check_init_size r v =
	  let sz   = Register.size r in
	  let name = Register.name r in
	  begin
	  match v with
	  | Config.Content c    -> check c sz name
	  | Config.CMask (b, m) -> check_mask b m sz name
	  end;
	  v
	in
	(* first the domain is updated with the tainting value for each register with initial tainting in the provided configuration *)
	let d' =  Hashtbl.fold
		    (fun r v d -> Domain.taint_register_from_config r Data.Address.Global (check_tainting_register v r) d
		    )
		    Config.initial_register_tainting d
	in
	(* then the resulting domain d' is updated with the content for each register with initial content setting in the provided configuration *)  
	Hashtbl.fold
	  (fun r v d ->
	    let region = if Register.is_stack_pointer r then Data.Address.Stack else Data.Address.Global
	    in
	    Domain.set_register_from_config r region (check_init_size r v) d
	  )
	  Config.initial_register_content d'

      (** builds 0xffff...ff with nb repetitions of the pattern ff *)
      let ff nb =
	let ff = Z.of_int 0xff in
	let s = ref Z.zero in
	for _i = 1 to nb do
	  s := Z.add ff (Z.shift_left !s 8)
	done;
	!s
	  
      (** splits the given integer into a sequence of integers that fit into !Config.operand_sz bits *)
      let pad_of_int r a i: (Data.Address.t * Z.t) list =
	let a'    = Data.Address.of_int r a !Config.address_sz in
	let nb    = !Config.operand_sz / Config.size_of_byte   in
	let mask  = ff nb                                      in
	let l     = ref []                                     in
	let n     = ref i                                      in
	while Z.compare !n Z.zero > 0 do
	  l := (Z.logand mask !n)::!l;
	  n := Z.shift_right !n !Config.operand_sz 
	done;
	List.mapi (fun i v -> Data.Address.add_offset a' (Z.of_int (i*nb)), v) (List.rev !l)
	
   		   
      (** 1. split b into a list of tainting values of size Config.operand_sz *)
      (** 2. associates to each element of this list its address. First element has address a ; second one has a+1, etc. *)
      let extended_tainting_memory_pad r a t =
	match t with
	| Config.Taint b      -> List.map (fun (a', v') -> a', Config.Taint v') (pad_of_int r a b)
	| Config.TMask (b, m) -> 
	   let b' = pad_of_int r a b in
	   let m' = pad_of_int r a m in
	   let nb' = List.length b' in
	   let nm' = List.length m' in
	   if nb' = nm' then
	     List.map2 (fun (a, t) (_, m) -> a, Config.TMask (t, m)) b' m'
	   else
	     if nb' > nm' then
	       List.mapi (fun i (a, t) -> if i < nm' then a, Config.TMask (t, snd (List.nth m' i)) else a, Config.Taint t) b'
	     else
	       (* filling with '0' means that we suppose by default that memory is untainted *)
	       List.mapi (fun i (a, m) -> if i < nb' then a, Config.TMask (snd (List.nth b' i), m) else a, Config.TMask (Z.zero, m)) m' 

      let extended_content_memory_pad r a c =
	match c with
	  | Config.Content b    -> List.map (fun (a', v') -> a', Config.Content v') (pad_of_int r a b)
	  | Config.CMask (b, m) -> 
	   let b' = pad_of_int r a b in
	   let m' = pad_of_int r a m in
	   let nb' = List.length b' in
	   let nm' = List.length m' in
	   if nb' = nm' then
	     List.map2 (fun (a, t) (_, m) -> a, Config.CMask (t, m)) b' m'
	   else
	     if nb' > nm' then
	       List.mapi (fun i (a, t) -> if i < nm' then a, Config.CMask (t, snd (List.nth m' i)) else a, Config.Content t) b'
	     else
	      Log.error "Decoder: illegal mask for range assignment"
			 
      (* main function to initialize memory locations (Global/Stack/Heap) both for content and tainting *)
      (* this filling is done by iterating on corresponding tables in Config *)
      let init_mem d region content_tbl tainting_tbl =
	let repeat l n =
	  let n' = Z.to_int n in
	  match n' with
	  | 0  -> []
	  | 1  -> l
	  | n' ->
	     let o  = Z.of_int ((List.length l) * !Config.operand_sz) in
	     let l' = ref []					      in
	     for i = 1 to n'-1 do
	       let o' = Z.mul o (Z.of_int i) in
	       l' := !l' @ (List.map (fun (a, v) -> Data.Address.add_offset a o', v) l)
	     done;
	     l @ !l'
	in
	let dc' = Hashtbl.fold (fun (a, n) c d ->
		      let l = extended_content_memory_pad region a c in
		      let l' = repeat l n in
		      List.fold_left (fun d (a', c') -> Domain.set_memory_from_config a' Data.Address.Global c' d) d l'
		    ) content_tbl d
	in
	Hashtbl.fold (fun (a, n) t d ->
	    let l = extended_tainting_memory_pad region a t in
	    let l' = repeat l n in
	    List.fold_left (fun d (a', c') -> Domain.taint_memory_from_config a' Data.Address.Global c' d) d l') tainting_tbl dc'
	
      (* end of init utilities *)	     
      (*************************)

      (** CFA creation *)
      (** returned CFA has only one node : the state whose ip is given by the parameter and whose domain field is generated from the Config module *)
      let init ip =
	let d  = List.fold_left (fun d r -> Domain.add_register r d) (Domain.init()) (Register.used()) in
	(* initialisation of Global memory + registers *)
	let d' = init_mem (init_registers d) Data.Address.Global Config.initial_memory_content Config.initial_memory_tainting in
	(* init of the Stack memory *)
	let d' = init_mem d' Data.Address.Stack Config.initial_stack_content Config.initial_stack_tainting in
	(* init of the Heap memory *)
	let d' = init_mem d' Data.Address.Heap Config.initial_heap_content Config.initial_heap_tainting in
	let s = {
	    id = 0;
	    ip = ip;
	    v = d';
	    stmts = [];
	    ctx = {
		op_sz = !Config.operand_sz;
		addr_sz = !Config.address_sz;
	      };
	    internal = false
	}
	in
	let g = G.create () in
	G.add_vertex g s;
	g, s
 			       
      (* CFA utilities *)
      (*****************)
			     
      (** returns true whenever the two given contexts are equal *)
      let ctx_equal c1 c2 = c1.addr_sz = c2.addr_sz && c1.op_sz = c2.op_sz
								    
      (** [add_state g pred ip s stmts ctx i] creates a new state in _g_ with
    - ip as instruction pointer;
    - stmts as list of statements;
    - v as abstract value
    - ctx as decoding context
    - i is the boolean true for internal states ; false otherwise *)
      let add_state g ip v stmts ctx i =
	let v = {
	    id       = new_state_id();
	    v 	     = v;
	    ip 	     = ip;
	    stmts    = stmts ;
	    ctx      = ctx;
	    internal = i
	  }
	  in
	  G.add_vertex g v;
	  v

				    
      (** [add_edge g src dst l] adds in _g_ an edge _src_ -> _dst_ with label _l_ *)
      let add_edge g src dst l = G.add_edge_e g (G.E.create src l dst)
					      
      (** updates the abstract value field of the given state *)
      let update_state s v'=
      	s.v <- Domain.join v' s.v;
      	Domain.subset s.v v'
			  
      (** updates the context and statement fields of the given state *)
      let update_stmts s stmts op_sz addr_sz =
      	s.stmts <- stmts;
      	s.ctx   <- { addr_sz = addr_sz; op_sz = op_sz }

      (** returns the list of successors of the given vertex in the given CFA *)
      let succs g v  = G.succ g v

      (** fold on all vertices of a graph *)
      let fold_vertex f g i = G.fold_vertex f g i

      (** iter on all vertices of a graph *)
      let iter_vertex f g = G.iter_vertex f g
					  
      (** returns the unique predecessor of the given vertex in the given CFA *)
      (** may raise an exception if the vertex has no predessor *)
      let pred g v   =
	try List.hd (G.pred g v)
	with _ -> raise (Invalid_argument "vertex without predecessor")

      (** remove the given vertex of the given CFA *)
      let remove g v = G.remove_vertex g v

      (** dump the given CFA into the given file *)
      (** dot generation is also processed *)
      module GDot = struct
	include G
	let edge_attributes _e = []
	let default_edge_attributes _e = []
	let get_subgraph _g = None
	let vertex_attributes _v = []
	let default_vertex_attributes _v = []
	let graph_attributes _g = []
	let vertex_name v = string_of_int v.id
      end
      module Dot = Graph.Graphviz.Dot(GDot)
				     
      let print dumpfile dotfile g =
	let f = open_out dumpfile in
	(* state printing (detailed) *)
	let print_ip s =
	  let abstract_values = List.fold_left (fun s v -> v ^ "\n" ^ s) "" (Domain.to_string s.v) in
	  Printf.fprintf f "[address = %s]\nid = %d\n%s\n" (Data.Address.to_string s.ip) s.id abstract_values
	in
	G.iter_vertex print_ip g;
	(* edge printing (summary) *)
	Printf.fprintf f "[edges]\n";
	G.iter_edges_e (fun e -> Printf.fprintf f "e%d_%d = %d -> %d\n" (G.E.src e).id (G.E.dst e).id (G.E.src e).id (G.E.dst e).id) g;
	close_out f;
	(* dot generation *)	
	let f' = open_out dotfile in
	Dot.output_graph f' g;
	close_out f';
	

	
	
    end
  (** module Cfa *)
