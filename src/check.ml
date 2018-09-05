open CoreAst
open TagAst
open TagAstPrinter
open Util
open Printf
open Str

exception TypeException of string
exception DimensionException of int * int

(* Variable defs *)
type gamma = (typ) Assoc.context

(* Tags defs *)
type delta = (tag_typ) Assoc.context

(* Function defs *)
type phi = (fn_type list) Assoc.context

let trans_top (n1: int) (n2: int) : typ =
    TransTyp ((BotTyp n1), (TopTyp n2))

let trans_bot (n1: int) (n2: int) : typ =
    TransTyp ((TopTyp n1), (BotTyp n2))

let rec vec_dim (t: tag_typ) (d: delta) : int =
    debug_print ">> vec_dim";
    match t with
    | TopTyp n
    | BotTyp n -> n
    | VarTyp s -> try vec_dim (Assoc.lookup s d) d with _ -> failwith (string_of_tag_typ t)

let rec get_ancestor_list (t: tag_typ) (d: delta) : id list =
    match t with 
    | TopTyp _ -> []
    | BotTyp _ -> raise (TypeException "Bad failure -- Ancestor list somehow includes the bottom type")
    | VarTyp s -> s :: (get_ancestor_list (Assoc.lookup s d) d)

let is_tag_subtype (to_check: tag_typ) (target: tag_typ) (d: delta) : bool =
    match (to_check, target) with
    | BotTyp n1, BotTyp n2
    | BotTyp n1, TopTyp n2
    | TopTyp n1, TopTyp n2 -> n1 = n2
    | BotTyp n, VarTyp s -> n = (vec_dim target d)
    | VarTyp _, BotTyp _ -> false
    | VarTyp _, VarTyp s2 -> List.mem s2 (get_ancestor_list to_check d)
    | VarTyp s, TopTyp n -> n = (vec_dim to_check d)
    | TopTyp _, _ -> false

let is_subtype (to_check : typ) (target : typ) (d : delta) : bool =
    match (to_check, target) with 
    | (TagTyp t1, TagTyp t2) -> is_tag_subtype t1 t2 d (* MARK *)
    | (SamplerTyp i1, SamplerTyp i2) -> i1 = i2 
    | (BoolTyp, BoolTyp)
    | (IntTyp, IntTyp)
    | (FloatTyp, FloatTyp) -> true
    | (TransTyp (t1, t2), TransTyp (t3, t4)) -> 
        (is_tag_subtype t3 t1 d && is_tag_subtype t2 t4 d)
    | _ -> false

let subsumes_to (to_check: tag_typ) (target: tag_typ) (d: delta) : bool =
    match (to_check, target) with
    | VarTyp s, TopTyp n -> false (* Cannot upcast a variable to the toptyp *)
    | _ -> is_tag_subtype to_check target d

let least_common_parent (t1: tag_typ) (t2: tag_typ) (d: delta) : tag_typ =
    let check_dim (n1: int) (n2: int) : unit =
        if n1 = n2 then () else (raise (DimensionException (n1, n2)))
    in
    let rec lub (anc_list1: id list) (anc_list2: id list) : id =
        match anc_list1 with
        | [] -> raise (TypeException ("Cannot implicitly cast " ^ (string_of_tag_typ t1) ^ " and " ^ (string_of_tag_typ t2) ^ " to the top vector type"  ))
        | h::t -> 
            (try (List.find (fun x -> x=h) anc_list2) with Not_found -> lub t anc_list2)
    in
    match (t1, t2) with
    | BotTyp n1, BotTyp n2 ->
        check_dim n1 n2; BotTyp n1
    | BotTyp n1, TopTyp n2
    | TopTyp n1, BotTyp n2
    | TopTyp n1, TopTyp n2 ->
        check_dim n1 n2; TopTyp n1
    | VarTyp s, TopTyp n1
    | TopTyp n1, VarTyp s ->
        check_dim (vec_dim (VarTyp s) d) n1;
        raise (TypeException ("Cannot implicitly cast " ^ (string_of_tag_typ t1) ^ " and " ^ (string_of_tag_typ t2) ^ " to the top vector type"  ))
    | VarTyp s, BotTyp n1
    | BotTyp n1, VarTyp s ->
        check_dim (vec_dim (VarTyp s) d) n1; VarTyp s
    | VarTyp s1, VarTyp s2 ->
        check_dim (vec_dim (VarTyp s1) d) (vec_dim (VarTyp s2) d);
        (if s1 = s2 then VarTyp s1
        else VarTyp (lub (get_ancestor_list t1 d) (get_ancestor_list t2 d)))

