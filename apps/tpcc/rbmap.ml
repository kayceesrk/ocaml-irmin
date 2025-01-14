(*-
 * Copyright (c) 2007, Benedikt Meurer <benedikt.meurer@googlemail.com>
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
 * IN THE SOFTWARE.
 *)

(* This is my implementation of Red-Black Trees for OCaml. It is based upon
 * "Red-Black Trees in a Functional Setting", Chris Okasaki in "Functional
 * Pearls".
 * Red-Black Trees are exposed via a map and a set API, which is designed to
 * be compatible with the Map and Set modules in the OCaml standard library
 * (which are implemented using AVL trees). You can use the Rbmap and Rbset
 * modules as drop-in replacement for the Map and Set modules.
 *)

module type KEY =
  sig
    type t
    val t: t Irmin.Type.t
    val compare: t -> t -> int
    val to_string : t -> string
  end

module type VALUE = 
  sig
    type t
    val merge: ancestor:t -> t -> t -> t
  end

module type S =
  sig
    type key
    type value
    type t =
      | Black of t * key * value * t
      | Red of t * key * value * t
      | Empty
    val empty: t
    val is_empty: t -> bool
    val add: key -> value -> t -> t
    val insert: key -> value -> t -> t
    val find: key -> t -> value
    val remove: key -> t -> t
    val mem:  key -> t -> bool
    val iter: (key -> value -> unit) -> t -> unit
    val map: (value -> value) -> t -> t
    val mapi: (key -> value -> value) -> t -> t
    val fold: (key -> value -> value -> value) -> t -> value -> value
    val compare: (value -> value -> int) -> t -> t -> int
    val equal: (value -> value -> bool) -> t -> t -> bool
    val update : (key -> int) -> (value -> value) -> t -> t
    val select: (key -> int) -> t -> value list
  end

