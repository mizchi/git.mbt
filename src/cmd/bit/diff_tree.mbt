///|
/// git diff-tree: Compare trees or commits

///|
priv struct DiffTreeEntry {
  id : @bitcore.ObjectId
  mode : String
}

///|
async fn handle_diff_tree(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  // Parse flags
  let mut recursive = false
  let mut patch = false
  let mut name_only = false
  let mut name_status = false
  let mut no_commit_id = false
  let mut show_tree = false
  let mut show_root = false
  let mut suppress = false
  let mut diff_filter : String? = None
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-r" => recursive = true
      "-p" | "-u" | "--patch" => {
        patch = true
        recursive = true
      }
      "--name-only" => name_only = true
      "--name-status" => name_status = true
      "--no-commit-id" => no_commit_id = true
      "-t" => show_tree = true
      "--root" => show_root = true
      "-s" => suppress = true
      "--stdin" => ()
      "--" => {
        i += 1
        while i < args.length() {
          positional.push(args[i])
          i += 1
        }
        continue
      }
      _ if arg.has_prefix("--diff-filter=") =>
        diff_filter = Some(
          String::unsafe_substring(arg, start=14, end=arg.length()),
        )
      _ if not(arg.has_prefix("-")) => positional.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("diff-tree", arg)
      _ => ()
    }
    i += 1
  }
  if positional.length() == 0 {
    eprint_line("fatal: must give at least one tree")
    @sys.exit(128)
    return
  }
  let db = @bitlib.ObjectDb::load(rfs, git_dir)
  if positional.length() == 1 {
    // Single commit: diff parent tree vs commit tree
    let commit_hex = positional[0]
    let commit_id = commit_tree_resolve_hex(rfs, git_dir, commit_hex)
    let obj = db.get(rfs, commit_id)
    guard obj is Some(commit_obj) else {
      eprint_line("fatal: bad object \{commit_hex}")
      @sys.exit(128)
      return
    }
    if commit_obj.obj_type != @bitcore.ObjectType::Commit {
      eprint_line("fatal: not a commit object")
      @sys.exit(128)
      return
    }
    let info = @bitcore.parse_commit(commit_obj.data)
    let old_tree : @bitcore.ObjectId? = if info.parents.length() > 0 {
      let parent_obj = db.get(rfs, info.parents[0])
      match parent_obj {
        Some(pobj) => {
          let parent_info = @bitcore.parse_commit(pobj.data)
          Some(parent_info.tree)
        }
        None => None
      }
    } else if show_root {
      None
    } else {
      return
    }
    if not(no_commit_id) {
      print_line(commit_id.to_hex())
    }
    if not(suppress) {
      diff_tree_output(
        db,
        rfs,
        old_tree,
        info.tree,
        recursive,
        patch,
        name_only,
        name_status,
        show_tree,
        diff_filter,
        git_dir,
      )
    }
  } else {
    // Two trees
    let old_id = commit_tree_resolve_hex(rfs, git_dir, positional[0])
    let new_id = commit_tree_resolve_hex(rfs, git_dir, positional[1])
    let old_tree = diff_tree_resolve_to_tree(db, rfs, old_id)
    let new_tree = diff_tree_resolve_to_tree(db, rfs, new_id)
    if not(suppress) {
      diff_tree_output(
        db,
        rfs,
        Some(old_tree),
        new_tree,
        recursive,
        patch,
        name_only,
        name_status,
        show_tree,
        diff_filter,
        git_dir,
      )
    }
  }
}

///|
fn diff_tree_resolve_to_tree(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  id : @bitcore.ObjectId,
) -> @bitcore.ObjectId raise Error {
  let obj = db.get(fs, id)
  guard obj is Some(o) else {
    raise @bitcore.GitError::InvalidObject("bad object \{id.to_hex()}")
  }
  if o.obj_type == @bitcore.ObjectType::Tree {
    return id
  }
  if o.obj_type == @bitcore.ObjectType::Commit {
    let info = @bitcore.parse_commit(o.data)
    return info.tree
  }
  raise @bitcore.GitError::InvalidObject("not a tree or commit object")
}