let greatest_common_child (t1: tag_typ) (t2: tag_typ) (d: delta) : tag_typ =
    let check_dim (n1: int) (n2: int) : unit =
        if n1 = n2 then () else (raise (DimensionException (n1, n2)))
    in
    match (t1, t2) with
    | BotTyp n1, BotTyp n2
    | BotTyp n1, TopTyp n2
    | TopTyp n1, BotTyp n2 ->
        check_dim n1 n2; BotTyp n1
    | TopTyp n1, TopTyp n2 ->
        check_dim n1 n2; TopTyp n1
    | VarTyp s, TopTyp n1
    | TopTyp n1, VarTyp s ->
        check_dim (vec_dim (VarTyp s) d) n1; VarTyp s
    | VarTyp s, BotTyp n1
    | BotTyp n1, VarTyp s ->
        check_dim (vec_dim (VarTyp s) d) n1; BotTyp n1
    | VarTyp s1, VarTyp s2 ->
        let bot_dim = vec_dim (VarTyp s1) d in
        check_dim bot_dim (vec_dim (VarTyp s2) d);
        (* This works since each tag can only have one parent *)
        (if subsumes_to t1 t2 d then t1
        else if subsumes_to t2 t1 d then t2
        else BotTyp bot_dim)

let check_val (v: value) (d: delta) : typ = 
    debug_print ">> check_aval";
    match v with
    | Bool b -> BoolTyp
    | Num n -> IntTyp
    | Float f -> FloatTyp
    | _ -> raise (TypeException ("Unexpected typechecker value " ^ (string_of_value v)))

let check_tag_typ (tag: tag_typ) (d: delta) : unit =
    match tag with
    | TopTyp n
    | BotTyp n -> (if (n > 0) then ()
        else raise (TypeException "Cannot declare a type with dimension less than 0"))
    | VarTyp s -> (if Assoc.mem s d then ()
        else raise (TypeException ("Undeclared tag" ^ s)))

let check_typ_exp (t: typ) (d: delta) : unit =
    debug_print ">> check_typ";
    match t with
    | AutoTyp -> raise (TypeException "Cannot use type auto as a function argument")
    | UnitTyp
    | BoolTyp
    | IntTyp
    | FloatTyp 
    | SamplerTyp _ -> ()
    | TagTyp s -> check_tag_typ s d; ()
    | TransTyp (s1, s2) -> check_tag_typ s1 d; check_tag_typ s2 d; ()


(* "scalar linear exp", (i.e. ctimes) returns generalized MatTyp *)
let check_ctimes_exp (t1: typ) (t2: typ) (d: delta) : typ = 
    debug_print ">> check_scalar_linear_exp";
    match (t1, t2) with 
    | TransTyp (m1, m2), TransTyp (m3, m4) ->
        let left = (vec_dim m1 d) in
        let right = (vec_dim m2 d) in
        if left = (vec_dim m3 d) && right = (vec_dim m4 d)
        then trans_top left right
        else (raise (TypeException "dimension mismatch in ctimes operator"))
    | TagTyp l, TagTyp r -> (
        check_tag_typ l d; check_tag_typ r d;
        let ldim = vec_dim l d in
        let rdim = vec_dim r d in 
        if ldim = rdim 
        then TagTyp (TopTyp (vec_dim l d))
        else (raise (TypeException "dimension mismatch in ctimes operator"))
    )
    | _ -> (raise (TypeException ("expected linear types for ctimes operator, found: "^(string_of_typ t1)^", "^(string_of_typ t2))))

