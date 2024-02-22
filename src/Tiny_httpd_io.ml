(** IO abstraction.

    We abstract IO so we can support classic unix blocking IOs
    with threads, and modern async IO with Eio.

    {b NOTE}: experimental.

    @since 0.14
*)

module Buf = Tiny_httpd_buf

(** Input channel (byte source) *)
module Input = struct
  type t = {
    input: bytes -> int -> int -> int;
        (** Read into the slice. Returns [0] only if the
        channel is closed. *)
    close: unit -> unit;  (** Close the input. Must be idempotent. *)
  }
  (** An input channel, i.e an incoming stream of bytes.

      This can be a [string], an [int_channel], an [Unix.file_descr], a
      decompression wrapper around another input channel, etc. *)

  let of_in_channel ?(close_noerr = false) (ic : in_channel) : t =
    {
      input = (fun buf i len -> input ic buf i len);
      close =
        (fun () ->
          if close_noerr then
            close_in_noerr ic
          else
            close_in ic);
    }

  let of_unix_fd ?(close_noerr = false) ~closed (fd : Unix.file_descr) : t =
    let eof = ref false in
    {
      input =
        (fun buf i len ->
          let n = ref 0 in
          if (not !eof) && len > 0 then (
            let continue = ref true in
            while !continue do
              (* Printf.eprintf "read %d B (from fd %d)\n%!" len (Obj.magic fd); *)
              match Unix.read fd buf i len with
              | n_ ->
                n := n_;
                continue := false
              | exception
                  Unix.Unix_error
                    ( ( Unix.EBADF | Unix.ENOTCONN | Unix.ESHUTDOWN
                      | Unix.ECONNRESET | Unix.EPIPE ),
                      _,
                      _ ) ->
                eof := true;
                continue := false
              | exception
                  Unix.Unix_error
                    ((Unix.EWOULDBLOCK | Unix.EAGAIN | Unix.EINTR), _, _) ->
                ignore (Unix.select [ fd ] [] [] 1.)
            done;
            (* Printf.eprintf "read returned %d B\n%!" !n; *)
            if !n = 0 then eof := true
          );
          !n);
      close =
        (fun () ->
          if not !closed then (
            closed := true;
            eof := true;
            if close_noerr then (
              try Unix.close fd with _ -> ()
            ) else
              Unix.close fd
          ));
    }

  let of_slice (i_bs : bytes) (i_off : int) (i_len : int) : t =
    let i_off = ref i_off in
    let i_len = ref i_len in
    {
      input =
        (fun buf i len ->
          let n = min len !i_len in
          Bytes.blit i_bs !i_off buf i n;
          i_off := !i_off + n;
          i_len := !i_len - n;
          n);
      close = ignore;
    }

  (** Read into the given slice.
      @return the number of bytes read, [0] means end of input. *)
  let[@inline] input (self : t) buf i len = self.input buf i len

  (** Read exactly [len] bytes.
      @raise End_of_file if the input did not contain enough data. *)
  let really_input (self : t) buf i len : unit =
    let i = ref i in
    let len = ref len in
    while !len > 0 do
      let n = input self buf !i !len in
      if n = 0 then raise End_of_file;
      i := !i + n;
      len := !len - n
    done

  (** Close the channel. *)
  let[@inline] close self : unit = self.close ()

  let append (i1 : t) (i2 : t) : t =
    let use_i1 = ref true in
    let rec input buf i len : int =
      if !use_i1 then (
        let n = i1.input buf i len in
        if n = 0 then (
          use_i1 := false;
          input buf i len
        ) else
          n
      ) else
        i2.input buf i len
    in

    {
      input;
      close =
        (fun () ->
          close i1;
          close i2);
    }
end

