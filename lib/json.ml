(*
 * Copyright (C) 2010 Thomas Gazagnaire <thomas@gazagnaire.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)

open Value

let rec list_iter_between f o = function
    | []   -> ()
    | [h]  -> f h
    | h::t -> f h; o (); list_iter_between f o t

let escape_string s =
    let buf = Buffer.create 80 in
    Buffer.add_string buf "\"";
    for i = 0 to String.length s - 1
    do
        let x =
            match s.[i] with
            | '\n'   -> "\\n"
            | '\t'   -> "\\t"
            | '\r'   -> "\\r"
            | '\b'   -> "\\b"
            | '\\'   -> "\\\\"
            | '/'    -> "\\/"
            | '"'    -> "\\\""
            | '\x0c' -> "\\f"
            | c      -> String.make 1 c
            in
        Buffer.add_string buf x
    done;
    Buffer.add_string buf "\"";
    Buffer.contents buf

let rec to_fct t f =
    match t with
    | Unit     -> f "null"
    | Int i    -> f (Printf.sprintf "%Ld" i)
    | Bool b   -> f (string_of_bool b)
    | Float r  -> f (Printf.sprintf "%f" r)
    | String s -> f (escape_string s)
    | Enum ( (Tuple [String _;_] :: _) as a )->
        to_fct (Dict (List.map 
          (function 
           | Tuple [String k; v] -> (k, v)
           | _ -> assert false
        ) a)) f
    | Enum a   ->
        f "[";
        list_iter_between (fun i -> to_fct i f) (fun () -> f ", ") a;
        f "]"
    | Tuple a  ->
        to_fct (Enum a) f
    | Dict a   ->
        f "{";
        list_iter_between (fun (k, v) -> to_fct (String k) f; f ": "; to_fct v f)
                          (fun () -> f ", ") a;
        f "}"
    | Sum (v, []) ->
        to_fct (String v) f
    | Sum (v, args) ->
        to_fct (Enum (String v :: args)) f 
    | Null     -> f "null"
    | Value t  -> to_fct t f
    | Arrow t  -> failwith "Marshalling of functional values is not (yet) supported"
    | Rec ((v,i), t)
    | Ext ((v,i), t) ->
        to_fct t f
    | Var (v,i) ->
        to_fct (Dict [ ("type", String v); ("id", Int i) ]) f