(* Type check norm expressions *)
let rec check_norm_exp (t: typ) (d: delta) : typ = 
    debug_print ">> check_norm_exp";
    match t with
    | TagTyp a -> t
    | _ -> (raise (TypeException "expected linear type for norm operator"))

(* Type check binary bool operators (i.e. &&, ||) *)
let check_bool_binop (t1: typ) (t2: typ) (d: delta) : typ = 
    debug_print ">> check_bool_binop";
    match (t1, t2) with 
    | BoolTyp, BoolTyp -> BoolTyp
    | _ -> raise (TypeException "expected boolean expression for binop")

(* Type check unary number operators (i.e. -) *)
let check_num_unop (t1: typ) (d: delta) : typ =
    debug_print ">> check_num_unop";
    match t1 with 
    | IntTyp
    | FloatTyp
    | TagTyp _
    | TransTyp _ -> t1
    | _ -> raise (TypeException "expected integer, float, vector, or matrix expression")

(* Type check unary bool operators (i.e. !) *)
let check_bool_unop (t1: typ) (d: delta) : typ =
    debug_print ">> check_bool_unop";
    match t1 with 
    | BoolTyp -> BoolTyp
    | _ -> raise (TypeException "expected boolean expression")

(* Type check unary bool operators (i.e. !) *)
let check_swizzle (s : id) (t1: typ) (d: delta) : typ =
    debug_print ">> check_swizzle";
    let check_reg valid_set = if Str.string_match valid_set s 0 
        then if String.length s == 1 then FloatTyp else TagTyp (TopTyp (String.length s))
        else raise (TypeException ("invalid characters used for swizzling in " ^ s)) in
    let valid_length_1 = Str.regexp "[xrs]+" in
    let valid_length_2 = Str.regexp "[xyrgst]+" in
    let valid_length_3 = Str.regexp "[xyzrgbstp]+" in
    let valid_length_4 = Str.regexp "[xyzwrgbastpq]+" in
    match t1 with
    | TagTyp v -> 
        let dim = vec_dim v d in
        if dim == 1 then check_reg valid_length_1 else
        if dim == 2 then check_reg valid_length_2 else
        if dim == 3 then check_reg valid_length_3 else
        if dim >= 4 then check_reg valid_length_4 else
        raise (TypeException "cannot swizzle a vector of length 0")
    | _ -> raise (TypeException "expected boolean expression")

(* Type check equality (==) *)
(* Only bool, int, float are comparable *)
let check_equality_exp (t1: typ) (t2: typ) (d: delta) : typ = 
    debug_print ">> check_comp_binop";
    match (t1, t2) with
    | BoolTyp, BoolTyp -> BoolTyp
    | IntTyp, IntTyp -> BoolTyp
    | FloatTyp, FloatTyp -> BoolTyp
    | _ -> raise (TypeException "unexpected type for binary comparator operations")

(* Type check comparative binary operators (i.e. <. <=) *)
(* Only int and float are comparable *)
let check_comp_binop (t1: typ) (t2: typ) (d: delta) : typ = 
    debug_print ">> check_comp_binop";
    match (t1, t2) with
    | IntTyp, IntTyp -> BoolTyp
    | FloatTyp, FloatTyp -> BoolTyp
    | _ -> raise (TypeException "unexpected type for binary comparator operations")

let check_dot_exp (t1: typ) (t2: typ) (d: delta): typ = 
    match (t1, t2) with 
    | TagTyp a1, TagTyp a2 ->  
        if subsumes_to a1 a2 d || subsumes_to a2 a1 d
        then FloatTyp 
        else raise (TypeException "expected tag type of same dimension for dot product exp")
    | _ -> raise (TypeException "unexpected type for dot product exp")

