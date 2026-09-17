// SPDX-License-Identifier: Apache-2.0
// function-set: the rule-asset verbs (P6). A function set is authored
// as one JSON document and deployed to a node, exactly like a topic
// declaration is: the asset lives in that node's metadata store, is
// validated before it lands, and gains a revision on every update. The
// verbs are deliberately few — the asset document carries the content,
// the commands carry the name and the destination.

///|
/// `moonflux function-set <verb> [flags]`
fn cmd_function_set(argv : Array[String]) -> Unit {
  if argv.length() == 0 {
    fail("function-set: missing verb (create, get, list, delete)")
  }
  let verb = argv[0]
  let rest = if argv.length() > 1 {
    argv[1:argv.length()].to_owned()
  } else {
    []
  }
  match verb {
    "create" => function_set_create(rest)
    "get" => function_set_get(rest)
    "list" => function_set_list(rest)
    "delete" => function_set_delete(rest)
    _ =>
      fail(
        "function-set: unknown verb '\{verb}' (known: create, get, list, delete)",
      )
  }
}

///|
/// `moonflux function-set create --file fns.json --remote host:port`
/// The document's `name` is the asset name; `--name` overrides it (and
/// is the only way for a document that omits one).
fn function_set_create(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = flags.require("remote")
  let path = flags.require("file")
  let text = match @fs.read_file(path) {
    Ok(bytes) => @utf8.decode_lossy(bytes[0:bytes.length()])
    Err(e) => fail("function-set create: read \{path}: \{e}")
  }
  // local parse first: an operator gets the shape errors without a
  // round trip. The node re-validates — it owns the store.
  let (doc_name, functions) = match parse_function_set_asset(text) {
    Ok(parsed) => parsed
    Err(e) => fail("function-set create: \{e}")
  }
  let name = match flags.get("name") {
    Some(name) => name
    None => doc_name
  }
  match
    control_call_with_token(
      remote,
      @client.CMD_FUNCTION_SET_CREATE,
      @utf8.encode(text),
      client_token(flags),
    ) {
    Ok(payload) => {
      let reply = @utf8.decode_lossy(payload[0:payload.length()])
      let parsed = @json.parse(reply[0:reply.length()]) catch {
        _ => Json::null()
      }
      let revision = match parsed.value("revision") {
        Some(Number(n)) => n.to_int64()
        _ => 0L
      }
      let was_new = match parsed.value("created") {
        Some(True) => true
        _ => false
      }
      let verb = if was_new { "deployed" } else { "updated" }
      println(
        "\{verb} function set \{name} at revision \{revision} (\{functions.length()} function(s))",
      )
    }
    Err(e) => fail("function-set create: \{e}")
  }
  cli_exit(0)
}

///|
/// `moonflux function-set get --name N --remote host:port`
fn function_set_get(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = flags.require("remote")
  let name = flags.require("name")
  let payload = match
    control_call_with_token(
      remote,
      @client.CMD_FUNCTION_SET_GET,
      @utf8.encode(name),
      client_token(flags),
    ) {
    Ok(payload) => payload
    Err(e) => fail("function-set get: \{e}")
  }
  let text = @utf8.decode_lossy(payload[0:payload.length()])
  println(text)
  cli_exit(0)
}

///|
/// `moonflux function-set list --remote host:port`
fn function_set_list(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = flags.require("remote")
  let payload = match
    control_call_with_token(
      remote,
      @client.CMD_FUNCTION_SET_LIST,
      b"",
      client_token(flags),
    ) {
    Ok(payload) => payload
    Err(e) => fail("function-set list: \{e}")
  }
  let text = @utf8.decode_lossy(payload[0:payload.length()])
  let json = @json.parse(text[0:text.length()]) catch {
    e => fail("function-set list: bad reply: \{e}")
  }
  match json {
    Array(items) =>
      for item in items {
        let name = match item.value("name") {
          Some(String(name)) => name
          _ => "?"
        }
        let revision = match item.value("revision") {
          Some(Number(n)) => n.to_int64()
          _ => 0L
        }
        let count = match item.value("functions") {
          Some(Array(fns)) => fns.length()
          _ => 0
        }
        println("\{name}\trevision=\{revision}\tfunctions=\{count}")
      }
    _ => fail("function-set list: bad reply shape")
  }
  cli_exit(0)
}

