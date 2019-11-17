
(** An input stream. *)
type input_stream = {
  ic: in_channel;
  mutable buf: bytes;
}

exception Bad_req of int * string
let bad_reqf c fmt = Printf.ksprintf (fun s ->raise (Bad_req (c,s))) fmt

let _debug k =
  match Sys.getenv "HTTP_DBG" with
  | _ ->
    k (fun fmt->
       Printf.fprintf stdout "[thread %d]: " Thread.(id @@ self());
       Printf.kfprintf (fun oc -> Printf.fprintf oc "\n%!") stdout fmt)
  | exception _ -> ()

module Response_code = struct
  type t = int

  let descr = function
    | 100 -> "Continue"
    | 200 -> "OK"
    | 400 -> "Bad request"
    | 403 -> "Forbidden"
    | 404 -> "Not found"
    | 417 -> "Expectation failed"
    | 500 -> "Internal server error"
    | 503 -> "Service unavailable"
    | _ -> "Unknown response" (* TODO *)
end

type 'a resp_result = ('a, Response_code.t * string) result 
let unwrap_resp_result = function
  | Ok x -> x
  | Error (c,s) -> raise (Bad_req (c,s))

module Meth = struct
  type t = [
    | `GET
    | `PUT
    | `POST
    | `HEAD
  ]

  let to_string = function
    | `GET -> "GET"
    | `PUT -> "PUT"
    | `HEAD -> "HEAD"
    | `POST -> "POST"
  let pp out s = Format.pp_print_string out (to_string s)

  let of_string = function
    | "GET" -> `GET
    | "PUT" -> `PUT
    | "POST" -> `POST
    | "HEAD" -> `HEAD
    | s -> bad_reqf 400 "unknown method %S" s
end

module Headers = struct
  type t = (string * string) list
  let contains = List.mem_assoc
  let get x h = try Some (List.assoc x h) with Not_found -> None
  let set x y h = (x,y) :: List.filter (fun (k,_) -> k<>x) h
  let pp out l =
    let pp_pair out (k,v) = Format.fprintf out "@[<h>%s: %s@]" k v in
    Format.fprintf out "@[<v>%a@]" (Format.pp_print_list pp_pair) l

  let parse_ (is:input_stream) : t =
    let rec loop acc =
      let line = input_line is.ic in
      if line = "\r" then (
        List.rev acc
      ) else (
        let k,v =
          try Scanf.sscanf line "%s@: %s@\r" (fun k v->k,v)
          with _ -> bad_reqf 400 "invalid header line: %S" line
        in
        loop ((k,v)::acc)
      )
    in
    loop []
end