(* Type checking addition operations on scalar (int, float) expressions *)
(* Types are closed under addition and scalar multiplication *)
let check_addition_exp (t1: typ) (t2: typ) (d: delta) : typ =
    debug_print ">> check_addition";
    match (t1, t2) with 
    | IntTyp, IntTyp -> IntTyp
    | FloatTyp, IntTyp
    | IntTyp, FloatTyp
    | FloatTyp, FloatTyp -> FloatTyp
    | TagTyp a1, TagTyp a2 -> TagTyp (least_common_parent a1 a2 d)
    | TransTyp (m1, m2), TransTyp (m3, m4) -> 
        TransTyp (greatest_common_child m1 m3 d, least_common_parent m2 m4 d)
    | _ -> 
        (raise (TypeException ("invalid expressions for addition: "
        ^ (string_of_typ t1) ^ ", " ^ (string_of_typ t2))))

(* Type checking times operator - on scalar mult & matrix transformations *)
let check_times_exp (t1: typ) (t2: typ) (d: delta) : typ = 
    debug_print ">> check_times_exp";
    match (t1, t2) with
    | IntTyp, IntTyp -> IntTyp
    | FloatTyp, IntTyp
    | IntTyp, FloatTyp
    | FloatTyp, FloatTyp -> FloatTyp
    | (TagTyp _, TagTyp _) -> raise (TypeException "cannot multiply vectors together")

    (* Scalar Multiplication *)
    | IntTyp, TagTyp t
    | TagTyp t, IntTyp
    | FloatTyp, TagTyp t
    | TagTyp t, FloatTyp -> TagTyp t

    | IntTyp, TransTyp (m1, m2)
    | TransTyp  (m1, m2), IntTyp
    | FloatTyp, TransTyp  (m1, m2)
    | TransTyp  (m1, m2), FloatTyp -> TransTyp (m1, m2)

    (* Matrix * Vector Multiplication *)
    | TagTyp _, TransTyp _ -> 
        raise(TypeException "Cannot multiply a vector * matrix (did you mean matrix * vector?)")
    | TransTyp (m1, m2), TagTyp t -> 
        if subsumes_to t m1 d then (TagTyp m2)
        else raise (TypeException ("Cannot apply a matrix of type " ^ (string_of_typ t1)
            ^ " to a vector of type " ^ (string_of_typ t2)))

    (* Matrix * Matrix Multiplication *)
    | TransTyp (m1, m2), TransTyp (m3, m4) ->
        (* Check for a cast match between m2 and m3 *)
        least_common_parent m1 m4 d |> ignore;
        TransTyp (m3, m2)
    | _ -> raise (TypeException ("Invalid types for multiplication: "
        ^ (string_of_typ t1) ^ " and " ^ (string_of_typ t2)))

(* Type checking division operations (/) *)
(* Types are closed under scalar division *)
let check_division_exp (t1: typ) (t2: typ) (d: delta) : typ =
    debug_print ">> check_addition";
    match (t1, t2) with 
    | IntTyp, IntTyp -> IntTyp
    | FloatTyp, IntTyp
    | IntTyp, FloatTyp
    | FloatTyp, FloatTyp -> FloatTyp
    | TagTyp a, IntTyp
    | TagTyp a, FloatTyp -> TagTyp a
    | _ -> 
        (raise (TypeException ("invalid expressions for division: "
        ^ (string_of_typ t1) ^ ", " ^ (string_of_typ t2))))

let check_index_exp (t1: typ) (t2: typ) (d: delta) : typ =
    debug_print ">> check_addition";
    match (t1, t2) with 
    | TagTyp t, IntTyp -> FloatTyp
    | TransTyp (u, v), IntTyp -> TagTyp (TopTyp (vec_dim v d))
    | _ -> 
        (raise (TypeException ("invalid expressions for division: "
        ^ (string_of_typ t1) ^ ", " ^ (string_of_typ t2))))

