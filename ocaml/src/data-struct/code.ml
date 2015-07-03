(** data type for the code *)
module type T =
  sig
    type t
    type address
	   
    (** constructor *)
    val make: address -> int -> string -> t
    (** The provided address is the entry point ; the integer is the offset (raises an exception if it is negative) *)
    (** of the entry point from the start of the provided byte sequence supposed to start at 0 index *)
					    
    (** returns the sub sequence of byte string starting at the given address *)
    val sub: t -> address -> string
    (** may raise an exception if the given address is out of range *)
			       
end

module Make (D: Data.T) =
  struct
    type t = {
	e: D.Address.t; (** entry point *)
	o: int; 	(** offset of the start of the string from the entry point *)
	c: string; 	(** the byte sequence containing the code *)	       
      }
	       
    type address   = D.Address.t
    let make e o c =
      if o >= 0 then
	{e = e ; o = o ; c = c}
      else
	raise Utils.Illegal_address
	      
    let sub v a =
      try
	let o   = Int64.to_int (D.Address.sub a v.e) in
	let len = (String.length v.c) - o            in
	String.sub v.c o len 
      with _ -> raise Utils.Illegal_address
  end
