///|
async fn handle_show_ref(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let git_dir = resolve_git_dir(fs, root)
  let mut heads_only = false
  let mut tags_only = false
  let mut hash_only = false
  let mut verify = false
  let mut exists = false
  let mut quiet = false
  let mut dereference = false
  let mut show_head = false
  let mut exclude_existing = false
  let mut _exclude_existing_prefix = ""
  let patterns : Array[String] = []
  for arg in args {
    match arg {
      "--heads" | "--branches" => heads_only = true
      "--tags" => tags_only = true
      "-s" | "--hash" => hash_only = true
      "--verify" => verify = true
      "--exists" => exists = true
      "-q" | "--quiet" => quiet = true
      "-d" | "--dereference" => dereference = true
      "--head" => show_head = true
      "--exclude-existing" => exclude_existing = true
      _ if arg.has_prefix("--exclude-existing=") => {
        exclude_existing = true
        _exclude_existing_prefix = arg[19:].to_string()
      }
      "--" => ()
      _ if arg.has_prefix("-") => warn_unimplemented_arg("show-ref", arg)
      _ => patterns.push(arg)
    }
  }
  // Sub-modes are mutually exclusive: --verify, --exists, --exclude-existing
  let mode_count = (if verify { 1 } else { 0 }) +
    (if exists { 1 } else { 0 }) +
    (if exclude_existing { 1 } else { 0 })
  if mode_count > 1 {
    let modes : Array[String] = []
    if verify {
      modes.push("--verify")
    }
    if exclude_existing {
      modes.push("--exclude-existing")
    }
    if exists {
      modes.push("--exists")
    }
    eprint_line(
      "error: options '\{modes[0]}' and '\{modes[1]}' cannot be used together",
    )
    @sys.exit(129)
  }
  if exists {
    if patterns.length() != 1 {
      @sys.exit(1)
    }
    let refname = patterns[0]
    if show_ref_exists_without_resolution(fs, git_dir, refname) {
      @sys.exit(0)
    } else {
      if not(quiet) {
        eprint_line("error: reference does not exist")
      }
      @sys.exit(2)
    }
  }
  if verify {
    if patterns.length() == 0 {
      @sys.exit(1)
    }
    let db = @bitlib.ObjectDb::load(fs, git_dir)
    let mut has_missing = false
    for refname in patterns {
      match @bitlib.resolve_ref(fs, git_dir, refname) {
        Some(id) => {
          // Verify object exists (git checks this for dangling refs)
          let obj_exists = db.get(fs, id) catch { _ => None }
          if obj_exists is None {
            if not(quiet) {
              eprint_line(
                "fatal: git show-ref: bad ref \{refname} (\{id.to_hex()})",
              )
            }
            has_missing = true
          } else if not(quiet) {
            if hash_only {
              print_line(id.to_hex())
            } else {
              print_line("\{id.to_hex()} \{refname}")
            }
            if dereference {
              show_ref_deref(db, fs, id, refname, hash_only)
            }
          }
        }
        None => has_missing = true
      }
    }
    if has_missing {
      @sys.exit(1)
    }
    return
  }
  let refs = @bitrepo.show_ref(fs, git_dir)
  let db = if dereference {
    Some(@bitlib.ObjectDb::load(fs, git_dir))
  } else {
    None
  }
  let mut matched_count = 0
  // --head: show HEAD first
  if show_head {
    match @bitlib.resolve_ref(fs, git_dir, "HEAD") {
      Some(head_id) => {
        // --head always shows HEAD regardless of patterns
        matched_count += 1
        if not(quiet) {
          if hash_only {
            print_line(head_id.to_hex())
          } else {
            print_line("\{head_id.to_hex()} HEAD")
          }
        }
      }
      None => ()
    }
  }
  for item in refs {
    let (refname, id) = item
    if heads_only || tags_only {
      let is_head = refname.has_prefix("refs/heads/")
      let is_tag = refname.has_prefix("refs/tags/")
      let type_match = (heads_only && is_head) || (tags_only && is_tag)
      if not(type_match) {
        continue
      }
    }
    if patterns.length() > 0 {
      let mut matched = false
      for pattern in patterns {
        if refname == pattern ||
          refname.has_suffix("/" + pattern) ||
          refname.has_prefix(pattern) {
          matched = true
          break
        }
      }
      if not(matched) {
        continue
      }
    }
    matched_count += 1
    if not(quiet) {
      if hash_only {
        print_line(id.to_hex())
      } else {
        print_line("\{id.to_hex()} \{refname}")
      }
      if dereference {
        show_ref_deref(db.unwrap(), fs, id, refname, hash_only)
      }
    }
  }
  if matched_count == 0 {
    @sys.exit(1)
  }
}

///|
async fn show_ref_deref(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  id : @bitcore.ObjectId,
  refname : String,
  hash_only : Bool,
) -> Unit raise Error {
  // Dereference: if the object is a tag, show the dereferenced object
  let obj = db.get(fs, id) catch { _ => return }
  guard obj is Some(o) else { return }
  if o.obj_type == @bitcore.ObjectType::Tag {
    // Parse tag to get target object ID
    let text = decode_bytes(o.data)
    let mut target_hex = ""
    for line_view in text.split("\n") {
      let line = line_view.to_string()
      if line.length() == 0 {
        break
      }
      if line.has_prefix("object ") {
        target_hex = line[7:].to_string()
        break
      }
    }
    if target_hex.length() > 0 {
      let target_id = @bitcore.ObjectId::from_hex(target_hex) catch {
        _ => return
      }
      if hash_only {
        print_line(target_id.to_hex())
      } else {
        print_line("\{target_id.to_hex()} \{refname}^{}")
      }
    }
  }
}

///|
fn show_ref_exists_without_resolution(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> Bool {
  // Accept HEAD and special refs (FETCH_HEAD, ORIG_HEAD, etc.)
  let normalized = if refname == "HEAD" ||
    refname == "FETCH_HEAD" ||
    refname == "ORIG_HEAD" ||
    refname == "MERGE_HEAD" ||
    refname == "CHERRY_PICK_HEAD" ||
    refname == "REVERT_HEAD" ||
    refname == "BISECT_HEAD" {
    refname
  } else {
    let normalized = @bitlib.normalize_repo_path(refname) catch {
      _ => return false
    }
    if not(normalized.has_prefix("refs/")) {
      return false
    }
    normalized
  }
  let loose_path = git_dir + "/" + normalized
  if fs.is_file(loose_path) {
    return true
  }
  let packed_refs_path = git_dir + "/packed-refs"
  if not(fs.is_file(packed_refs_path)) {
    return false
  }
  let content = decode_bytes(
    fs.read_file(packed_refs_path) catch {
      _ => return false
    },
  )
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    match line.find(" ") {
      Some(idx) => {
        let packed_ref = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if packed_ref == normalized {
          return true
        }
      }
      None => ()
    }
  }
  false
}

///|
