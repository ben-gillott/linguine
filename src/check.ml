open CoreAst
open GatorAst
open GatorAstPrinter
open Util
open Printf
open Str
open CheckUtil
open Contexts

let rec get_frame_top (cx : contexts) (x : string) : int =
    match get_frame cx x with
    | FrameDim s -> get_frame_top cx s
    | FrameNum n -> n

let rec reduce_dexp (cx: contexts) (d : dexp) : int =
    debug_print (">> reduce_dexp " ^ string_of_dexp d);
    match d with
    | DimNum n -> n
    | DimVar x -> get_frame_top cx x
    | DimBinop (l, b, r) -> match b with
            | Plus -> reduce_dexp cx l + reduce_dexp cx r
            | Minus -> reduce_dexp cx l - reduce_dexp cx r
            | _ -> error cx ("Invalid binary operation to dimension expression " ^ string_of_binop b)

let rec unwrap_abstyp (cx: contexts) (s: string) : typ =
    debug_print ">> unwrap_abstyp";
    match get_pm cx s with
        | ParTyp (s, tl) -> failwith "unimplemented partyp unwrapping"
        | p -> p

let rec replace_abstype (c: typ Assoc.context) (t: typ) : typ =
    debug_print ">> replace_abstype";
    let is_abs s = List.mem s (Assoc.keys c) in
    (* TODO: this isn't right, but I'm not sure what I want here *)
    match t with
    | ParTyp (s, tl) -> 
        if is_abs s then Assoc.lookup s c
        else ParTyp (s, List.map (replace_abstype c) tl)
    | CoordTyp (s, t') ->
        if is_abs s then Assoc.lookup s c
        else CoordTyp (s, replace_abstype c t')
    | _ -> t

let rec is_typ_eq (cx : contexts) (t1: typ) (t2: typ) : bool =
    match (t1, t2) with
    | UnitTyp, UnitTyp
    | BoolTyp, BoolTyp
    | IntTyp, IntTyp
    | FloatTyp, FloatTyp -> true
    | Literal t1, Literal t2 -> is_typ_eq cx t1 t2
    | ArrTyp (t1, d1), ArrTyp (t2, d2) -> is_typ_eq cx t1 t2 && reduce_dexp cx d1 = reduce_dexp cx d2
    | CoordTyp (c1, ParTyp (o1, f1)), CoordTyp(c2, ParTyp (o2, f2)) -> 
        c1 = c2 && is_typ_eq cx (ParTyp (o1, f1)) (ParTyp (o2, f2))
    | ParTyp (s1, tl1), ParTyp (s2, tl2) -> s1 = s2 && 
        (if (List.length tl1 = List.length tl2) 
        then list_typ_eq cx tl1 tl2
        else false)    
    | _ -> false

and list_typ_eq (cx : contexts) (tl1: typ list) (tl2: typ list) : bool 
    = List.fold_left2 (fun acc x y -> acc && is_typ_eq cx x y) true tl1 tl2

let rec is_subtype (cx: contexts) (to_check : typ) (target : typ) : bool =
    debug_print (">> is_subtype " ^ (string_of_pair (string_of_typ to_check) (string_of_typ target)));
    if is_typ_eq cx to_check target then true else
    match (to_check, target) with
    | BotTyp, _ -> true
    | _, BotTyp -> false
    | _, AnyTyp -> true
    | AnyTyp, _ -> false
    | BoolTyp, GenTyp -> false
    | _, GenTyp -> true
    | GenArrTyp t1, GenArrTyp t2 -> is_subtype cx t1 t2
    | ArrTyp (t, _), GenArrTyp c -> is_subtype cx t c

    | ArrTyp (t1, d1), ArrTyp (t2, d2) ->
        reduce_dexp cx d1 = reduce_dexp cx d2 
        && is_subtype cx t1 t2
    | ParTyp (s1, tl1), ParTyp (s2, tl2) -> (s1 = s2 && List.length tl1 = List.length tl2
        && list_typ_eq cx tl1 tl2)
        || is_subtype cx (tau_lookup cx s1 tl1) target
    | CoordTyp (c1, ParTyp (o1, f1)), CoordTyp (c2, ParTyp (o2, f2)) ->
        (c1 = c2 && list_typ_eq cx f1 f2)
        || is_subtype cx (chi_object_lookup cx c1 o1 f1) target
    
    (* Type lookup cases *)
    | Literal t, _ -> is_subtype cx target t
    | ParTyp (s, tl), _ -> is_subtype cx (tau_lookup cx s tl) target
    | CoordTyp (c, ParTyp (o, f)), _ -> is_subtype cx (chi_object_lookup cx c o f) target

    | _ -> false

(* Given a parameterization and a list of types being invoked on that parameterization *)
(* Returns the appropriate concretized context if one exists *)
and match_parameterization (cx: contexts) (pml : typ list)
: typ Assoc.context =
    debug_print ">> match_parameterization";
    let pmb = Assoc.bindings cx.pm in
    if List.length pmb == List.length pml
        && List.fold_left2 (fun acc (s, c) t -> is_subtype cx t c && acc) true pmb pml
    then List.fold_left2 (fun tcacc (s, c) t -> Assoc.update s t tcacc)
        Assoc.empty (Assoc.bindings cx.pm) pml
    else error cx ("Invalid parameterization provided to " ^ string_of_parameterization cx.pm
        ^ " by <" ^ string_of_separated_list "," string_of_typ pml ^ ">")
 
(* Looks up a supertype without checking the bounds on the provided parameters (hence, 'unsafe') *)
and tau_lookup (cx: contexts) (x: id) (pml: typ list) : typ =
    (* If the given type evaluates to a declared tag, return it *)
    (* If the return type would be a top type, resolve the dimension to a number *)
    debug_print ">> tau_lookup";
    let pmd, t = get_typ cx x in
    let tc = match_parameterization (with_pm cx pmd) pml in
    replace_abstype tc t

(* Looks up an object 'o' definition from a coordinate scheme 'c' without checking parameter bounds *)
and chi_object_lookup (cx: contexts) (c : id) (o: id) (f: typ list) : typ =
    match get_coordinate_element cx c o with
    | CoordObjectAssign (_, pmd, t) -> 
        let tc = match_parameterization (with_pm cx pmd) f in
        replace_abstype tc t
    | _ -> error cx ("")

(* Steps types up a level in the subtyping tree *)
(* Fails if given a primitive type, illegal geometric type, or external type (they have no supertype) *)
let rec typ_step (cx : contexts) (t : typ) : typ option =
    debug_print (">> typ_step" ^ string_of_typ t);
    match t with
    | ParTyp (s, tl) -> Some (tau_lookup cx s tl)
    | CoordTyp (c, ParTyp (o, f)) -> Some (chi_object_lookup cx c o f)
    | Literal t -> Some t
    | _ -> None

(* Produces a primitive type (boolean, int, float, array, or array literal) *)
let rec primitive (cx : contexts) (t : typ) : typ =
    debug_print (">> primitive" ^ string_of_typ t);
    match typ_step cx t with
    | Some t' -> primitive cx t'
    | None -> t

let rec greatest_common_child (cx: contexts) (t1: typ) (t2: typ): typ =
    debug_print ">> greatest_common_child";    
    if is_subtype cx t1 t2 then t1 else 
    if is_subtype cx t2 t1 then t2 else 
    let top = primitive cx t1 in
    if is_typ_eq cx top (primitive cx t2) then Literal top else
    error cx ("Cannot unify " ^ (string_of_typ t1) ^ " and " ^ (string_of_typ t2))

let rec least_common_parent (cx: contexts) (t1: typ) (t2: typ): typ =
    debug_print (">> least_common_parent" ^ (string_of_pair (string_of_typ t1) (string_of_typ t2)));
    if is_subtype cx t1 t2 then t2 else if is_subtype cx t2 t1 then t1 
    else match typ_step cx t1 with 
    | Some t1' -> least_common_parent cx t1' t2
    | None -> error cx ("Cannot unify " ^ (string_of_typ t1) ^ " and " ^ (string_of_typ t2))

(* Least common parent which will not raise an exception (used for typechecking of inferred/internal types) *)
let least_common_parent_safe (cx: contexts) (t1: typ) (t2: typ): typ option =
    try Some (least_common_parent cx t1 t2) with
    | TypeException _ -> None
    | t -> raise t

let check_subtype_list (cx: contexts) (l: typ list) (t: typ) : bool =
    debug_print ">> check_subtype_list";
    List.fold_left (fun acc t' -> acc || (is_subtype cx t t')) false l
    
let check_typ_valid (cx: contexts) (ogt: typ) : unit =
    let rec check_typ_valid_rec (t: typ) : unit =
        debug_print ">> check_typ_valid";
        match t with
        | ParTyp (s, tl) -> 
            ignore_typ (tau_lookup cx s tl);
            List.fold_left (fun _ -> check_typ_valid_rec) () tl
        | CoordTyp (c, ParTyp(o, f)) ->
            ignore_typ (chi_object_lookup cx c o f);
        | CoordTyp _ ->
            error cx ("All types a.b must be geometric (i.e. of the form scheme.object<frames>) and "
                ^ string_of_typ t ^ " fails to adhere to this form")
        | _ -> ()
    in check_typ_valid_rec ogt

let rec typ_erase_param (cx: contexts) (t: typ) : TypedAst.etyp = 
    debug_print ">> tag_erase_param";
    match t with
    | ParTyp(s, tl) -> if Assoc.mem s cx.pm then 
        let c = Assoc.lookup s cx.pm in 
        TypedAst.AbsTyp (s, constrain_erase cx c)
        else error cx ("AbsTyp " ^ s ^ " was not found in function parameterization definition")
    | _ -> typ_erase cx t

and typ_erase (cx: contexts) (t : typ) : TypedAst.etyp =
    debug_print ">> tag_erase";
    let d_to_c opd = match opd with
    | DimNum i -> ConstInt(i) 
    | DimVar s -> ConstVar(s)
    | _ -> error cx ("No valid concrete interpretation of " ^ string_of_typ t) in
    match t with
    | UnitTyp -> TypedAst.UnitTyp
    | BoolTyp -> TypedAst.BoolTyp
    | IntTyp -> TypedAst.IntTyp
    | FloatTyp -> TypedAst.FloatTyp
    | ArrTyp (t', d) -> TypedAst.ArrTyp (typ_erase cx t', d_to_c d)
    | CoordTyp _ | ParTyp _ | Literal _ -> typ_erase cx (primitive cx t)
    | AutoTyp -> error cx ("Illegal use of auto (cannot use auto as part of a function call)")
    | _ -> debug_fail cx "Invalid use of typ_erase"

and constrain_erase (cx: contexts) (t: typ) : TypedAst.constrain =
    debug_print ">> constrain_erase";
    match t with
    | AnyTyp -> TypedAst.AnyTyp
    | GenTyp -> TypedAst.GenTyp
    | GenArrTyp _ -> debug_fail cx "unimplemented genarrtyp erasure"
    | _ -> TypedAst.ETypConstraint(typ_erase cx t)

let rec etyp_to_typ (e : TypedAst.etyp) : typ =
    debug_print ">> etyp_to_typ";
    match e with 
    | TypedAst.UnitTyp -> UnitTyp
    | TypedAst.BoolTyp -> BoolTyp
    | TypedAst.IntTyp -> IntTyp
    | TypedAst.FloatTyp -> FloatTyp
    | TypedAst.VecTyp n -> ArrTyp (FloatTyp, DimNum n)
    | TypedAst.MatTyp (n1, n2) -> ArrTyp(ArrTyp(FloatTyp, DimNum n1), DimNum n2)
    | TypedAst.TransTyp (s1, s2) -> failwith "unimplemented removal of transtyp from typedast"
    | TypedAst.AbsTyp (s, c) -> ParTyp(s, [])
    | TypedAst.ArrTyp (t, c) -> ArrTyp (etyp_to_typ t, 
        match c with | ConstInt i -> DimNum i | ConstVar v -> DimVar v)

and constrain_to_typ (c : TypedAst.constrain) : typ =
    debug_print ">> constrain_to_constrain";
    match c with
    | TypedAst.AnyTyp -> AnyTyp
    | TypedAst.GenTyp -> GenTyp
    | TypedAst.GenMatTyp -> GenArrTyp(FloatTyp)
    | TypedAst.GenVecTyp -> GenArrTyp(GenArrTyp(FloatTyp))
    | TypedAst.ETypConstraint t -> etyp_to_typ t

let rec check_val (cx: contexts) (v: value) : typ = 
    debug_print ">> check_aval";
    match v with
    | Bool b -> Literal BoolTyp
    | Num n -> Literal IntTyp
    | Float f -> Literal FloatTyp
    | ArrLit v -> Literal (ArrTyp (List.fold_left (least_common_parent cx) BotTyp (List.map (check_val cx) v), 
        DimNum (List.length v)))
    | Unit -> error cx ("Unexpected value " ^ (string_of_value v))

let exp_to_texp (cx: contexts) ((exp, t) : TypedAst.exp * typ) : TypedAst.texp = 
    debug_print ">> exp_to_texp";
    exp, typ_erase cx t

(* Given a function and list of arguments to that function *)
(* Attempts to produce a list of valid types for the parameterization of the function *)
let infer_pml (cx: contexts) (pr : params) (args : typ list) : (typ list) option =
    debug_print ">> infer_pml";
    let update_inference (t : typ) (s : string) (fpm : typ Assoc.context option) : typ Assoc.context option =
        match fpm with | None -> None | Some p ->
        if Assoc.mem s p then match least_common_parent_safe cx t (Assoc.lookup s p) with
            | None -> None
            | Some t' -> Some (Assoc.update s t' p)
        else Some (Assoc.update s t p)
    in
    let rec unify_param (fpm : (typ Assoc.context) option) (arg_typ : typ) (par_typ : typ) : (typ Assoc.context) option =
        (* Only update our inference if we are working on an abstract type *)
        let is_abs s = List.mem s (Assoc.keys cx.pm) in
        let new_fpm s = if is_abs s then update_inference arg_typ s fpm else fpm in
        match arg_typ, par_typ with
        | ParTyp (_, tl1), ParTyp (s, tl2) ->
            (* Abstract params may have unspecified parameterizations provided by the arguments *)
            if List.length tl1 != List.length tl2 then new_fpm s else
            List.fold_left2 unify_param (new_fpm s) tl1 tl2
        | CoordTyp (_, t1), CoordTyp(s, t2) ->
            unify_param (new_fpm s) t1 t2
        | _ -> fpm
    in
    let inferred = List.fold_left2 unify_param (Some Assoc.empty) args (List.map fst pr) in
    option_map Assoc.values inferred