(** Output channel (byte sink) *)
module Output = struct
  type t = {
    output_char: char -> unit;  (** Output a single char *)
    output: bytes -> int -> int -> unit;  (** Output slice *)
    flush: unit -> unit;  (** Flush underlying buffer *)
    close: unit -> unit;  (** Close the output. Must be idempotent. *)
  }
  (** An output channel, ie. a place into which we can write bytes.

      This can be a [Buffer.t], an [out_channel], a [Unix.file_descr], etc. *)

  let of_unix_fd ?(close_noerr = false) ~closed ~(buf : Buf.t)
      (fd : Unix.file_descr) : t =
    Buf.clear buf;
    let buf = Buf.bytes_slice buf in
    let off = ref 0 in

    let flush () =
      if !off > 0 then (
        let i = ref 0 in
        while !i < !off do
          (* Printf.eprintf "write %d bytes\n%!" (!off - !i); *)
          match Unix.write fd buf !i (!off - !i) with
          | 0 -> failwith "write failed"
          | n -> i := !i + n
          | exception
              Unix.Unix_error
                ( ( Unix.EBADF | Unix.ENOTCONN | Unix.ESHUTDOWN
                  | Unix.ECONNRESET | Unix.EPIPE ),
                  _,
                  _ ) ->
            failwith "write failed"
          | exception
              Unix.Unix_error
                ((Unix.EWOULDBLOCK | Unix.EAGAIN | Unix.EINTR), _, _) ->
            ignore (Unix.select [] [ fd ] [] 1.)
        done;
        off := 0
      )
    in

    let[@inline] flush_if_full_ () = if !off = Bytes.length buf then flush () in

    let output_char c =
      flush_if_full_ ();
      Bytes.set buf !off c;
      incr off;
      flush_if_full_ ()
    in
    let output bs i len =
      (* Printf.eprintf "output %d bytes (buffered)\n%!" len; *)
      let i = ref i in
      let len = ref len in
      while !len > 0 do
        flush_if_full_ ();
        let n = min !len (Bytes.length buf - !off) in
        Bytes.blit bs !i buf !off n;
        i := !i + n;
        len := !len - n;
        off := !off + n
      done;
      flush_if_full_ ()
    in
    let close () =
      if not !closed then (
        closed := true;
        flush ();
        if close_noerr then (
          try Unix.close fd with _ -> ()
        ) else
          Unix.close fd
      )
    in
    { output; output_char; flush; close }

  (** [of_out_channel oc] wraps the channel into a {!Output.t}.
      @param close_noerr if true, then closing the result uses [close_out_noerr]
      instead of [close_out] to close [oc] *)
  let of_out_channel ?(close_noerr = false) (oc : out_channel) : t =
    {
      output_char = (fun c -> output_char oc c);
      output = (fun buf i len -> output oc buf i len);
      flush = (fun () -> flush oc);
      close =
        (fun () ->
          if close_noerr then
            close_out_noerr oc
          else
            close_out oc);
    }

  (** [of_buffer buf] is an output channel that writes directly into [buf].
        [flush] and [close] have no effect. *)
  let of_buffer (buf : Buffer.t) : t =
    {
      output_char = Buffer.add_char buf;
      output = Buffer.add_subbytes buf;
      flush = ignore;
      close = ignore;
    }

  (** Output the buffer slice into this channel *)
  let[@inline] output_char (self : t) c : unit = self.output_char c

  (** Output the buffer slice into this channel *)
  let[@inline] output (self : t) buf i len : unit = self.output buf i len

  let[@inline] output_string (self : t) (str : string) : unit =
    self.output (Bytes.unsafe_of_string str) 0 (String.length str)

  (** Close the channel. *)
  let[@inline] close self : unit = self.close ()

  (** Flush (ie. force write) any buffered bytes. *)
  let[@inline] flush self : unit = self.flush ()

  let output_buf (self : t) (buf : Buf.t) : unit =
    let b = Buf.bytes_slice buf in
    output self b 0 (Buf.size buf)

  (** [chunk_encoding oc] makes a new channel that outputs its content into [oc]
      in chunk encoding form.
      @param close_rec if true, closing the result will also close [oc]
      @param buf a buffer used to accumulate data into chunks.
        Chunks are emitted when [buf]'s size gets over a certain threshold,
        or when [flush] is called.
      *)
  let chunk_encoding ?(buf = Buf.create ()) ~close_rec (self : t) : t =
    (* write content of [buf] as a chunk if it's big enough.
       If [force=true] then write content of [buf] if it's simply non empty. *)
    let write_buf ~force () =
      let n = Buf.size buf in
      if (force && n > 0) || n >= 4_096 then (
        output_string self (Printf.sprintf "%x\r\n" n);
        self.output (Buf.bytes_slice buf) 0 n;
        output_string self "\r\n";
        Buf.clear buf
      )
    in

    let flush () =
      write_buf ~force:true ();
      self.flush ()
    in

    let close () =
      write_buf ~force:true ();
      (* write an empty chunk to close the stream *)
      output_string self "0\r\n";
      (* write another crlf after the stream (see #56) *)
      output_string self "\r\n";
      self.flush ();
      if close_rec then self.close ()
    in
    let output b i n =
      Buf.add_bytes buf b i n;
      write_buf ~force:false ()
    in

    let output_char c =
      Buf.add_char buf c;
      write_buf ~force:false ()
    in
    { output_char; flush; close; output }
end

(** A writer abstraction. *)
module Writer = struct
  type t = { write: Output.t -> unit } [@@unboxed]
  (** Writer.

    A writer is a push-based stream of bytes.
    Give it an output channel and it will write the bytes in it.

    This is useful for responses: an http endpoint can return a writer
    as its response's body; the writer is given access to the connection
    to the client and can write into it as if it were a regular
    [out_channel], including controlling calls to [flush].
    Tiny_httpd will convert these writes into valid HTTP chunks.
    @since 0.14
    *)

  let[@inline] make ~write () : t = { write }

  (** Write into the channel. *)
  let[@inline] write (oc : Output.t) (self : t) : unit = self.write oc

  (** Empty writer, will output 0 bytes. *)
  let empty : t = { write = ignore }

  (** A writer that just emits the bytes from the given string. *)
  let[@inline] of_string (str : string) : t =
    let write oc = Output.output_string oc str in
    { write }
end

(** A TCP server abstraction. *)
module TCP_server = struct
  type conn_handler = {
    handle: client_addr:Unix.sockaddr -> Input.t -> Output.t -> unit;
        (** Handle client connection *)
  }

  type t = {
    endpoint: unit -> string * int;
        (** Endpoint we listen on. This can only be called from within [serve]. *)
    active_connections: unit -> int;
        (** Number of connections currently active *)
    running: unit -> bool;  (** Is the server currently running? *)
    stop: unit -> unit;
        (** Ask the server to stop. This might not take effect immediately,
      and is idempotent. After this [server.running()] must return [false]. *)
  }
  (** A running TCP server.

     This contains some functions that provide information about the running
     server, including whether it's active (as opposed to stopped), a function
     to stop it, and statistics about the number of connections. *)

  type builder = {
    serve: after_init:(t -> unit) -> handle:conn_handler -> unit -> unit;
        (** Blocking call to listen for incoming connections and handle them.
            Uses the connection handler [handle] to handle individual client
            connections in individual threads/fibers/tasks.
            @param after_init is called once with the server after the server
            has started. *)
  }
  (** A TCP server builder implementation.

      Calling [builder.serve ~after_init ~handle ()] starts a new TCP server on
      an unspecified endpoint
      (most likely coming from the function returning this builder)
      and returns the running server. *)
end