module Request = struct
  type t = {
    meth: Meth.t;
    headers: Headers.t;
    path: string;
    body: string
  }

  let headers self = self.headers
  let meth self = self.meth
  let path self = self.path
  let body self = self.body

  let pp out self : unit =
    Format.fprintf out "{@[meth=%s;@ headers=%a;@ path=%S;@ body=%S@]}"
      (Meth.to_string self.meth) Headers.pp self.headers
      self.path self.body

  let read_body (is:input_stream) (n:int) : string =
    _debug (fun k->k "read body of size %d" n);
    if Bytes.length is.buf < n then (
      is.buf <- Bytes.make n ' ';
    );
    let i = ref 0 in
    while !i < n do
      let read = input is.ic is.buf !i (n- !i) in
      if read=0 then bad_reqf 400 "body is too short";
      i := !i + read
    done;
    Bytes.sub_string is.buf 0 n

  let read_body_chunked (is:input_stream) : string =
    _debug (fun k->k "read body with chunked encoding");
    let n = ref 0 in
    let rec read_chunks () =
      let line = input_line is.ic in
      (* parse chunk length, ignore extensions *)
      let chunk_size =
        if String.trim line = "" then 0
        else
          try Scanf.sscanf line "%x %s@\r" (fun n _ext -> n)
          with _ -> bad_reqf 400 "cannot read chunk size from line %S" line
      in
      _debug (fun k->k "chunk size: %d" chunk_size);
      if chunk_size = 0 then (
        Bytes.sub_string is.buf 0 !n (* done *)
      ) else (
        let new_size = chunk_size + !n in
        (* resize buffer if needed *)
        if Bytes.length is.buf < new_size then (
          let new_buf = Bytes.make (new_size + 10) ' ' in
          Bytes.blit is.buf 0 new_buf 0 !n;
          is.buf <- new_buf;
        );
        while !n < new_size do
          let read = input is.ic is.buf !n (new_size - !n) in
          if read=0 then bad_reqf 400 "body is too short";
          n := !n + read
        done;
        _debug (fun k->k "read a chunk");
        read_chunks()
      )
    in
    read_chunks()

  (* parse request, but not body (yet) *)
  let parse_req_start (is:input_stream) : t option resp_result =
    try
      let line = input_line is.ic in
      let meth, path =
        try Scanf.sscanf line "%s %s HTTP/1.1\r" (fun x y->x,y)
        with _ -> raise (Bad_req (400, "Invalid request line"))
      in
      let meth = Meth.of_string meth in
      let headers = Headers.parse_ is in
      _debug (fun k->k "got meth: %s, path %S" (Meth.to_string meth) path);
      Ok (Some {meth; path; headers; body=""})
    with
    | End_of_file | Sys_error _ -> Ok None
    | Bad_req (c,s) -> Error (c,s)
    | e ->
      Error (400, Printexc.to_string e)

  (* parse body, given the headers *)
  let parse_body_ (is:input_stream) (req:t) : t resp_result =
    try
      let body = match List.assoc "Content-Length" req.headers |> int_of_string with
        | 0 -> ""
        | n -> read_body is n (* body of fixed size *)
        | exception Not_found ->
          begin match List.assoc "Transfer-Encoding" req.headers |> String.trim with
            | "chunked" -> read_body_chunked is (* body sent by chunks *)
            | s -> bad_reqf 500 "cannot handle transfer encoding: %s" s
            | exception Not_found -> ""
          end
        | exception _ -> bad_reqf 400 "invalid content-length"
      in
      Ok {req with body}
    with
    | End_of_file -> Error (400, "unexpected end of file")
    | Bad_req (c,s) -> Error (c,s)
    | e ->
      Error (400, Printexc.to_string e)
end