let check_fn_inv (cx: contexts) (x : id) (pml: typ list) (args : (TypedAst.exp * typ) list)
: (string * TypedAst.etyp list * TypedAst.args) * typ = 
    debug_print (">> check_fn_inv " ^ x);
    let arg_typs = List.map snd args in
    (* find definition for function in phi *)
    (* looks through all possible overloaded definitions of the function *)
    let find_fn_inv ((ml, rt, x, pr, params, meta') : fn_typ) : (typ Assoc.context) option =
        debug_print ">> find_fn_inv";
        (* This function asserts whether or not the function invocation matches the function given *)
        (* In particular, this checks whether the given function matches the given parameterization and parameters *)
        (* If it is valid, this returns (Some 'map from parameter to type'), otherwise returns 'None' *)

        (* If we have the wrong number of arguments, then no match for sure *)
        if List.length args != List.length params then None else
        (* Work out the parameter inference if one is needed *)
        let inferred_pml = 
            if Assoc.size pr == List.length pml then Some pml
            else if List.length pml == 0 then infer_pml cx params arg_typs
            else None
        in
        match inferred_pml with | None -> None | Some ipml ->
        (* Helper function for using the function parameters as they are constructed *)
        let rec apply_fpm (fpm : typ Assoc.context) (t: typ) : typ =
            let is_abs s = List.mem s (Assoc.keys fpm) in
            (* TODO: this isn't right, but I'm not sure what I want here *)
            match t with
            | ParTyp (s, tl) -> 
                if is_abs s then Assoc.lookup s fpm
                else ParTyp (s, List.map (apply_fpm fpm) tl)
            | CoordTyp (s, t') ->
                if is_abs s then Assoc.lookup s fpm
                else CoordTyp (s, apply_fpm fpm t')
            | _ -> t
        in
        (* Check that the parameterization conforms to the bounds provided *)
        let param_check = 
            debug_print ">> param_check";
            List.fold_left2 (fun acc given_pm (s, t) -> 
            match acc with 
            | None -> None
            | Some fpm -> let bound = apply_fpm fpm t in 
                if is_subtype cx given_pm bound
                then Some (Assoc.update s given_pm fpm) else None)
            (Some Assoc.empty) ipml (Assoc.bindings pr)
        in
        match param_check with | None -> None | Some pm_map ->
        (* Get the parameters types and replace them in params_typ *)
        let param_typs = List.map fst params in
        let param_typs_updated = List.map (apply_fpm pm_map) param_typs in
        (* Finally, check that the arg and parameter types match *)
        if List.length arg_typs == List.length param_typs then
            List.fold_left2 (fun acc arg param -> if (is_subtype cx arg param) then acc else None)
            param_check arg_typs param_typs_updated
        else None
    in
    let fn_invocated =  
    match String.split_on_char '.' x with
    | [c;x'] -> let p,_,_ = get_coordinate cx c in
        (match get_prototype_element cx p x' with
        | ProtoFn f -> f
        | _ -> error cx ("Expected " ^ p ^ "." ^ x ^ " to be a function"))
    | [_] -> get_function cx x 
    | _ -> error cx ("Multiple leves of coordinate schemes not supported for " ^ x)
    in
    let (_, rt, _, _, _, _) = fn_invocated in
    match find_fn_inv fn_invocated with
    | Some pmt -> (x, List.rev (List.map (fun p -> typ_erase cx (snd p)) (Assoc.bindings pmt)), 
        List.map (exp_to_texp cx) args), replace_abstype pmt rt
    | None -> error cx ("No overloaded function declaration of " ^ x
    ^ if List.length pml > 0 then string_of_bounded_list string_of_typ "<" ">" pml else ""
    ^ " matching types " ^ string_of_bounded_list string_of_typ "(" ")" arg_typs ^ " found")

let check_parameterization (cx: contexts) (pm: parameterization) : unit =
    debug_print ">> check_parameterization_decl";
    let check_parameter found (s, t) =
        if Assoc.mem s found then error cx ("Duplicate parameter `" ^ s)
        else check_typ_valid (with_pm cx found) t;
        Assoc.update s t found
    in
    ignore_typ_context (List.fold_left check_parameter Assoc.empty (Assoc.bindings pm)); ()
    
let as_par_typ (cx : contexts) (t : typ) : string * typ list =
    match t with
    | ParTyp (s, t') -> s,t'
    | _ -> debug_fail cx ("Invalid type " ^ string_of_typ t ^ " provided to updating psi")

let update_psi (cx: contexts) (ml: modification list) (start: typ) 
(target: typ) ((f, pml) : string * typ list) : psi Assoc.context =
    (* Update psi, raising errors in case of a duplicate *)
    (* If the given type is not valid in psi, psi is returned unmodified *)
    (* Will raise a failure if a non-concrete vartyp is used *)
    debug_print ">> update_psi";
    let is_valid (t: typ) : bool =
        match t with
        | ParTyp _ -> true
        | _ -> false
    in
    if not (is_valid start) || not (is_valid target) then cx.ps else
    let rec check_var_typ_eq (t1: typ) (t2: typ) : bool =
        match (t1, t2) with
        | ParTyp (s1, tl1), ParTyp (s2, tl2) -> s1 = s2 && 
            if List.length tl1 = List.length tl2
            then List.fold_left2 (fun acc t1' t2' -> acc && check_var_typ_eq t1' t2') true tl1 tl2
            else false
        | _ -> false
    in
    let s1, tl1 = as_par_typ cx start in
    let st, ttl = as_par_typ cx target in
    let start_index = string_of_typ start in
    let to_add = (target, (f, pml)) in
    if List.mem Canon ml then
        if Assoc.mem start_index cx.ps then 
        (let start_list = Assoc.lookup start_index cx.ps in
            if (List.fold_left (fun acc (lt, (_, _)) -> acc ||
                    (let (s2, tl2) = as_par_typ cx lt in
                    if (List.length ttl = List.length tl2) 
                    then List.fold_left2 (fun acc' t1 t2 -> acc' || (check_var_typ_eq t1 t2)) false ttl tl2
                    else false))
                false start_list)
            then error cx ("Duplicate transformation for " ^ 
                start_index ^ "->" ^ string_of_typ (ParTyp(s1, ttl)) ^
                " in the declaration of " ^ f)
            else Assoc.update start_index (to_add :: start_list) cx.ps
        )
        else Assoc.update start_index [to_add] cx.ps
    else cx.ps

(* Type check parameter; check parameter typ validity *)
(* Returns gamma *)
let check_param (cx: contexts) (t, id: typ * string) : contexts = 
    debug_print ">> check_param";
    check_typ_valid cx t;
    bind cx id (Gamma t)
    
(* Get list of parameters from param list *)
(* Returns gamma *)
let check_params (cx: contexts) (pl : params) : contexts * TypedAst.params = 
    debug_print ">> check_params";
    let cx' = List.fold_left check_param cx pl in 
    let p = (List.map (fun (t, x) -> typ_erase cx t, x) pl) in 
    cx', p

let check_index_exp (cx : contexts) (t1 : typ)  (t2 : typ) : typ =
    match t1, t2 with
    | ArrTyp (t, _), IntTyp -> t
    | _ -> error cx ("Expected array and integer for indexing, got " 
        ^ string_of_typ t1 ^ " and " ^ string_of_typ t2)

let check_as_exp (cx: contexts) (start: typ) (target : typ) : typ =
    if is_subtype cx start target then target
    else error cx ("Expected " ^ string_of_typ start ^ " to be a subtype of " ^ string_of_typ target)

(* Super expensive.  We're essentially relying on small contexts *)
let check_in_exp (cx: contexts) (start_exp: aexp) (start: typ) (target: typ) : aexp = 
    debug_print ">> check_in_exp";
    let rec psi_path_rec (to_search: (typ * aexp) Queue.t) (found: typ list) : aexp =
        let search_phi (tl: typ) (ps_lst : (typ * fn_inv) list) : (typ * fn_inv) list =
            (* This function searches phi for canonical abstract functions that map from the given type *)
            (* A list of the types these functions map with the inferred type parameters is returned *)
            (* If multiple functions are possible, then ambiguities are resolved with the following priorities *)
            (* 1. Minimize upcasting requirements (actually handled by use of this function) *)
            (* 2. Minimize number of type parameters *)
            (* 3. Minimize constraint bounds *)            
            let rec search_phi_rec (fns : (string * fn_typ) list) : (typ * (id * typ list * typ list)) list =
                match fns with
                (* Note that matrices are always selected over canonical function invocations *)
                | [] -> List.map (fun (t, (x, y)) -> (t, (x, y, []))) ps_lst 
                | (id, (ml, rt, _, pr, params, meta')) :: t -> 
                    let cx' = with_meta cx meta' in
                    if List.mem Canon (Assoc.lookup id cx.m) then
                        let pt = match params with | [(pt,_)] -> pt 
                        | _ -> failwith ("function " ^ id ^ " with non-one argument made canonical") in
                        match infer_pml cx params [tl] with | None -> search_phi_rec t | Some pml ->
                        let pr1 = List.map snd (Assoc.bindings pr) in
                        let rtr = replace_abstype (match_parameterization (with_pm cx' pr) pml) rt in
                        let ptr = replace_abstype (match_parameterization (with_pm cx' pr) pml) pt in
                        let fail id2 s = error cx ("Ambiguity between viable canonical functions " 
                            ^ id ^ " and " ^ id2 ^ " (" ^ s ^ ")") in
                        let compare_parameterizations (acc : bool option) t1 t2 : bool option = 
                            let result = is_subtype cx' t1 t2 in match acc with | None -> Some result
                            | Some b -> if b = result then acc else error cx' 
                            ("Ambiguous constraint ordering between " ^ string_of_typ t1
                            ^ " and " ^ string_of_typ t2)
                        in
                        if not (is_subtype cx tl ptr) then search_phi_rec t else
                        match rtr with
                        | ParTyp (_, _) -> let rec_result = search_phi_rec t in
                            if List.fold_left (fun acc (rt, _) -> is_typ_eq cx rt rtr || acc) false rec_result then
                                List.map (fun (rt, (id2, pml2, pr2)) -> 
                                if (List.length pr1 = List.length pr2) && (List.length pr1 = 0) then
                                fail id2 ("duplicate concrete paths from " ^ string_of_typ tl ^ " to " ^ string_of_typ rtr)
                                else if not (is_typ_eq cx' rt rtr) then (rt, (id2, pml2, pr2))
                                else if List.length pr1 < List.length pr2 then (rt, (id, pml, pr1))
                                else if List.length pr2 < List.length pr1 then (rt, (id2, pml2, pr2))
                                else if (match List.fold_left2 compare_parameterizations None pr1 pr2 with
                                    | None -> failwith "Unexpected concrete function type duplicates in phi" 
                                    | Some b -> b) then (rt, (id2, pml2, pr2))
                                else (rtr, (id, pml, pr1))) rec_result
                            (* No duplicate type result found, just add this function to the list *)
                            else (rtr, (id, pml, pr1)) :: rec_result
                        | _ -> error cx ("Canonical function " ^ id ^ " resulted in type "
                            ^ string_of_typ rtr ^ ", while canonical functions should always result in a partyp")
                    else search_phi_rec t
            in
            (* TODO: using _bindings here is super janky, but it's hard to fix rn, so... *)
            List.map (fun (t, (x, y, z)) -> (t, (x, y))) (search_phi_rec (Assoc.bindings cx._bindings.p))
        in
        let rec psi_lookup_rec (nt: typ) : (typ * fn_inv) list =
            (* NOTE: paths which would send to a type with more than 
             * 5 generic levels are rejected to avoid infinite spirals *)
            let rec check_typ_ignore (t: typ) (count: int) : bool =
                if count > 5 then true else
                match t with
                | ParTyp (_, tl) -> List.fold_left (fun acc t -> acc || check_typ_ignore t (count + 1)) false tl
                | _ -> false
            in
            if check_typ_ignore nt 0 then [] else
            let s_lookup = string_of_typ nt in
            let ps_lst = if Assoc.mem s_lookup cx.ps then Assoc.lookup s_lookup cx.ps else [] in
            let to_return = search_phi nt ps_lst in
            let (ns, ntl) = as_par_typ cx nt in
            let next_step = match nt with | ParTyp _ -> tau_lookup cx ns ntl | _ -> nt in
            match next_step with
            | ParTyp _ -> 
                to_return @ psi_lookup_rec next_step
            | _ -> to_return
        in 
        let rec update_search_and_found (vals: (typ * fn_inv) list) (e: aexp) : typ list =
            match vals with
            | [] -> found
            | (t1, (v, pml))::t -> 
                if List.fold_left (fun acc t2 -> acc || is_typ_eq cx t1 t2) false found 
                then update_search_and_found t e 
                else 
                let e' = 
                    match find_safe cx v with
                    | Some Gamma _ -> Binop ((Var v, snd e), Times, e), snd e
                    | Some Phi _ -> FnInv (v, pml, [e]), snd e
                    | _ -> debug_fail cx ("Typechecker error: unknown value " ^ v ^ " loaded into psi") in
                (* Note the update to the stateful queue *)
                (Queue.push (t1, e') to_search;  t1 :: update_search_and_found t e)
        in
        let (nt, e) = if Queue.is_empty to_search 
            then error cx ("Cannot find a path from " ^
                string_of_typ start ^ " to " ^ string_of_typ target)
            else Queue.pop to_search 
        in 
        (* We use the 'with_strictness' version to avoid throwing an exception *)
        if is_subtype cx nt target then e
        else psi_path_rec to_search (update_search_and_found (psi_lookup_rec nt) e)
    in	
	if string_of_typ start = string_of_typ target then start_exp else
	let q = Queue.create () in Queue.push (start, start_exp) q;
	psi_path_rec q []

let rec check_aexp (cx: contexts) ((e, meta) : aexp) : TypedAst.exp * typ =
    check_exp (with_meta cx meta) e

and check_exp (cx: contexts) (e : exp) : TypedAst.exp * typ = 
    debug_print ">> check_exp";
    let build_unop (op : unop) (e': aexp) (s: string)
        : TypedAst.exp * typ =
        let result = check_aexp cx e' in
            TypedAst.Unop(op, exp_to_texp cx result), snd (check_fn_inv cx s [] [result])
    in
    let build_binop (op : binop) (e1: aexp) (e2: aexp) (s: string)
        : TypedAst.exp * typ =
        let e1r = check_aexp cx e1 in
        let e2r = check_aexp cx e2 in
            TypedAst.Binop(exp_to_texp cx e1r, op, exp_to_texp cx e2r), 
            snd (check_fn_inv cx s [] [e1r; e2r])
    in
    match e with
    | Val v -> (TypedAst.Val v, check_val cx v)
    | Var v -> "\tVar "^v |> debug_print; TypedAst.Var v, get_var cx v
    | Arr a -> check_arr cx a
    | As (e', t) -> let er, tr = check_aexp cx e' in er, check_as_exp cx tr t
    | In (e', t) -> let _, tr = check_aexp cx e' in 
        check_aexp cx (check_in_exp cx e' tr t)
    | Unop (op, e') -> let s = match op with
            | Neg -> "-"
            | Not -> "!"
            | Swizzle s -> "swizzle" in
        build_unop op e' s
    | Binop (e1, op, e2) -> 
        (match op with
        | Index -> (* Stupid special case *)
            let e1r = check_aexp cx e1 in
            let e2r = check_aexp cx e2 in
            TypedAst.Binop(exp_to_texp cx e1r, Index, exp_to_texp cx e2r), check_index_exp cx (snd e1r) (snd e2r)
        | _ -> let s = match op with
            | Eq -> "="
            | Leq -> "<="
            | Lt -> "<"
            | Geq -> ">="
            | Gt -> ">"
            | Or -> "||"
            | And -> "&&"
            | Plus -> "+"
            | Minus -> "-"
            | Times -> "*"
            | Div  -> "/"
            | CTimes -> "*."
            | Index -> debug_fail cx "Bad assumption made"
        in build_binop op e1 e2 s)
    | FnInv (x, pr, args) -> 
        let (a, b, c), t = check_fn_inv cx x pr (List.map (check_aexp cx) args) in
        TypedAst.FnInv (a, b, c), t
        
and check_arr (cx: contexts) (a : aexp list) : TypedAst.exp * typ =
    debug_print ">> check_arr";
    let a' = List.map (check_aexp cx) a in
    TypedAst.Arr(List.map (exp_to_texp cx) a'),
    List.fold_left (fun acc (_,t) -> least_common_parent cx acc t) BotTyp a'

(* Updates Gamma and Psi *)
let rec check_acomm (cx: contexts) ((c, meta): acomm) : contexts * TypedAst.comm =
    check_comm (with_meta cx meta) c

(* Updates Gamma and Psi *)
and check_comm (cx: contexts) (c: comm) : contexts * TypedAst.comm =
    debug_print ">> check_comm";
    let check_incdec te x = let xt = snd (get_typ cx x) in
        if is_subtype cx xt IntTyp then te x TypedAst.IntTyp
        else if is_subtype cx xt FloatTyp then te x TypedAst.FloatTyp
        else error cx ("++ and -- must be applied to an integer or float")
    in
    match c with
    | Skip -> cx, TypedAst.Skip
    | Print e -> (
        let (e, t) = exp_to_texp cx (check_aexp cx e) in 
        match t with
        | UnitTyp -> error cx ("Print function cannot print void types")
        | _ -> cx, TypedAst.Print (e, t)
    )
    | Inc x -> cx,check_incdec (fun l r -> TypedAst.Inc (l, r)) x
    | Dec x -> cx,check_incdec (fun l r -> TypedAst.Dec (l, r)) x
    | Decl (ml, t, s, e) -> 
        (check_typ_valid cx t; 
        let result = check_aexp cx e in
        check_assign cx t s (snd result),
            TypedAst.Decl (typ_erase cx t, s, (exp_to_texp cx result)))
    | Assign (s, e) ->
        let t = snd (get_typ cx s) in
        let result = check_aexp cx e in
        check_assign cx t s (snd result), TypedAst.Assign (s, (exp_to_texp cx result))
    | AssignOp (s, b, e) -> 
        let cx', c' = check_acomm cx 
            (Assign (s, (Binop((Var s, snd e), b, e), cx.meta)), cx.meta) in
        (match c' with
        | TypedAst.Assign (_, (TypedAst.Binop ((_, st), _, e), _)) -> 
            cx', TypedAst.AssignOp((s, st), b, e)
        | _ -> failwith "Assign must return an assign?")
    | If ((b, c1), el, c2) ->
        let check_if b c =
            let er = (check_aexp cx b) in
            let _, cr = check_comm_lst cx c in
            (match snd er with 
            | BoolTyp -> ((exp_to_texp cx er), cr)
            | _ -> error cx ("Expected boolean expression for if condition"))
        in
        let c2r = (match c2 with | Some e -> Some (snd (check_comm_lst cx e)) | None -> None) in
        cx, TypedAst.If (check_if b c1, List.map (fun (b, c) -> check_if b c) el, c2r)
    | For (c1, b, c2, cl) ->
        let cx', c1r = check_acomm cx c1 in
        let br, brt = check_aexp cx' b in
        let btexp = exp_to_texp cx (br, brt) in
        let cx'', c2r = check_acomm cx' c2 in
        cx, TypedAst.For (c1r, btexp, c2r, (snd (check_comm_lst cx'' cl)))
    | Return e ->
        cx, TypedAst.Return(option_map (exp_to_texp cx |- check_aexp cx) e)
    | FnCall (x, pml, args) ->             
        let ((i, tpl, args_exp), _) = check_fn_inv cx x pml (List.map (check_aexp cx) args) in 
        cx, TypedAst.FnCall (i, tpl, args_exp)

(* Updates Gamma and Psi *)
and check_comm_lst (cx: contexts) (cl : acomm list) : contexts * TypedAst.comm list = 
    debug_print ">> check_comm_lst";
    match cl with
    | [] -> cx, []
    | h::t -> let cx', c' = check_acomm cx h in
        let cx'', cl' = check_comm_lst cx' t  in 
        cx'', c' :: cl'

(* Updates Gamma *)
and check_assign (cx: contexts) (t: typ) (s: string) (etyp : typ) : contexts =
    debug_print (">> check_assign <<"^s^">>");
    debug_print (string_of_typ t);
    (* Check that t, if not a core type, is a registered tag *)
    let rec check_tag (t: typ) : unit =
        match t with
        | ParTyp (s, pml) -> tau_lookup cx s pml |> ignore_typ; ()
        | _ -> ()
    in
    check_tag t;
    if is_subtype cx etyp t then bind cx s (Gamma t)
    else error cx ("Mismatched types for var decl for " ^ s ^
        ": expected " ^ (string_of_typ t) ^ ", found " ^ (string_of_typ etyp))

(* Updates Phi, and internal calls update gamma and psi *)
let check_fn_decl (cx: contexts) (ml, rt, id, pm, pl, meta: fn_typ) : 
contexts * TypedAst.params * TypedAst.parameterization =
    debug_print (">> check_fn_decl : " ^ id);
    check_parameterization cx pm;
    let _,pr = check_params cx pl in 
    check_typ_valid cx rt;
    let pme = Assoc.gen_context (List.map (fun (s, c) -> (s, constrain_erase cx c)) (Assoc.bindings pm)) in
    bind cx id (Phi (ml, rt, id, pm, pl, meta)), pr, pme

(* Helper function for type checking void functions. 
 * Functions that return void can have any number of void return statements 
 * anywhere. *)
let check_void_return (cx : contexts) (c: acomm) : unit =
    debug_print ">> check_void_return";
    match c with
    | (Return Some _, _) -> error cx ("Void functions cannot return a value")
    | _ -> ()

let check_return (cx: contexts) (t: typ) (c: acomm) : unit = 
    debug_print ">> check_return";
    match c with
    | (Return None, meta) -> error cx ("Expected a return value instead of void")
    | (Return Some r, meta) -> (
        let (_, rt) = check_aexp cx r in
        (* raises return exception of given boolean exp is false *)
        if is_subtype cx rt t then () 
        else error cx ("Mismatched return types, expected: " ^ 
        (string_of_typ t) ^ ", found: " ^ (string_of_typ rt))
        )
    | _ -> ()

(* Updates mu *)
let update_mu_with_function (cx: contexts) (fm, r, id, pmd, pr, meta : fn_typ) : contexts =
    let cx' = with_m cx (Assoc.update id fm cx.m) in
    if List.mem Canon fm then
        match pr with
        (* Only update if it is a canon function with exactly one argument *)
        | [(t,_)] ->
        begin
            if is_typ_eq cx' t r then error cx
                ("Canonical function " ^ id ^ " cannot be a map from a type to itself") else
            let fail _ = error cx
            ("Canonical functions must be between tag or abstract types") in
            match t with
            | ParTyp _ ->  
            begin
                match r with
                | ParTyp _ -> cx'
                | _ -> fail ()
            end
            | _ -> fail ()
        end
        | _ -> error cx ("Cannot have a canonical function with zero or more than one arguments")
    else cx

(* Updates Tau with new typing information *)
let check_typ_decl (cx: contexts) (x : string) (pm, t : tau) : contexts =
    debug_print ">> check_tag_decl";
    let rec check_valid_supertype (t: typ) : typ =
        match t with
        | ParTyp (s, pml) -> 
            let tpm,_ = get_typ cx s in
            let pmb = Assoc.bindings tpm in
            if List.length pmb == List.length pml
            then (List.fold_left2 (fun acc (s, c) t -> if is_subtype cx t c then () else
                error cx ("Invalid constraint used for parameterization of " ^ s))
                () (Assoc.bindings tpm) (List.map check_valid_supertype pml); t)
            else error cx ("Invalid number of parameters provided to parameterized type " ^ s)
        | _ -> error cx ("Invalid type for tag declaration " ^ string_of_typ t)
    in
    check_valid_supertype t |> ignore_typ;
    bind cx x (Tau (pm, t))

(* Updates gamma, mu, and phi from underlying calls *)
let check_decls (cx: contexts) (e : extern_element) : contexts =
    match e with
    | ExternFn f -> let (cx', _, _) = check_fn_decl cx f in 
        update_mu_with_function cx' f
    | ExternVar (ml, t, x, meta) -> bind cx x (Gamma t)

(* Type check global variable *)
(* Updates gamma *)
let check_global_variable (cx: contexts) (ml, sq, t, id, e: global_var) 
: contexts * TypedAst.global_var =
    debug_print ">> check_global_variable";
    let e' = option_map (fun x -> check_aexp cx x) e in
    check_typ_valid cx t; 
        bind cx id (Gamma t),
        (sq, typ_erase cx t, id, option_map (fun x -> exp_to_texp cx x) e')
        

(* Updates mu, phi, and psi from underlying calls *)
let check_fn (cx: contexts) (f, cl: fn) 
: contexts * TypedAst.fn = 
    let ml, r, id, pm, pr, meta = f in
    debug_print (">> check_fn : " ^ id);
    (* update phi with function declaration *)
    let cx', pr', pm' = check_fn_decl cx f in
    (* Note that we don't use our updated phi to avoid recursion *)
    let cx'', cl' = check_comm_lst cx' cl in
    let cxr = update_mu_with_function (clear cx'' CGamma) f in
    (* check that the last command is a return statement *)
    match r with
    | UnitTyp -> List.iter (fun c -> check_void_return cx c) cl;
        cxr, (((id, (pr', TypedAst.UnitTyp, pm')), cl'))
    (* TODO: might want to check that there is exactly one return statement at the end *)
    | t -> List.iter (check_return cx'' t) cl; 
        cxr, ((id, (pr', typ_erase cx t, pm')), cl')

let check_term (cx: contexts) (t: term) 
: contexts * TypedAst.fn option * TypedAst.global_var option =
    match t with    
    | Prototype p -> failwith ""
    | Coordinate c -> failwith ""
    | Frame t -> failwith ""
    | Typ (id, pm, t) ->
        check_typ_decl cx id (pm, t), None, None
    | Extern e -> let cx' = check_decls cx e in
        cx', None, None
    | GlobalVar gv -> let (cx', gv') = check_global_variable cx gv in
        cx', None, Some gv'
    | Fn f -> let (cx', f') = check_fn cx f in
        cx', Some f', None
    
let check_aterm (cx: contexts) ((t, meta): aterm) 
: contexts * TypedAst.fn option * TypedAst.global_var option =
    check_term (with_meta cx meta) t

let rec check_term_list (tl: aterm list) :
contexts * TypedAst.prog * TypedAst.global_vars =
    debug_print ">> check_global_var_or_fn_lst";
    (* Annoying bootstrapping hack *)
    let app_maybe o l = match o with | Some v -> v::l | None -> l in
    let cx, f, gv = List.fold_left (fun acc t -> let (cx', f', gv') = check_aterm (tr_fst acc) t in
        (cx', app_maybe f' (tr_snd acc), app_maybe gv' (tr_thd acc)))
        (init (snd (List.hd tl)), [], []) tl in
    cx, List.rev f, List.rev gv

(* Check that there is a void main() defined *)
let check_main_fn (cx: contexts) : unit =
    debug_print ">> check_main_fn";
    let (ml, rt, id, pm, pr, meta) = get_function cx "main" in 
    debug_print (">> check_main_fn_2" ^ (string_of_list string_of_param pr) ^ (string_of_parameterization pm));
    if (List.length pr) > 0 || (Assoc.size pm) > 0 then error cx ("Cannot provide parameters to main") else
    match rt with
        | UnitTyp -> ()
        | _ -> raise (TypeException "Expected main function to return void")

(* Returns the list of fn's which represent the program 
 * and params of the void main() fn *)
let check_prog (tl: prog) : TypedAst.prog * TypedAst.global_vars =
    debug_print ">> check_prog";
    let cx, typed_prog, typed_gvs = check_term_list tl in
    check_main_fn cx;
    debug_print "===================";
    debug_print "Type Check Complete";
    debug_print "===================\n";
    typed_prog, typed_gvs
    