let tag_erase (t : typ) (d : delta) : TypedAst.etyp =
    debug_print ">> tag_erase";
    match t with
    | AutoTyp -> raise (TypeException "Illegal use of auto (cannot use auto as part of a function call)")
    | UnitTyp -> TypedAst.UnitTyp
    | BoolTyp -> TypedAst.BoolTyp
    | IntTyp -> TypedAst.IntTyp
    | FloatTyp -> TypedAst.FloatTyp
    | TagTyp tag -> (match tag with
        | TopTyp n
        | BotTyp n -> TypedAst.VecTyp n
        | VarTyp _ -> TypedAst.VecTyp (vec_dim tag d))
    | TransTyp (s1, s2) -> TypedAst.MatTyp ((vec_dim s2 d), (vec_dim s1 d))
    | SamplerTyp i -> TypedAst.SamplerTyp i

    
(* Type check parameter; make sure there are no name-shadowed parameter names *)
let check_param ((id, t): (string * typ)) (g: gamma) (d: delta) : gamma = 
    debug_print ">> check_param";
    if Assoc.mem id g 
    then raise (TypeException ("duplicate parameter name in function declaration: " ^ id))
    else (
        match t with
        TagTyp (VarTyp v) -> 
            if Assoc.mem v d then Assoc.update id t g 
            else raise (TypeException ("Tag in parameter not defined : " ^ v))
        | _ -> Assoc.update id t g
    )
    
(* Get list of parameters from param list *)
let check_params (pl: (id * typ) list) (d: delta): TypedAst.params * gamma = 
    let g = List.fold_left (fun (g: gamma) p -> check_param p g d) Assoc.empty pl in 
    let p = List.map (fun (i, t) -> (i, tag_erase t d)) pl in 
    (p, g)

let exp_to_texp (checked_exp : TypedAst.exp * typ) (d : delta) : TypedAst.texp = 
    ((fst checked_exp), (tag_erase (snd checked_exp) d))