module Make(K:KEY)(V:VALUE) : S with type key=K.t and type value=V.t =
struct
  type key = K.t

  type value = V.t

  type t =
    | Black of t * key * value * t
    | Red of t * key * value * t
    | Empty

  type enum =
    | End
    | More of key * value * t * enum

  let rec enum m e =
    match m with
      | Empty -> e
      | Black(l, k, x, r) | Red(l, k, x, r) -> enum l (More(k, x, r, e))

  let blackify = function
    | Red(l, k, x, r) -> Black(l, k, x, r), false
    | m -> m, true

  let empty = Empty

  let is_empty = function
    | Empty -> true
    | _ -> false

  let balance_left l kx x r =
    match l, kx, x, r with
      | Red(Red(a, kx, x, b), ky, y, c), kz, z, d
      | Red(a, kx, x, Red(b, ky, y, c)), kz, z, d ->
          Red(Black(a, kx, x, b), ky, y, Black(c, kz, z, d))
      | l, kx, x, r ->
          Black(l, kx, x, r)

  let balance_right l kx x r =
    match l, kx, x, r with
      | a, kx, x, Red(Red(b, ky, y, c), kz, z, d)
      | a, kx, x, Red(b, ky, y, Red(c, kz, z, d)) ->
          Red(Black(a, kx, x, b), ky, y, Black(c, kz, z, d))
      | l, kx, x, r ->
          Black(l, kx, x, r)

  let add kx x m =
    let rec add_aux = function
      | Empty ->
          Red(Empty, kx, x, Empty)
      | Red(l, ky, y, r) ->
          let c = K.compare kx ky in
            if c < 0 then
              Red(add_aux l, ky, y, r)
            else if c > 0 then
              Red(l, ky, y, add_aux r)
            else
              Red(l, kx, x, r)
      | Black(l, ky, y, r) ->
          let c = K.compare kx ky in
            if c < 0 then
              balance_left (add_aux l) ky y r
            else if c > 0 then
              balance_right l ky y (add_aux r)
            else
              Black(l, kx, x, r)
    in fst (blackify (add_aux m))

  let insert = add

  let rec find k = function
    | Empty ->
        raise Not_found
    | Red(l, kx, x, r)
    | Black(l, kx, x, r) ->
        let c = K.compare k kx in
          if c < 0 then 
            ((*Printf.printf "%s < %s\n" (K.to_string k) 
               (K.to_string kx);*) find k l)
          else if c > 0 then 
            ((*Printf.printf "%s > %s\n" (K.to_string k) 
               (K.to_string kx);*) find k r)
          else x

  let unbalanced_left = function
    | Red(Black(a, kx, x, b), ky, y, c) ->
        balance_left (Red(a, kx, x, b)) ky y c, false
    | Black(Black(a, kx, x, b), ky, y, c) ->
        balance_left (Red(a, kx, x, b)) ky  y c, true
    | Black(Red(a, kx, x, Black(b, ky, y, c)), kz, z, d) ->
        Black(a, kx, x, balance_left (Red(b, ky, y, c)) kz z d), false
    | _ ->
        assert false

  let unbalanced_right = function
    | Red(a, kx, x, Black(b, ky, y, c)) ->
        balance_right a kx x (Red(b, ky, y, c)), false
    | Black(a, kx, x, Black(b, ky, y, c)) ->
        balance_right a kx x (Red(b, ky, y, c)), true
    | Black(a, kx, x, Red(Black(b, ky, y, c), kz, z, d)) ->
        Black(balance_right a kx x (Red(b, ky, y, c)), kz, z, d), false
    | _ ->
        assert false

  let rec remove_min = function
    | Empty
    | Black(Empty, _, _, Black(_)) ->
        assert false
    | Black(Empty, kx, x, Empty) ->
        Empty, kx, x, true
    | Black(Empty, kx, x, Red(l, ky, y, r)) ->
        Black(l, ky, y, r), kx, x, false
    | Red(Empty, kx, x, r) ->
        r, kx, x, false
    | Black(l, kx, x, r) ->
        let l, ky, y, d = remove_min l in
        let m = Black(l, kx, x, r) in
          if d then
            let m, d = unbalanced_right m in m, ky, y, d
          else
            m, ky, y, false
    | Red(l, kx, x, r) ->
        let l, ky, y, d = remove_min l in
        let m = Red(l, kx, x, r) in
          if d then
            let m, d = unbalanced_right m in m, ky, y, d
          else
            m, ky, y, false

  let remove k m =
    let rec remove_aux = function
      | Empty ->
          Empty, false
      | Black(l, kx, x, r) ->
          let c = K.compare k kx in
            if c < 0 then
              let l, d = remove_aux l in
              let m = Black(l, kx, x, r) in
                if d then unbalanced_right m else m, false
            else if c > 0 then
              let r, d = remove_aux r in
              let m = Black(l, kx, x, r) in
                if d then unbalanced_left m else m, false
            else
              begin match r with
                | Empty ->
                    blackify l
                | _ ->
                    let r, kx, x, d = remove_min r in
                    let m = Black(l, kx, x, r) in
                      if d then unbalanced_left m else m, false
              end
      | Red(l, kx, x, r) ->
          let c = K.compare k kx in
            if c < 0 then
              let l, d = remove_aux l in
              let m = Red(l, kx, x, r) in
                if d then unbalanced_right m else m, false
            else if c > 0 then
              let r, d = remove_aux r in
              let m = Red(l, kx, x, r) in
                if d then unbalanced_left m else m, false
            else
              begin match r with
                | Empty ->
                    l, false
                | _ ->
                    let r, kx, x, d = remove_min r in
                    let m = Red(l, kx, x, r) in
                      if d then unbalanced_left m else m, false
              end
    in fst (remove_aux m)

  let rec mem k = function
    | Empty ->
        false
    | Red(l, kx, x, r)
    | Black(l, kx, x, r) ->
        let c = K.compare k kx in
          if c < 0 then mem k l
          else if c > 0 then mem k r
          else true

  let rec iter f = function
    | Empty -> ()
    | Red(l, k, x, r) | Black(l, k, x, r) -> iter f l; f k x; iter f r

  let rec map f = function
    | Empty -> Empty
    | Red(l, k, x, r) -> Red(map f l, k, f x, map f r)
    | Black(l, k, x, r) -> Black(map f l, k, f x, map f r)

  let rec mapi f = function
    | Empty -> Empty
    | Red(l, k, x, r) -> Red(mapi f l, k, f k x, mapi f r)
    | Black(l, k, x, r) -> Black(mapi f l, k, f k x, mapi f r)

  let rec fold f m accu =
    match m with
      | Empty -> accu
      | Red(l, k, x, r) | Black(l, k, x, r) -> fold f r (f k x (fold f l accu))

  let compare cmp m1 m2 =
    let rec compare_aux e1 e2 =
      match e1, e2 with
        | End, End ->
            0
        | End, _ ->
            -1
        | _, End ->
            1
        | More(k1, x1, r1, e1), More(k2, x2, r2, e2) ->
            let c = K.compare k1 k2 in
              if c <> 0 then c
              else
                let c = cmp x1 x2 in
                  if c <> 0 then c
                  else compare_aux (enum r1 e1) (enum r2 e2)
    in compare_aux (enum m1 End) (enum m2 End)

  let equal cmp m1 m2 =
    let rec equal_aux e1 e2 =
      match e1, e2 with
        | End, End ->
            true
        | End, _
        | _, End ->
            false
        | More(k1, x1, r1, e1), More(k2, x2, r2, e2) ->
            (K.compare k1 k2 = 0
                && cmp x1 x2
                && equal_aux (enum r1 e1) (enum r2 e2))
    in equal_aux (enum m1 End) (enum m2 End)

  let rec update sigf updf t = match t with
    | Empty -> Empty
    | Red(l, k, v, r) 
      when sigf k > 0 -> Red(update sigf updf l, k, v, r)
    | Black(l, k, v, r) 
      when sigf k > 0 -> Black(update sigf updf l, k, v, r)
    | Red(l, k, v, r) 
      when sigf k < 0 -> Red(l, k, v, update sigf updf r)
    | Black(l, k, v, r) 
      when sigf k < 0 -> Black(l, k, v, update sigf updf r)
    | Red(l, k, v, r) 
      when sigf k = 0 -> Red(update sigf updf l, 
                             k, updf v,
                             update sigf updf r)
    | Black(l, k, v, r) 
      when sigf k = 0 -> Black(update sigf updf l, 
                               k, updf v,
                               update sigf updf r)
    | _ -> failwith "Rbmap.update.exhaustiveness"

  let rec select sigf t = match t with
    | Empty -> []
    | Red(l, k, v, r) | Black(l, k, v, r) 
      when sigf k > 0 -> select sigf l
    | Red(l, k, v, r) | Black(l, k, v, r) 
      when sigf k < 0 -> select sigf r
    | Red(l, k, v, r) 
      when sigf k = 0 -> (select sigf l)@(v::(select sigf r))
    | Black(l, k, v, r) 
      when sigf k = 0 -> (select sigf l)@(v::(select sigf r))
    | _ -> failwith "Rbmap.select.exhaustiveness"
end
