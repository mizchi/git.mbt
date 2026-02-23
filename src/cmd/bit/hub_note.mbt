///|
fn print_hub_note_usage() -> Unit {
  println("Usage: bit pr|issue note <subcommand> [<args>]")
  println("")
  println("Subcommands:")
  println("  add <commit> [--body <body>] [--ns <name>]")
  println("  get <commit> [--ns <name>]")
  println("  list [--ns <name>]")
  println("  remove <commit> [--ns <name>]")
}

///|
async fn handle_hub_note(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_note_usage()
    return ()
  }
  let subcmd = args[0]
  let rest = collect_args(args, 1)
  match subcmd {
    "add" => handle_hub_note_add(rest)
    "get" => handle_hub_note_get(rest)
    "list" => handle_hub_note_list(rest)
    "remove" => handle_hub_note_remove(rest)
    "help" | "-h" | "--help" => print_hub_note_usage()
    _ => {
      eprint_line("bit note: unknown subcommand '\{subcmd}'")
      print_hub_note_usage()
      @sys.exit(1)
    }
  }
}

///|
async fn handle_hub_note_add(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_note_usage()
    return ()
  }
  let mut commit_hex : String? = None
  let mut body : String? = None
  let mut ns : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" | "--message" | "--body" if i + 1 < args.length() => {
        body = Some(args[i + 1])
        i += 2
        continue
      }
      "--ns" if i + 1 < args.length() => {
        ns = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--body=") => {
        body = Some(String::unsafe_substring(arg, start=7, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        body = Some(String::unsafe_substring(arg, start=10, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("--ns=") => {
        ns = Some(String::unsafe_substring(arg, start=5, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("note add", arg)
        i += 1
        continue
      }
      _ => {
        if commit_hex is None {
          commit_hex = Some(arg)
        } else {
          warn_unimplemented_arg("note add", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard commit_hex is Some(hex) else {
    raise @bitcore.GitError::InvalidObject("Commit id is required")
  }
  let note_body = match body {
    Some(b) => b
    None => {
      let input = read_all_stdin()
      let text = decode_bytes(input)
      if text.length() == 0 {
        raise @bitcore.GitError::InvalidObject("Missing --body")
      }
      text
    }
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  let note = hub.add_note(
    objects,
    refs,
    clock,
    @bitcore.ObjectId::from_hex(hex),
    note_body,
    get_author_string(),
    get_commit_timestamp(),
    ns=note_ns(ns),
  )
  print_line(note.serialize())
}

///|
async fn handle_hub_note_get(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_note_usage()
    return ()
  }
  let mut commit_hex : String? = None
  let mut ns : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--ns" if i + 1 < args.length() => {
        ns = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--ns=") => {
        ns = Some(String::unsafe_substring(arg, start=5, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("note get", arg)
        i += 1
        continue
      }
      _ => {
        if commit_hex is None {
          commit_hex = Some(arg)
        } else {
          warn_unimplemented_arg("note get", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard commit_hex is Some(hex) else {
    raise @bitcore.GitError::InvalidObject("Commit id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let note = hub.get_note(
    objects,
    refs,
    @bitcore.ObjectId::from_hex(hex),
    ns=note_ns(ns),
  )
  guard note is Some(val) else {
    raise @bitcore.GitError::InvalidObject("Note not found for \{hex}")
  }
  print_line(val.serialize())
}

///|
async fn handle_hub_note_list(args : Array[String]) -> Unit raise Error {
  let mut ns : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--ns" if i + 1 < args.length() => {
        ns = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--ns=") => {
        ns = Some(String::unsafe_substring(arg, start=5, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("note list", arg)
        i += 1
        continue
      }
      _ => {
        warn_unimplemented_arg("note list", arg)
        i += 1
        continue
      }
    }
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, _clock) = make_hub_stores(git_dir)
  let hub = load_hub_store(objects, refs)
  let notes = hub.list_notes(objects, refs, ns=note_ns(ns))
  if notes.length() == 0 {
    print_line("No notes")
    return ()
  }
  for note in notes {
    print_line(note.serialize())
  }
}

///|
async fn handle_hub_note_remove(args : Array[String]) -> Unit raise Error {
  if args.length() == 0 {
    print_hub_note_usage()
    return ()
  }
  let mut commit_hex : String? = None
  let mut ns : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--ns" if i + 1 < args.length() => {
        ns = Some(args[i + 1])
        i += 2
        continue
      }
      _ if arg.has_prefix("--ns=") => {
        ns = Some(String::unsafe_substring(arg, start=5, end=arg.length()))
        i += 1
        continue
      }
      _ if arg.has_prefix("-") => {
        warn_unimplemented_arg("note remove", arg)
        i += 1
        continue
      }
      _ => {
        if commit_hex is None {
          commit_hex = Some(arg)
        } else {
          warn_unimplemented_arg("note remove", arg)
        }
        i += 1
        continue
      }
    }
  }
  guard commit_hex is Some(hex) else {
    raise @bitcore.GitError::InvalidObject("Commit id is required")
  }
  let root = get_work_root()
  let git_dir = root + "/.git"
  let (objects, refs, clock) = make_hub_stores(git_dir)
  let hub = init_hub_store(objects, refs)
  hub.remove_note(
    objects,
    refs,
    clock,
    @bitcore.ObjectId::from_hex(hex),
    ns=note_ns(ns),
  )
  print_line("Removed note for \{hex}")
}