///|
/// `moonflux function-set delete --name N --remote host:port`
fn function_set_delete(argv : Array[String]) -> Unit {
  let flags = parse_flags(argv)
  let remote = flags.require("remote")
  let name = flags.require("name")
  match
    control_call_with_token(
      remote,
      @client.CMD_FUNCTION_SET_DELETE,
      @utf8.encode(name),
      client_token(flags),
    ) {
    Ok(_) => ()
    Err(e) => fail("function-set delete: \{e}")
  }
  println("deleted function set \{name}")
  cli_exit(0)
}

// ---------------------------------------------------------------------
// The node side: one handler, three dispatch sites (serve's hub path,
// serve's websocket session, the control port). Function sets are
// *node-local assets* — the same posture as topic declarations: each
// node holds the sets its own applies need, and a spec's apply is what
// binds a pipeline to a revision.

///|
/// Handles one function-set command against a node's metadata store.
/// Reply payloads are JSON text (the asset document is the interface;
/// the frame layer only carries it).
fn dispatch_function_set(
  frame : @client.Frame,
  store : MetadataStore,
) -> Result[Bytes, (Int, String)] {
  match frame.cmd {
    @client.CMD_FUNCTION_SET_CREATE => {
      let text = @utf8.decode_lossy(frame.payload[0:frame.payload.length()])
      let (doc_name, functions) = match parse_function_set_asset(text) {
        Ok(parsed) => parsed
        Err(e) => return Err((@client.ERR_BAD_PAYLOAD, "\{e}"))
      }
      let existed = match (store.load)() {
        Ok(metadata) => find_function_set(metadata, doc_name) is Some(_)
        Err(e) => return Err((@client.ERR_STORAGE, "\{e}"))
      }
      let created = match create_function_set(store, doc_name, functions) {
        Ok(created) => created
        Err(Rejected(message)) => return Err((@client.ERR_BAD_PAYLOAD, message))
        Err(Corrupt(message)) => return Err((@client.ERR_BAD_PAYLOAD, message))
        Err(Conflict(message)) => return Err((@client.ERR_SEQUENCE, message))
        Err(Storage(message)) => return Err((@client.ERR_STORAGE, message))
      }
      let reply_map : Map[String, Json] = {}
      reply_map["name"] = Json::string(created.name)
      reply_map["revision"] = Json::number(created.revision.to_double())
      reply_map["created"] = Json::boolean(!existed)
      let reply = Json::object(reply_map).stringify()
      Ok(@utf8.encode(reply[0:reply.length()]))
    }
    @client.CMD_FUNCTION_SET_LIST =>
      match list_function_sets(store) {
        Ok(sets) => {
          let items : Array[Json] = []
          for set in sets {
            items.push(encode_function_set_doc(set))
          }
          let text = Json::array(items).stringify()
          Ok(@utf8.encode(text[0:text.length()]))
        }
        Err(e) => Err((@client.ERR_STORAGE, "\{e}"))
      }
    @client.CMD_FUNCTION_SET_GET => {
      let name = @utf8.decode_lossy(frame.payload[0:frame.payload.length()])
      match get_function_set(store, name) {
        Ok(set) => {
          let text = encode_function_set_doc(set).stringify(indent=2)
          Ok(@utf8.encode(text[0:text.length()]))
        }
        Err(Rejected(message)) => Err((@client.ERR_BAD_PAYLOAD, message))
        Err(e) => Err((@client.ERR_STORAGE, "\{e}"))
      }
    }
    @client.CMD_FUNCTION_SET_DELETE => {
      let name = @utf8.decode_lossy(frame.payload[0:frame.payload.length()])
      match delete_function_set(store, name) {
        Ok(_) => Ok(b"")
        Err(Rejected(message)) => Err((@client.ERR_BAD_PAYLOAD, message))
        Err(e) => Err((@client.ERR_STORAGE, "\{e}"))
      }
    }
    _ =>
      Err(
        (
          @client.ERR_UNKNOWN_COMMAND,
          "not a function-set command (\{frame.cmd})",
        ),
      )
  }
}

///|
/// True when the command is one the handler above answers — the
/// dispatch sites use this to route without re-listing the constants.
fn is_function_set_command(cmd : Int) -> Bool {
  cmd == @client.CMD_FUNCTION_SET_CREATE ||
  cmd == @client.CMD_FUNCTION_SET_LIST ||
  cmd == @client.CMD_FUNCTION_SET_GET ||
  cmd == @client.CMD_FUNCTION_SET_DELETE
}
