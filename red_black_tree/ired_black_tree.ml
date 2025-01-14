open Lwt.Infix
open Irmin_unix

(* Config module has three functions root, shared and init. *)
module type Config = sig
  val root: string
  val shared: string
  val init: unit -> unit
end

(* MakeVersioned is a functor which takes Config and Atom as arguments *)
module MakeVersioned (Config: Config) (Atom: Red_black_tree_imp.ATOM)= struct
  module OM = Red_black_tree_imp.Make(Atom)
  module K = Irmin.Hash.SHA1


let from_just = function (Some x) -> x 
  | None -> failwith "Expected Some. Got None."

type vcolor = R | B
type vnode = {cl: vcolor; l:K.t; v:OM.atom; r:K.t}
 type vt = 
    | E
    | T of vnode

 module M = struct
    module AO_value = struct
      type t = vt

      let vc = 
       let open Irmin.Type in 
       variant "vc" (fun r b -> function 
          | R -> r
          | B -> b)
        |~ case0 "R" R
        |~ case0 "B" B
        |> sealv

      let node = 
        let open Irmin.Type in
        record "node" (fun cl l v r -> {cl;l;v;r})
        |+ field "cl" vc (fun t -> t.cl)
        |+ field "l" K.t (fun t -> t.l)
        |+ field "v" Atom.t (fun t -> t.v)
        |+ field "r" K.t (fun t -> t.r)
        |> sealr


      let t =
        let open Irmin.Type in
        variant "t" (fun empty node -> function
            | E -> empty
            | T n -> node n)
        |~ case0 "E" E
        |~ case1 "T" node (fun x -> T x)
        |> sealv

      let pp = Irmin.Type.dump t


     let of_string s =
        let decoder = Jsonm.decoder (`String s) in
        Irmin.Type.decode_json t decoder

  end

  module AO_store = struct
      (* Immutable collection of all versionedt *)
      module S = Irmin_git.AO(Git_unix.FS)(AO_value)
      include S

      let create config =
        let level = Irmin.Private.Conf.key ~doc:"The Zlib compression level."
            "level" Irmin.Private.Conf.(some int) None
        in
        let root = Irmin.Private.Conf.get config Irmin.Private.Conf.root in
        let level = Irmin.Private.Conf.get config level in
        Git_unix.FS.create ?root ?level ()

      (* Somehow pulls the config set by Store.init *)
      (* And creates a Git backend *)
      let create () = create @@ Irmin_git.config Config.shared
    end

    type t = K.t

    let of_vc (a : OM.color) : vcolor = 
      match a with 
      | OM.R -> R
      | OM.B -> B

    let to_vc (a : vcolor) : OM.color = 
      match a with 
      | R -> OM.R
      | B -> OM.B

    (*let rec of_vc (a: OM.color) : vcolor Lwt.t =
     let aostore = AO_store.create () in
      let aostore_add value =
        aostore >>= (fun ao_store -> AO_store.add ao_store value) in
        aostore_add =<< 
         (match a with 
           | OM.R -> Lwt.return @@ R
           | OM.B -> Lwt.return @@ B)*)

    let rec of_adt (a:OM.t) : t Lwt.t  =
      let aostore = AO_store.create () in
      let aostore_add value =
        aostore >>= (fun ao_store -> AO_store.add ao_store value) in
      aostore_add =<<
      (match a with
       | OM.E -> Lwt.return @@ E
       | OM.T {cl=co;l;v;r} -> 
         (of_adt l >>= fun l' ->
          of_adt r >>= fun r' ->
          Lwt.return {cl=of_vc co;l=l'; v; r=r'})
         >>= ((fun n -> Lwt.return @@ (T n))))
    
    (* returns the basic OCaml data type *)
    (* for the key k we find the data stored with that key using the function find *)
    (* Then t is matched with type defined in the AO_value *)
    let rec to_adt (k:t) : OM.t Lwt.t =
      AO_store.create () >>= fun ao_store ->
      AO_store.find ao_store k >>= fun t ->
      let t = from_just t in
      (match t with
      | E -> Lwt.return @@ OM.E
      | T {cl=co;l;v;r} ->
        (to_adt l >>= fun l' ->
         to_adt r >>= fun r' ->
         Lwt.return {cl=to_vc co;OM.l=l'; OM.v; OM.r=r'})
        >>= ((fun n -> Lwt.return @@ (OM.T n))))

    let t = K.t

    let pp = K.pp

    let of_string = K.of_string
 
    (* merge function merges old, v1_k and v2_k *)
    (* Irmin.Merge.promise t is a promise containing a value of type t *)
    (* using the to_adt, old_k, v1_k and v2_k is converted to the OCaml data type *)
    let rec merge ~(old:t Irmin.Merge.promise) v1_k v2_k =
      let open Irmin.Merge.Infix in
      old () >>=* fun old_k ->
      let old_k = from_just old_k in
      to_adt old_k >>= fun oldv  ->
      to_adt v1_k >>= fun v1  ->
      to_adt v2_k >>= fun v2 ->
      let v = OM.merge3 oldv v1 v2 in
      of_adt v >>= fun merged_k ->
      Irmin.Merge.ok merged_k

    let merge = Irmin.Merge.(option (v t merge))
  end

  (* Store is defined as follows which is a module *)
  module BC_store = struct
    module Store = Irmin_unix.Git.FS.KV(M)
    module Sync = Irmin.Sync(Store)

    type t = Store.t

    let init ?root ?bare () =
      let config = Irmin_git.config Config.root in
      Store.Repo.v config

    let master (repo:Store.repo) = Store.master repo

    let clone t name = Store.clone t name

    let get_branch r ~branch_name = Store.of_branch r branch_name

    let merge s ~into = Store.merge s ~into

    let update t k v = Store.set t k v

    let read t k = Store.find t k
  end

(* Vpst is a module which consist of type store, st and 'a t *)
  module Vpst : sig
  type 'a t
  val return : 'a -> 'a t
  val bind : 'a t -> ('a -> 'b t) -> 'b t
  val with_init_version_do: OM.t -> 'a t -> 'a
  val fork_version : 'a t -> unit t
  val get_latest_version: unit -> OM.t t
  val sync_next_version: ?v:OM.t -> OM.t t
  val liftLwt : 'a Lwt.t -> 'a t
end = struct
    (* store is a type which is basically of type BC_store.t *)
    type store = BC_store.t
    (* st is a record type with fields as master, local, name and next_id *)
    type st = {master   : store;
               local    : store;
               name     : string;
               next_id  : int}
    type 'a t = st -> ('a * st) Lwt.t

    let info s = Irmin_unix.info "[repo %s] %s" Config.root s  

    let path = ["state"]

    let return (x : 'a) : 'a t = fun st -> Lwt.return (x,st)

    let bind (m1: 'a t) (f: 'a -> 'b t) : 'b t = 
      fun st -> (m1 st >>= fun (a,st') -> f a st')

    let with_init_version_do (v: OM.t) (m: 'a t) =
      Lwt_main.run 
        begin
          BC_store.init () >>= fun repo -> 
          BC_store.master repo >>= fun m_br -> 
          M.of_adt v >>= fun k ->
          let cinfo = info "creating state of master" in
          BC_store.update m_br path k ~info:cinfo >>= fun () ->
          BC_store.clone m_br "1_local" >>= fun t_br ->
          let st = {master=m_br; local=t_br; name="1"; next_id=1} in
          m st >>= fun (a,_) -> Lwt.return a
        end

    let with_init_forked_do (m: 'a t) = 
      BC_store.init () >>= fun repo -> 
      BC_store.master repo >>= fun m_br ->
      BC_store.clone m_br "1_local" >>= fun t_br ->
      let st = {master=m_br; local=t_br; name="1"; next_id=1} in
      m st >>= fun (a, _) -> Lwt.return a

    let fork_version (m: 'a t) : unit t = fun (st: st) ->
      let thread_f () = 
        let child_name = st.name^"_"^(string_of_int st.next_id) in
        let parent_m_br = st.master in
        (* Ideally, the following has to happen: *)
        (* BC_store.clone_force parent_m_br m_name >>= fun m_br -> *)
        (* But, we currently default to an SC mode. Master is global. *)
        let m_br = parent_m_br in
        BC_store.clone m_br (child_name^"_local") >>= fun t_br ->
        let new_st = {master = m_br; local  = t_br; name = child_name; next_id = 1} in
        m new_st in
      begin
        Lwt.async thread_f;
        Lwt.return ((), {st with next_id=st.next_id+1})
      end

    let get_latest_version () : OM.t t = fun (st: st) ->
      BC_store.read st.local path >>= fun k ->
      M.to_adt @@ from_just k >>= fun td ->
      Lwt.return (td,st)

    let sync_remote_version remote_uri ?v : OM.t t = fun (st: st) ->
      (* How do you commit the next version? Simply update path? *)
      (* 1. Commit to the local branch *)
      let cinfo = info "committing local state" in
      (match v with 
       | None -> Lwt.return ()
       | Some v -> 
         M.of_adt v >>= fun k -> 
         BC_store.update st.local path k cinfo) >>= fun () ->

      (* 2.. Pull from remote to master *)
      let cinfo = info (Printf.sprintf "Merging remote: %s" remote_uri) in
      BC_store.Sync.pull st.master (Irmin.remote_uri remote_uri) (`Merge  cinfo) >>= fun _ ->
      (* 2. Merge local master to the local branch *)
      let cinfo = info "Merging master into local" in
      BC_store.merge st.master ~into:st.local ~info:cinfo >>= fun _ ->
      (* 3. Merge local branch to the local master *)
      let cinfo = info "Merging local into master" in
      BC_store.merge st.local ~into:st.master ~info:cinfo >>= fun _ ->
      get_latest_version () st

    let sync_next_version ?v : OM.t t = fun (st: st) ->
      (* How do you commit the next version? Simply update path? *)
      (* 1. Commit to the local branch *)
      let cinfo = info "committing local state" in
      (match v with 
       | None -> Lwt.return ()
       | Some v -> 
         M.of_adt v >>= fun k -> 
         BC_store.update st.local path k cinfo) >>= fun () ->

      (* 2. Merge local master to the local branch *)
      let cinfo = info "Merging master into local" in
      BC_store.merge st.master ~into:st.local ~info:cinfo >>= fun _ ->
      (* 3. Merge local branch to the local master *)
      let cinfo = info "Merging local into master" in
      BC_store.merge st.local ~into:st.master ~info:cinfo >>= fun _ ->
      get_latest_version () st

    let liftLwt (m: 'a Lwt.t) : 'a t = fun st ->
      m >>= fun a -> Lwt.return (a,st)
end 
end