///|
fn diff_tree_collect_entries(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  tree_id : @bitcore.ObjectId,
  prefix : String,
  recursive : Bool,
  show_tree : Bool,
  out : Map[String, DiffTreeEntry],
) -> Unit raise Error {
  let obj = db.get(fs, tree_id)
  guard obj is Some(tree_obj) else {
    raise @bitcore.GitError::InvalidObject("Missing tree object")
  }
  let entries = @bitcore.parse_tree(tree_obj.data)
  for entry in entries {
    let path = if prefix.length() == 0 {
      entry.name
    } else {
      prefix + "/" + entry.name
    }
    let is_tree = entry.mode == "40000" || entry.mode == "040000"
    if is_tree {
      if show_tree {
        out[path] = { id: entry.id, mode: "040000" }
      }
      if recursive || show_tree {
        diff_tree_collect_entries(
          db,
          fs,
          entry.id,
          path,
          recursive,
          show_tree,
          out,
        )
      } else {
        out[path] = { id: entry.id, mode: "040000" }
      }
    } else {
      out[path] = { id: entry.id, mode: entry.mode }
    }
  }
}

///|
async fn diff_tree_output(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  old_tree : @bitcore.ObjectId?,
  new_tree : @bitcore.ObjectId,
  recursive : Bool,
  patch : Bool,
  name_only : Bool,
  name_status : Bool,
  show_tree : Bool,
  diff_filter : String?,
  git_dir : String,
) -> Unit raise Error {
  let old_entries : Map[String, DiffTreeEntry] = {}
  let new_entries : Map[String, DiffTreeEntry] = {}
  match old_tree {
    Some(ot) =>
      diff_tree_collect_entries(
        db, fs, ot, "", recursive, show_tree, old_entries,
      )
    None => ()
  }
  diff_tree_collect_entries(
    db, fs, new_tree, "", recursive, show_tree, new_entries,
  )
  // Build diff results: (path, old_mode, new_mode, old_id, new_id, status)
  let results : Array[
    (String, String, String, @bitcore.ObjectId, @bitcore.ObjectId, String),
  ] = []
  let zero_id = @bitcore.ObjectId::zero()
  for path, entry in new_entries {
    match old_entries.get(path) {
      None =>
        if diff_tree_filter_matches(diff_filter, "A") {
          results.push((path, "000000", entry.mode, zero_id, entry.id, "A"))
        }
      Some(old_entry) =>
        if old_entry.id != entry.id || old_entry.mode != entry.mode {
          let status = if old_entry.mode != entry.mode &&
            old_entry.id == entry.id {
            "T"
          } else {
            "M"
          }
          if diff_tree_filter_matches(diff_filter, status) {
            results.push(
              (path, old_entry.mode, entry.mode, old_entry.id, entry.id, status),
            )
          }
        }
    }
  }
  for path, entry in old_entries {
    if not(new_entries.contains(path)) {
      if diff_tree_filter_matches(diff_filter, "D") {
        results.push((path, entry.mode, "000000", entry.id, zero_id, "D"))
      }
    }
  }
  results.sort_by(fn(a, b) { String::compare(a.0, b.0) })
  if patch {
    // Unified diff output using diff_trees from lib
    let diff_files = @bitlib.diff_trees(fs, git_dir, old_tree, new_tree)
    let lines = @bitlib.diff_text(diff_files)
    for line in lines {
      print_line(line)
    }
  } else if name_only {
    for item in results {
      print_line(item.0)
    }
  } else if name_status {
    for item in results {
      print_line("\{item.5}\t\{item.0}")
    }
  } else {
    // Raw format
    for item in results {
      let (path, old_mode, new_mode, old_id, new_id, status) = item
      let old_hex = old_id.to_hex()
      let new_hex = new_id.to_hex()
      print_line(
        ":\{old_mode} \{new_mode} \{old_hex} \{new_hex} \{status}\t\{path}",
      )
    }
  }
}

///|
fn diff_tree_filter_matches(filter : String?, status : String) -> Bool {
  match filter {
    None => true
    Some(f) => f.contains(status)
  }
}