(* given a type and a string, return well-formed Value *)
let rec of_typed_value = function
    | Type.Unit, v
    | Type.Bool, v 
    | Type.Char, v
    | Type.String, v
    | Type.Int _, v -> v
    | Type.Float, Value.String v ->
       Value.Float (float_of_string v)
    | Type.Float, v -> v
    | Type.Enum (Type.Tuple [Type.String; ty']), Dict vl ->
       Enum (List.map (fun (k,v) -> Tuple [String k; (of_typed_value (ty',v)) ]) vl)
    | Type.Enum ty', (Enum l) ->
       Enum (List.map (fun v -> of_typed_value (ty',v)) l)
    | Type.Tuple tyl, Enum l ->
       Tuple (List.map2 (fun ty' v -> of_typed_value (ty',v)) tyl l)
    | Type.Dict tyl, Dict vl ->
       (* need to cope with out of order dictionary entries here *)
       let d = List.fold_left (fun a (k,v) ->
           let _,_,ty = List.find (fun (n,_,_) -> n = k) tyl in
           let v' = of_typed_value (ty,v) in
           (k,v') :: a
         ) [] vl in
       Dict d
    | Type.Sum tyl, String v ->
       Sum (v,[])
    | Type.Sum tyl, Enum (String v :: args) ->
       let tyl' = List.assoc v tyl in
       Sum( v, (List.map2 (fun ty' va' -> of_typed_value (ty', va')) tyl' args))
    | Type.Option ty', Null -> Null
    | Type.Option ty', v -> Value (of_typed_value (ty',v))
    | Type.Rec (id,ty'), v -> 
       Rec ((id, 0L), (of_typed_value (ty',v)))
    | Type.Ext (id,ty'), v -> 
       Ext ((id, 0L), (of_typed_value (ty',v)))
    | Type.Var id, (Dict [ ("type", String _); ("id", Int i) ]) ->
          Var (id, i)
    | Type.Arrow _,_ -> failwith "Unmarshalling of functional values not yet implemented"
    | ty,v -> failwith (Printf.sprintf "of_typed_value: unknown type=%s value=%s" 
                (Type.to_string ty) (Value.to_string v))

let to_buffer t buf =
    to_fct t (fun s -> Buffer.add_string buf s)

let to_string t =
    let buf = Buffer.create 2048 in
    to_buffer t buf;
    Buffer.contents buf

type error =
    | Unexpected_char of int * char * (* json type *) string
    | Invalid_value of int * (* value *) string * (* json type *) string
    | Invalid_leading_zero of int * string
    | Unterminated_value of int * string
    | Internal_error of int * string

exception Parse_error of error

module Parser = struct

    type cursor =
        | Start
        | Expect_value
        | In_null of int
        | In_true of int
        | In_false of int
        | In_int of char list
        | In_float of char list * char list
        | In_int_exp of char list * char list
        | In_float_exp of char list * char list * char list
        | In_string of char list
        | In_string_control of char list
        | In_string_hex of char list * char list * int
        | Expect_object_elem_start
        | Expect_object_elem_colon
        | Expect_comma_or_end
        | Expect_object_key
        | Done of t

    type int_value =
        | IObject of (string * t) list
        | IObject_needs_key of (string * t) list
        | IObject_needs_value of (string * t) list * string
        | IArray of t list

    type parse_state = {
        mutable cursor: cursor;
        mutable stack: int_value list;
        mutable num_chars_parsed: int;
        mutable line_num: int
    }

    let init_parse_state () = {
        cursor = Start;
        stack = [];
        num_chars_parsed = 0;
        line_num = 1
    }

    let is_parsing_object s =
        match s.stack with
        | IObject _ :: _ | IObject_needs_key _ :: _ | IObject_needs_value _ :: _ -> true
        | IArray _ :: _
        | [] -> false

    let get_parse_result s =
        match s.cursor with
        | Done v -> Some v
        | _ -> None

    let ivalue_to_str = function
        | IObject _ -> "object"
        | IObject_needs_key _ -> "object_needing_key"
        | IObject_needs_value _ -> "object_needing_value"
        | IArray _ -> "array"

    let current_cursor_value = function
        | Start    | Expect_value -> "value"
        | In_null _ -> "null"
        | In_true _ | In_false _ -> "boolean"
        | In_int _ | In_float _ | In_int_exp _ | In_float_exp _     -> "number"
        | In_string _ | In_string_control _ | In_string_hex _ -> "string"
        | Expect_object_elem_start | Expect_object_elem_colon | Expect_object_key -> "object"
        | Expect_comma_or_end -> "object/array"
        | Done _ -> ""

    let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r'

    let update_line_num s c =
        if c = '\n' then
            s.line_num <- s.line_num + 1

    let is_hex_char = function
        | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
        | _ -> false

    let is_valid_unescaped_char c =
        match c with
            | '"' | '\\' | '\b' | '\x0c' | '\n' | '\r' | '\t' -> false
            | _ -> true

    let clist_to_string cs =
        let len = List.length cs in
        let s = String.create len in
        let rec iter indx = function
            | c :: cs ->
                  String.set s indx c;
                  iter (indx + 1) cs
            | [] -> () in
        iter 0 cs;
        s

    let string_of_error = function
        | Unexpected_char (l, c, state) ->
              Printf.sprintf "Line %d: Unexpected char %C (x%X) encountered in state %s"
                  l c (Char.code c) state
        | Invalid_value (l, v, t) ->
              Printf.sprintf "Line %d: '%s' is an invalid %s" l v t
        | Invalid_leading_zero (l, s) ->
              Printf.sprintf "Line %d: '%s' should not have leading zeros" l s
        | Unterminated_value (l, s) ->
              Printf.sprintf "Line %d: unterminated %s" l s
        | Internal_error (l, m) ->
              Printf.sprintf "Line %d: Internal error: %s" l m

    let raise_unexpected_char s c t =
        raise (Parse_error (Unexpected_char (s.line_num, c, t)))
    let raise_invalid_value s v t =
        raise (Parse_error (Invalid_value (s.line_num, v, t)))
    let raise_invalid_leading_zero s n =
        raise (Parse_error (Invalid_leading_zero (s.line_num, n)))
    let raise_unterminated_value s v =
        raise (Parse_error (Unterminated_value (s.line_num, v)))
    let raise_internal_error s m =
        raise (Parse_error (Internal_error (s.line_num, m)))

    let finish_value s v =
        match s.stack, v with
        | [], _ -> s.cursor <- Done v
        | IObject_needs_key fields :: tl, String key ->
            s.stack <- IObject_needs_value (fields, key) :: tl;
            s.cursor <- Expect_object_elem_colon
        | IObject_needs_value (fields, key) :: tl, _ ->
            s.stack <- IObject ((key, v) :: fields) :: tl;
            s.cursor <- Expect_comma_or_end
        | IArray l :: tl, _ ->
            s.stack <- IArray (v :: l) :: tl;
            s.cursor <- Expect_comma_or_end
        | io :: tl, _ ->
            raise_internal_error s ("unexpected " ^ (ivalue_to_str io) ^ " on stack at finish_value")

    let pop_stack s =
        match s.stack with
        | IObject fields :: tl -> s.stack <- tl; finish_value s (Dict (List.rev fields))
        | IArray l :: tl       -> s.stack <- tl; finish_value s (Enum (List.rev l))
        | io :: tl             -> raise_internal_error s ("unexpected " ^ (ivalue_to_str io) ^ " on stack at pop_stack")
        | []                   -> raise_internal_error s "empty stack at pop_stack"

    let rec parse_char s c =
        (* Printf.printf "parsing %C at line %d in state %s...\n" c s.line_num (current_cursor_value s.cursor); *)
        let tostring_with_leading_zero_check is =
            let ris = List.rev is in
            let check = function
                | [] | [ '0' ] -> ()
                | '0' :: tl when List.length tl > 0 ->
                      raise_invalid_leading_zero s (clist_to_string ris)
                | _ -> () in
            check ris;
            clist_to_string ris in
        let finish_int is =
            let str = tostring_with_leading_zero_check is in
            let int = try Int64.of_string str
            with Failure _ -> raise_invalid_value s str "int" in
            finish_value s (Int int) in
        let finish_int_exp is es =
            let int = tostring_with_leading_zero_check is in
            let exp = clist_to_string (List.rev es) in
            let str = Printf.sprintf "%s.e%s" int exp in
            (* If exp is positive, we might actually
               succeed in making this an int, but
               returning float is more uniform. *)
            let float = try float_of_string str
            with Failure _ -> raise_invalid_value s str "float" in
            finish_value s (Float float) in
        let finish_float is fs =
            let int = tostring_with_leading_zero_check is in
            let frac = clist_to_string (List.rev fs) in
            let str = Printf.sprintf "%s.%s" int frac in
            let float = try float_of_string str
            with Failure _ -> raise_invalid_value s str "float" in
            finish_value s (Float float) in
        let finish_float_exp is fs es =
            let int = tostring_with_leading_zero_check is in
            let frac = clist_to_string (List.rev fs) in
            let exp = clist_to_string (List.rev es) in
            let str = Printf.sprintf "%s.%se%s" int frac exp in
            let float = try float_of_string str
            with Failure _ -> raise_invalid_value s str "float" in
            finish_value s (Float float) in

        match s.cursor with
        | Start ->
            (match c with
            | 'n' -> s.cursor <- In_null 3
            | 't' -> s.cursor <- In_true 3
            | 'f' -> s.cursor <- In_false 4
            | '-' | '0' .. '9' -> s.cursor <- In_int [c]
            | '"' -> s.cursor <- In_string []
            | '{' -> s.cursor <- Expect_object_elem_start
            | '[' -> s.stack <- (IArray []) :: s.stack
            | ']' when s.stack <> [] -> pop_stack s
            | _ when is_space c -> update_line_num s c
            | _ -> raise_unexpected_char s c "start")

        | Expect_value ->
            (match c with
            | 'n' -> s.cursor <- In_null 3
            | 't' -> s.cursor <- In_true 3
            | 'f' -> s.cursor <- In_false 4
            | '-' | '0' .. '9' -> s.cursor <- In_int [c]
            | '"' -> s.cursor <- In_string []
            | '{' -> s.cursor <- Expect_object_elem_start
            | '[' -> s.stack <- (IArray []) :: s.stack; s.cursor <- Start
            | _ when is_space c -> update_line_num s c
            | _ -> raise_unexpected_char s c "value")
            
        | In_null rem ->
            (match c, rem with
            | 'u', 3 -> s.cursor <- In_null 2
            | 'l', 2 -> s.cursor <- In_null 1
            | 'l', 1 -> finish_value s Null
            | _ -> raise_unexpected_char s c "null")

        | In_true rem ->
            (match c, rem with
            | 'r', 3 -> s.cursor <- In_true 2
            | 'u', 2 -> s.cursor <- In_true 1
            | 'e', 1 -> finish_value s (Bool true)
            | _ -> raise_unexpected_char s c "true")

        | In_false rem ->
            (match c, rem with
            | 'a', 4 -> s.cursor <- In_false 3
            | 'l', 3 -> s.cursor <- In_false 2
            | 's', 2 -> s.cursor <- In_false 1
            | 'e', 1 -> finish_value s (Bool false)
            | _ -> raise_unexpected_char s c "false")

        | In_int is ->
            (match c with
            | '0' .. '9' -> s.cursor <- In_int (c :: is)
            | '.' -> s.cursor <- In_float (is, [])
            | 'e' | 'E' -> s.cursor <- In_int_exp (is, [])
            | ',' | ']' | '}' -> finish_int is; parse_char s c
            | _ when is_space c -> update_line_num s c; finish_int is
            | _ -> raise_unexpected_char s c "int")
        
        | In_float (is, fs) ->
            (match c with
            | '0' .. '9' -> s.cursor <- In_float (is, c :: fs)
            | 'e' | 'E' -> s.cursor <- In_float_exp (is, fs, [])
            | ',' | ']' | '}' -> finish_float is fs; parse_char s c
            | _ when is_space c -> update_line_num s c; finish_float is fs
            | _ -> raise_unexpected_char s c "float")

        | In_int_exp (is, es) ->
            (match c with
            | '+' | '-' | '0' .. '9' -> s.cursor <- In_int_exp (is, c :: es)
            | ',' | ']' | '}' -> finish_int_exp is es; parse_char s c
            | _ when is_space c -> update_line_num s c; finish_int_exp is es
            | _ -> raise_unexpected_char s c "int_exp")
        
        | In_float_exp (is, fs, es) ->
            (match c with
            | '+' | '-' | '0' .. '9' -> s.cursor <- In_float_exp (is, fs, c :: es)
            | ',' | ']' | '}' -> finish_float_exp is fs es; parse_char s c
            | _ when is_space c -> update_line_num s c; finish_float_exp is fs es
            | _ -> raise_unexpected_char s c "float_exp")

        | In_string cs ->
            (match c with
            | '\\' -> s.cursor <- In_string_control cs
            | '"' -> finish_value s (String (clist_to_string (List.rev cs)))
            | _ when is_valid_unescaped_char c -> s.cursor <- In_string (c :: cs)
            | _ ->  raise_unexpected_char s c "string")
            
        | In_string_control cs ->
            (match c with
            | '"' | '\\' | '/' -> s.cursor <- In_string (c :: cs)
            | 'b' -> s.cursor <- In_string ('\b' :: cs)
            | 'f' -> s.cursor <- In_string ('\x0c' :: cs)
            | 'n' -> s.cursor <- In_string ('\n' :: cs)
            | 'r' -> s.cursor <- In_string ('\r' :: cs)
            | 't' -> s.cursor <- In_string ('\t' :: cs)
            | 'u' -> s.cursor <- In_string_hex (cs, [], 4)
            | _ -> raise_unexpected_char s c "string_control")
        
        | In_string_hex (cs, hs, rem) ->
            if is_hex_char c then begin
            let hs = c :: hs in
            if rem > 1 then
                s.cursor <- In_string_hex (cs, hs, rem - 1)
            else
                (* TODO: We currently just leave the unicode escapes in place. *)
                s.cursor <- In_string (hs @ ('u' :: '\\' :: cs))
            end else
                raise_unexpected_char s c "string_unicode"

        | Expect_object_elem_start ->
            (match c with
            | '"' -> s.stack <- (IObject_needs_key []) :: s.stack; s.cursor <- In_string []
            | '}' -> finish_value s (Dict [])
            | _ when is_space c -> update_line_num s c
            | _ -> raise_unexpected_char s c "object_start")

        | Expect_object_elem_colon ->
            (match c with
            | ':' -> s.cursor <- Start
            | _ when is_space c -> update_line_num s c
            | _ -> raise_unexpected_char s c "object_elem_colon")

        | Expect_comma_or_end ->
            (match c with
            | ',' when is_parsing_object s -> s.cursor <- Expect_object_key
            | ',' -> s.cursor <- Expect_value
            | '}' when is_parsing_object s -> pop_stack s
            | '}' -> raise_unexpected_char s c "comma_or_end"
            | ']' when not (is_parsing_object s) -> pop_stack s
            | ']' -> raise_unexpected_char s c "comma_or_end"
            | _ when is_space c -> update_line_num s c
            | _ -> raise_unexpected_char s c "comma_or_end")

        | Expect_object_key ->
            (match c with
            | '"' ->
                (match s.stack with
                | IObject fields :: tl -> s.stack <- IObject_needs_key fields :: tl
                | io :: _ -> raise_internal_error s ("unexpected " ^ (ivalue_to_str io) ^ " on stack at object_key")
                | [] -> raise_internal_error s "empty stack at object_key");
                s.cursor <- In_string []
            | _ when is_space c -> update_line_num s c
            | _ -> raise_unexpected_char s c "object_key")

        | Done _ -> raise_internal_error s "parse called when parse_state is 'Done'"

    type parse_result =
        | Json_value of t
        | Json_parse_incomplete of parse_state

    let parse state str =
        begin try
            while get_parse_result state = None do
                parse_char state (str ());
                (* This is here instead of inside parse_char since
                   parse_char makes (tail-)recursive calls without
                   consuming a character.
                *)
                state.num_chars_parsed <- state.num_chars_parsed + 1;
            done;
        with _ -> () end;
        match get_parse_result state with
        | Some v -> Json_value v
        | None -> Json_parse_incomplete state

    (* This is really only required for numbers, since they are only
       terminated by whitespace, but end-of-file or end-of-connection
       qualifies as whitespace.

       The parser might also be just eating whitespace, expecting the
       start of a json value.
    *)
    let finish_parse state =
        match parse state (fun () -> ' ') with
        | Json_value v -> Some v
        | Json_parse_incomplete _ ->
            if state.cursor = Start then None
            else raise_unterminated_value state (current_cursor_value state.cursor)

    let num_chars_parsed state = state.num_chars_parsed

    let of_stream str =
        match parse (init_parse_state ()) str with
        | Json_value v -> v
        | Json_parse_incomplete st ->
            match finish_parse st with
            | Some v -> v
            | None -> raise_unterminated_value st (current_cursor_value st.cursor)

    let of_string str =
        let i = ref (-1) in
        let next () =
            incr i;
            str.[ !i ] in
        of_stream next
end

let of_string ty s = of_typed_value (ty, Parser.of_string s)