module Response = struct
  type out_stream = bytes -> int -> int -> int
  type body = [
    | `String of string
    | `Stream of out_stream
  ]

  type t = {
    code: Response_code.t;
    headers: Headers.t;
    body: body;
  }

  (* TODO: if query had ["Accept-Encoding", "chunked"], we cna reply with chunks,
     if [body] was a stream|string instead of just a string *)

  let make_raw ?(headers=[]) ~code body : t =
    (* add content length to response *)
    let headers =
      Headers.set "Content-Length" (string_of_int (String.length body)) headers
    in
    { code; headers; body=`String body; }

  let make_raw_chunked ?(headers=[]) ~code body : t =
    (* add content length to response *)
    let headers = Headers.set "Transfer-Encoding" "chunked" headers in
    { code; headers; body=`Stream body; }

  let make ?headers r : t = match r with
    | Ok body -> make_raw ?headers ~code:200 body
    | Error (code,msg) ->
      make_raw ?headers ~code msg

  let fail ?headers ~code fmt =
    Printf.ksprintf (fun msg -> make_raw ?headers ~code msg) fmt

  let pp out self : unit =
    let pp_body out = function
      | `String s -> Format.fprintf out "%S" s
      | `Stream _ -> Format.pp_print_string out "<stream>"
    in
    Format.fprintf out "{@[code=%d;@ headers=%a;@ body=%a@]}"
      self.code Headers.pp self.headers pp_body self.body

  (* print a stream as a series of chunks *)
  let output_stream_ (oc:out_channel) (str:out_stream) : unit =
    let buf = Bytes.make 4096 ' ' in
    let continue = ref true in
    while !continue do
      (* next chunk *)
      let n = str buf 0 (Bytes.length buf) in
      _debug (fun k->k "send chunk of size %d" n);
      Printf.fprintf oc "%x\r\n" n;
      if n = 0 then (
        continue := false;
      ) else (
        output oc buf 0 n;
      );
      output_string oc "\r\n";
    done;
    ()

  let output_ (oc:out_channel) (self:t) : unit =
    Printf.fprintf oc "HTTP/1.1 %d %s\r\n" self.code (Response_code.descr self.code);
    List.iter (fun (k,v) -> Printf.fprintf oc "%s: %s\r\n" k v) self.headers;
    Printf.fprintf oc "\r\n";
    begin match self.body with
      | `String "" -> ()
      | `String s -> output_string oc s;
      | `Stream str -> output_stream_ oc str;
    end;
    flush oc
end

type t = {
  addr: string;
  port: int;
  fork: (unit -> unit) -> unit;
  masksigpipe: bool;
  mutable handler: (Request.t -> Response.t);
  mutable path_handlers : (Request.t -> (unit -> Response.t) option) list;
  mutable req_cbs: (Request.t -> Request.t option) list;
  mutable res_cbs: (Request.t -> Response.t -> Response.t option) list;
  mutable running: bool;
}

let addr self = self.addr
let port self = self.port

let add_request_cb self f =  self.req_cbs <- f :: self.req_cbs
let add_response_cb self f = self.res_cbs <- f :: self.res_cbs
let set_top_handler self f = self.handler <- f

let add_path_handler ?meth self fmt f =
  let ph req: (unit -> Response.t) option =
    match meth with
    | Some m when m <> req.Request.meth -> None (* ignore *)
    | _ ->
      try Some (Scanf.sscanf req.Request.path fmt (f req))
      with _ -> None
  in
  self.path_handlers <- ph :: self.path_handlers

let create
    ?(masksigpipe=true)
    ?(fork=(fun f -> ignore (Thread.create f () : Thread.t)))
    ?(addr="127.0.0.1") ?(port=8080) () : t =
  let handler _req = Response.fail ~code:404 "no top handler" in
  { fork; addr; port; masksigpipe; handler; running= true;
    path_handlers=[];
    req_cbs=[]; res_cbs=[];
  }

let stop s = s.running <- false

let find_map f l =
  let rec aux f = function
    | [] -> None
    | x::l' ->
      match f x with
        | Some _ as res -> res
        | None -> aux f l'
  in aux f l

let handle_client_ (self:t) (client_sock:Unix.file_descr) : unit =
  let ic = Unix.in_channel_of_descr client_sock in
  let oc = Unix.out_channel_of_descr client_sock in
  (* wrap [ic] in a stream with a reusable buffer *)
  let is = {ic; buf=Bytes.make 1024 ' '} in
  let handler = self.handler in
  let ph_handlers = self.path_handlers in
  let continue = ref true in
  while !continue && self.running do
    _debug (fun k->k "read next request");
    match Request.parse_req_start is with
    | Ok None -> continue := false
    | Error (c,s) ->
      let res = Response.make_raw ~code:c s in
      Response.output_ oc res
    | Ok (Some req) ->
      let res =
        try
          (* handle expectations *)
          begin match List.assoc "Expect" req.Request.headers with
            | "100-continue" ->
              _debug (fun k->k "send back: 100 CONTINUE");
              Response.output_ oc (Response.make_raw ~code:100 "");
            | s -> bad_reqf 417 "unknown expectation %s" s
            | exception Not_found -> ()
          end;
          (* modify request by reading body *)
          let req = Request.parse_body_ is req |> unwrap_resp_result in
          (* request callbacks *)
          let req =
            List.fold_left
              (fun req cb -> match cb req with None -> req | Some r' -> r')
              req self.req_cbs
          in
          let run_handler =
            match find_map (fun ph -> ph req) ph_handlers with
            | Some f -> f
            | None -> (fun () -> handler req)
          in
          let resp = run_handler() in
          (* response callbacks *)
          List.fold_left
            (fun resp cb -> match cb req resp with None -> resp | Some r' -> r')
            resp self.res_cbs
        with
        | e ->
          Response.fail ~code:500 "server error: %s" (Printexc.to_string e)
      in
      Response.output_ oc res
    | exception Bad_req (code,s) ->
      Response.output_ oc (Response.make_raw ~code s);
      continue := false
    | exception Sys_error _ ->
      continue := false; (* connection broken somehow *)
      Unix.close client_sock;
  done;
  _debug (fun k->k "done with client, exiting");
  ()

let run (self:t) : (unit,_) result =
  try
    if self.masksigpipe then (
      ignore (Unix.sigprocmask Unix.SIG_BLOCK [Sys.sigpipe] : _ list);
    );
    let sock = Unix.socket PF_INET Unix.SOCK_STREAM 0 in
    Unix.setsockopt sock Unix.SO_REUSEADDR true;
    Unix.setsockopt_optint sock Unix.SO_LINGER None;
    let inet_addr = Unix.inet_addr_of_string self.addr in
    Unix.bind sock (Unix.ADDR_INET (inet_addr, self.port));
    Unix.listen sock 10;
    while self.running do
      let client_sock, _ = Unix.accept sock in
      self.fork
        (fun () -> handle_client_ self client_sock);
    done;
    Ok ()
  with e -> Error e