let rec check_exp (e: exp) (d: delta) (g: gamma) (p: phi): TypedAst.exp * typ = 
    debug_print ">> check_exp";
    let build_unop (op : unop) (e': exp) (check_fun: typ->delta->typ)
        : TypedAst.exp * typ =
        let result = check_exp e' d g p in
            (TypedAst.Unop(op, exp_to_texp result d), check_fun (snd result) d)
    in
    let build_binop (op : binop) (e1: exp) (e2: exp) (check_fun: typ->typ->delta->typ)
        : TypedAst.exp * typ =
        let e1r = check_exp e1 d g p in
        let e2r = check_exp e2 d g p in
            (TypedAst.Binop(op, exp_to_texp e1r d, exp_to_texp e2r d), check_fun (snd e1r) (snd e2r) d)
    in 
    match e with
    | Val v -> (TypedAst.Val v, check_val v d)
    | Var v -> "\tVar "^v |> debug_print;
        (TypedAst.Var v, Assoc.lookup v g)
    | Arr a -> check_arr d g p a
    | Unop (op, e') -> (match op with
        | Neg -> build_unop op e' check_num_unop
        | Not -> build_unop op e' check_bool_unop
        | Swizzle s -> build_unop op e' (check_swizzle s))
    | Binop (op, e1, e2) -> (match op with
        | Eq -> build_binop op e1 e2 check_equality_exp
        | Leq -> build_binop op e1 e2 check_comp_binop
        | Or | And -> build_binop op e1 e2 check_bool_binop
        | Plus | Minus -> build_binop op e1 e2 check_addition_exp
        | Times -> build_binop op e1 e2 check_times_exp
        | Div  -> build_binop op e1 e2 check_division_exp
        | CTimes -> build_binop op e1 e2 check_ctimes_exp
        | Index -> build_binop op e1 e2 check_index_exp
    )
    | FnInv (i, args) -> let ((i, args_exp), rt) = check_fn_inv d g p args i in 
        (FnInv (i, args_exp), rt)
        
and check_arr (d: delta) (g: gamma) (p: phi) (a: exp list) : (TypedAst.exp * typ) =
    let is_vec (v: TypedAst.texp list) : bool =
        List.fold_left (fun acc (_, t) -> match t with
            | TypedAst.IntTyp | TypedAst.FloatTyp -> acc | _ -> false) true v
    in
    let is_mat (v: TypedAst.texp list) : int option =
        match List.hd v with
        | (_, TypedAst.VecTyp size) ->
        List.fold_left (fun acc (_, t) -> match t with
            | TypedAst.VecTyp n -> if (n == size) then acc else None | _ -> None) (Some size) v
        | _ -> None
    in
    let checked_a = List.map (fun e -> (exp_to_texp (check_exp e d g p) d)) a in
    let length_a = List.length a in
    if is_vec checked_a then (TypedAst.Arr checked_a, TagTyp (BotTyp length_a)) else 
    (match is_mat checked_a with
    | Some n -> (TypedAst.Arr checked_a, trans_bot n length_a)
    | None ->  raise (TypeException ("Invalid array definition for " ^ (string_of_exp (Arr a)) ^ ", must be a matrix or vector")))
    

and check_fn_inv (d : delta) (g : gamma) (p : phi) (args : args) (i : string)
 : (string * TypedAst.args) * typ =
    let args' = List.map (fun a -> check_exp a d g p) args in 
    let args_exp = List.map fst args' in 
    let args_typ = List.map snd args' in
    let rec find_fn_inv (fns : fn_type list) : fn_type =
        match fns with
        | [] -> raise (TypeException ("No function matching the argument types " ^ 
        (String.concat ", " (List.map string_of_typ args_typ)) ^ " for the function " ^ i ^ " found"))
        | (params, rt)::t -> 
            let params_typ = List.map snd params in
            if List.length args_typ == List.length params_typ then
                if List.fold_left2 (fun acc arg param -> 
                acc && is_subtype arg param d)
                true args_typ params_typ 
                then (params, rt) else find_fn_inv t
            else find_fn_inv t 
    in
    let (_, rt) = find_fn_inv (Assoc.lookup i p) in
    ((i, args_exp), rt)

and check_comm (c: comm) (d: delta) (g: gamma) (p: phi): TypedAst.comm * gamma = 
    debug_print ">> check_comm";
    match c with
    | Skip -> (TypedAst.Skip, g)
    | Print e -> (
        let (e, t) = exp_to_texp (check_exp e d g p) d in 
        match t with
        | UnitTyp -> raise (TypeException "print function cannot print void types")
        | _ -> (TypedAst.Print (e, t), g)
    )
    | Decl (t, s, e) ->
        if Assoc.mem s g then raise (TypeException "variable name shadowing is illegal")
        else 
        let result = check_exp e d g p in
        let t' = (match t with | AutoTyp -> 
            (match (snd result) with
                | TagTyp (BotTyp _) -> raise (TypeException "Cannot infer the type of a vector literal")
                | TransTyp (TopTyp _, BotTyp _) -> raise (TypeException "Cannot infer the type of a matrix literal")
                | t' -> t')
            | _ -> t) in
        (TypedAst.Decl (tag_erase t' d, s, (exp_to_texp result d)), (check_assign t' s (snd result) d g p))

    | Assign (s, e) ->
        if Assoc.mem s g then
            let t = Assoc.lookup s g in
            let result = check_exp e d g p in
            (TypedAst.Assign (s, (exp_to_texp result d)), check_assign t s (snd result) d g p)
        else raise (TypeException "assignment to undeclared variable")

    | If (b, c1, c2) ->
        let result = (check_exp b d g p) in
        let c1r = check_comm_lst c1 d g p in
        let c2r = check_comm_lst c2 d g p in
        (match (snd result) with 
        | BoolTyp -> (TypedAst.If ((exp_to_texp result d), (fst c1r), (fst c2r)), g)
        | _ -> raise (TypeException "expected boolean expression for if condition"))
    | Return Some e ->
        let (e, t) = exp_to_texp (check_exp e d g p) d in
        (TypedAst.Return (Some (e, t)), g)
    | Return None -> (TypedAst.Return None, g)
    | FnCall (i, args) -> let ((i, args_exp), _) = check_fn_inv d g p args i in 
        (TypedAst.FnCall (i, args_exp), g)

and check_comm_lst (cl : comm list) (d: delta) (g: gamma) (p: phi) : TypedAst.comm list * gamma = 
    debug_print ">> check_comm_lst";
    match cl with
    | [] -> ([], g)
    | h::t -> let context = check_comm h d g p in
        let result = check_comm_lst t d (snd context) p in 
        ((fst context) :: (fst result), (snd result))

and check_assign (t: typ) (s: string) (etyp : typ) (d: delta) (g: gamma) (p: phi) : gamma =
    debug_print (">> check_assign <<"^s^">>");
    (* Check that t, if not a core type, is a registered tag *)
    (match t with
    | TransTyp (VarTyp t1, VarTyp t2) -> if not (Assoc.mem t1 d)
        then raise (TypeException ("unknown tag " ^ t2))
        else if not (Assoc.mem t2 d) then raise (TypeException ("unknown tag " ^ t1))
    | TagTyp (VarTyp t')
    | TransTyp (VarTyp t', _)
    | TransTyp (_, VarTyp t') ->
        if not (Assoc.mem t' d) then raise (TypeException ("unknown tag " ^ t'))
    | _ -> ());
    let check_name regexp = if Str.string_match regexp s 0 then raise (TypeException ("Invalid variable name " ^ s)) in
    check_name (Str.regexp "int$");
    check_name (Str.regexp "float$");
    check_name (Str.regexp "bool$");
    check_name (Str.regexp "vec[0-9]+$");
    check_name (Str.regexp "mat[0-9]+$");
    check_name (Str.regexp "mat[0-9]+x[0-9]+$");
    if Assoc.mem s d then 
        raise (TypeException ("variable " ^ s ^ " has the name of a tag"))
    else if Assoc.mem s p then
        raise (TypeException ("variable " ^ s ^ " has the name of a function"))
    else (
        match (t, etyp) with
        | (BoolTyp, BoolTyp)
        | (IntTyp, IntTyp)
        | (FloatTyp, FloatTyp) -> Assoc.update s t g
        | (TagTyp t1, TagTyp t2) ->
            least_common_parent t1 t2 d |> ignore;
            if subsumes_to t2 t1 d then Assoc.update s t g
            else raise (TypeException ("mismatched linear type for var decl: " ^ s))
        | (TransTyp (t1, t2), TransTyp (t3, t4)) ->
            if is_tag_subtype t1 t3 d && is_tag_subtype t4 t2 d then Assoc.update s t g
            else raise (TypeException ("no possible upcast for var decl: " ^ s))
        | _ -> raise (TypeException ("mismatched types for var decl for " ^ s ^  ": expected " ^ (string_of_typ t) ^ ", found " ^ (string_of_typ etyp)))
    )


let check_tag (s: string) (l: tag_typ) (d: delta) : delta = 
    debug_print ">> check_tag";
    if Assoc.mem s d then raise (TypeException "cannot redeclare tag")
            else Assoc.update s l d

let rec check_tags (t: tag_decl list) (d: delta): delta =
    debug_print ">> check_tags";
    match t with 
    | [] -> d
    | (s, a)::t ->
        check_typ_exp a |> ignore;
        match a with 
        | (TagTyp l) -> (
            match l with 
            | VarTyp s' -> (
                if Assoc.mem s' d then check_tag s l d |> check_tags t
                else raise (TypeException "tag undefined")
            )
            | _ -> check_tag s l d |> check_tags t
        )
        | _ -> raise (TypeException "expected linear type for tag declaration")

let check_fn_decl (d: delta) ((id, t): fn_decl) (p: phi) (no_dupes : bool) : phi =
    let update_phi (name : string) (ft : fn_type) (p : phi) : phi =
        let rec check_arg_dups (fns : fn_type list) : unit =
            match fns with
            | [] -> ()
            | h::t -> ()
        in
        if not (Assoc.mem name p)
        then Assoc.update name [ft] p
        else let fns = Assoc.lookup name p in 
        check_arg_dups fns; Assoc.update name (ft::(fns)) p
    in
    debug_print ">> check_fn_decl";
    let (pl, _) = t in
    let _ = check_params pl d in 
    if no_dupes && Assoc.mem id p 
    then raise (TypeException ("function of duplicate name has been found: " ^ id))
    else update_phi id t p

(* Helper function for type checking void functions. 
 * Functions that return void can have any number of void return statements 
 * anywhere. *)
let check_void_return (c: comm) =
    debug_print ">> check_void_return";
    match c with
    | Return Some _ -> raise (TypeException ("void functions cannot return a value"))
    | _ -> ()

let check_return (t: typ) (d: delta) (g: gamma) (p: phi) (c: comm) : unit = 
    debug_print ">> check_return";
    match c with
    | Return None -> raise (TypeException ("expected a return value instead of void"))
    | Return Some r -> (
        let (_, rt) = check_exp r d g p in
        (* raises return exception of given boolean exp is false *)
        let raise_return_exception b =
            if b then () 
            else raise (TypeException ("mismatched return types, expected: " ^ 
            (string_of_typ t) ^ ", found: " ^ (string_of_typ rt)))
        in
        match (t, rt) with
        | (TagTyp t1, TagTyp t2) -> subsumes_to t2 t1 d |> raise_return_exception
        | (SamplerTyp i1, SamplerTyp i2) -> i1 = i2 |> raise_return_exception 
        | (BoolTyp, BoolTyp)
        | (IntTyp, IntTyp)
        | (FloatTyp, FloatTyp)
        | (AutoTyp, _) -> ()
        | (TransTyp (t1, t2), TransTyp (t3, t4)) -> 
            (is_tag_subtype t3 t1 d && is_tag_subtype t2 t4 d) |> raise_return_exception
        | _ -> false |> raise_return_exception
        )
    | _ -> ()

let rec check_fn (((id, (pl, r)), cl): fn) (d: delta) (p: phi) : TypedAst.fn * phi = 
    debug_print ">> check_fn";
    (* fn := fn_decl * comm list *)
    let (pl', g') = check_params pl d in
    let (cl', g'') = check_comm_lst cl d g' p in 
    (* update phi with function declaration *)
    let p' = check_fn_decl d (id, (pl, r)) p in 
    (* check that the last command is a return statement *)
    match r with
    | UnitTyp -> List.iter check_void_return cl; ((((id, (pl', TypedAst.UnitTyp)), cl')), p' true)
    (* TODO: might want to check that there is exactly one return statement at the end *)
    | t -> List.iter (check_return t d g'' p) cl; ((((id, (pl', tag_erase t d)), cl')), p' true)

and check_fn_lst (fl: fn list) (d: delta) (p: phi) : TypedAst.prog * phi =
    debug_print ">> check_fn_lst";
    match fl with
    | [] -> ([], p)
    | h::t -> let (fn', p') = check_fn h d p in
        let (fn'', p'') = check_fn_lst t d p' in 
        ((fn' :: fn''), p'')

(* Check that there is a void main() defined *)
let check_main_fn (p: phi) (d: delta) =
    debug_print ">> check_main_fn";
    let main_fns = Assoc.lookup "main" p in
    let rec check_main (fl: fn_type list) =
        match fl with 
        | [] -> raise (TypeException ("expected main function to return void"))
        | (params, ret_type, parameterization)::t -> (
            match ret_type with
                | UnitTyp -> check_params params d |> fst
                | _ -> check_main t
        ) in 
    check_main main_fns

(* Returns the list of fn's which represent the program 
 * and params of the void main() fn *)
let check_prog (e: prog) : TypedAst.prog * TypedAst.params =
    debug_print ">> check_prog";
    match e with
    | Prog (dl, t, f) -> (*(d: delta) ((id, t): fn_decl) (p: phi) *)
        (* delta from tag declarations *)
        let d = check_tags t Assoc.empty in 
        let p = List.fold_left 
        (fun (a: phi) (dl': fn_decl) -> check_fn_decl d dl' a false)
        Assoc.empty dl in
        let (e', p') = check_fn_lst f d p in 
        let pr = check_main_fn p' d in 
        (e', pr)
