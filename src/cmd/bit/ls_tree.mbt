///|
async fn handle_ls_tree(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  let mut recursive = false
  let mut show_trees = false // -t option
  let mut only_trees = false // -d option: only show trees
  let mut name_only = false
  let mut name_status = false
  let mut object_only = false
  let mut long_mode = false
  let mut format_str : String? = None
  let mut _full_name = false
  let mut _full_tree = false
  let mut _abbrev : Int? = None
  let mut recurse_submodules = false
  let positional : Array[String] = []
  for arg in args {
    match arg {
      "-r" | "--recursive" => recursive = true
      "-t" => show_trees = true
      "-d" => only_trees = true
      "--name-only" => name_only = true
      "--name-status" => name_status = true
      "--object-only" => object_only = true
      "-l" | "--long" => long_mode = true
      "--full-name" => _full_name = true
      "--full-tree" => _full_tree = true
      "--recurse-submodules" => recurse_submodules = true
      _ if arg.has_prefix("--format=") => format_str = Some(arg[9:].to_string())
      _ if arg.has_prefix("--abbrev=") => {
        let v = arg[9:].to_string()
        _abbrev = Some(@strconv.parse_int(v)) catch { _ => Some(7) }
      }
      "--abbrev" => _abbrev = Some(7)
      _ if not(arg.has_prefix("-")) => positional.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("ls-tree", arg)
      _ => ()
    }
  }
  // Validate incompatible options
  // git uses a cmdmode enum; we check pairs explicitly.
  // Each format-altering option conflicts with the others and with --format.
  let has_format = format_str is Some(_)
  if long_mode && name_only {
    eprint_line(
      "error: options '--name-only' and '--long' cannot be used together",
    )
    @sys.exit(129)
  }
  if long_mode && name_status {
    eprint_line(
      "error: options '--name-status' and '--long' cannot be used together",
    )
    @sys.exit(129)
  }
  if name_only && name_status {
    eprint_line(
      "error: options '--name-status' and '--name-only' cannot be used together",
    )
    @sys.exit(129)
  }
  if name_status && object_only {
    eprint_line(
      "error: options '--object-only' and '--name-status' cannot be used together",
    )
    @sys.exit(129)
  }
  if name_only && object_only {
    eprint_line(
      "error: options '--object-only' and '--name-only' cannot be used together",
    )
    @sys.exit(129)
  }
  if object_only && long_mode {
    eprint_line(
      "error: options '--long' and '--object-only' cannot be used together",
    )
    @sys.exit(129)
  }
  if has_format {
    let other = if long_mode {
      "--long"
    } else if name_only {
      "--name-only"
    } else if name_status {
      "--name-status"
    } else if object_only {
      "--object-only"
    } else {
      ""
    }
    if other.length() > 0 {
      eprint_line(
        "error: options '\{other}' and '--format' cannot be used together",
      )
      @sys.exit(129)
    }
  }
  // Merge name_status into name_only for output logic
  if name_status {
    name_only = true
  }
  guard positional.length() > 0 else {
    raise @bitcore.GitError::InvalidObject("tree-ish required")
  }
  let spec = positional[0]
  // Path filters are remaining positional arguments
  let path_filters : Array[String] = []
  for i in 1..<positional.length() {
    path_filters.push(positional[i])
  }
  let cwd_prefix = compute_cwd_prefix(root)
  let normalized_filters = normalize_ls_tree_filters(path_filters, cwd_prefix)
  let tree_id = @bitrepo.rev_parse(fs, git_dir, spec)
  guard tree_id is Some(tid) else {
    raise @bitcore.GitError::InvalidObject("Not a valid object name: \{spec}")
  }
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  // Resolve to tree if it's a commit
  let actual_tree_id = resolve_to_tree(db, fs, tid)
  // Parse submodules if needed
  let submodules = if recurse_submodules {
    parse_gitmodules(fs, root)
  } else {
    []
  }
  print_tree_entries(
    db, fs, actual_tree_id, "", recursive, show_trees, only_trees, name_only, recurse_submodules,
    root, submodules, cwd_prefix, normalized_filters,
  )
}

///|
fn resolve_to_tree(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  id : @bitcore.ObjectId,
) -> @bitcore.ObjectId raise @bitcore.GitError {
  let obj = db.get(fs, id)
  guard obj is Some(o) else {
    raise @bitcore.GitError::InvalidObject("Object not found")
  }
  match o.obj_type {
    @bitcore.ObjectType::Tree => id
    @bitcore.ObjectType::Commit => {
      let info = @bitcore.parse_commit(o.data)
      info.tree
    }
    _ => raise @bitcore.GitError::InvalidObject("Not a tree or commit")
  }
}

///|
async fn print_tree_entries(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  tree_id : @bitcore.ObjectId,
  prefix : String,
  recursive : Bool,
  show_trees : Bool,
  only_trees : Bool,
  name_only : Bool,
  recurse_submodules : Bool,
  root : String,
  submodules : Array[SubmoduleInfo],
  cwd_prefix : String,
  path_filters : Array[String],
) -> Unit raise Error {
  let obj = db.get(fs, tree_id)
  guard obj is Some(o) else {
    raise @bitcore.GitError::InvalidObject("Tree not found")
  }
  let entries = @bitcore.parse_tree(o.data)
  for entry in entries {
    let path = if prefix.length() == 0 {
      entry.name
    } else {
      prefix + "/" + entry.name
    }
    let is_tree = entry.mode == "40000" || entry.mode == "040000"
    let is_submodule = entry.mode == "160000"
    // Path filtering logic
    let (matches_filter, should_recurse_for_filter) = if path_filters.length() ==
      0 {
      (true, true)
    } else {
      let mut match_found = false
      let mut recurse_needed = false
      for filter in path_filters {
        if path == filter || path.has_prefix(filter + "/") {
          match_found = true
        }
        // Filter is under the entry path (need to recurse into this tree to find it)
        if filter.has_prefix(path + "/") {
          recurse_needed = true
        }
      }
      (match_found, recurse_needed)
    }
    if not(matches_filter) && not(should_recurse_for_filter) {
      continue
    }
    // Skip submodule entries when recurse_submodules is enabled
    // (we'll recurse into them instead of listing them)
    if recurse_submodules && is_submodule {
      // Find matching submodule info
      let mut found_submod = false
      for s in submodules {
        if s.path == path {
          found_submod = true
          break
        }
      }
      if found_submod {
        // Resolve the submodule's git directory
        let sub_git_path = root + "/" + path + "/.git"
        let sub_git_dir = @bitlib.resolve_gitdir(fs, sub_git_path)
        // Load the submodule's object database
        let sub_db = @bitlib.ObjectDb::load(fs, sub_git_dir)
        // entry.id is the commit SHA in the submodule
        // Resolve it to a tree
        let sub_tree_id = resolve_to_tree(sub_db, fs, entry.id) catch {
          err if @async.is_cancellation_error(err) => raise err
          _ => continue // Skip if can't resolve submodule tree
        }
        // Recursively print submodule tree entries
        print_tree_entries(
          sub_db,
          fs,
          sub_tree_id,
          path,
          recursive,
          show_trees,
          only_trees,
          name_only,
          recurse_submodules,
          root + "/" + path,
          [], // No nested submodules for now
          cwd_prefix,
          path_filters,
        )
      }
      continue
    }
    // With -d, only show tree entries
    // With -r, don't print tree entries unless -t is also specified
    // With -t and path filters, show tree entries we're traversing through
    let should_print = if not(matches_filter) &&
      not(show_trees && should_recurse_for_filter && is_tree) {
      false // Don't print if path doesn't match filters (unless -t and traversing trees)
    } else if only_trees {
      is_tree // Only print tree entries
    } else {
      not(recursive) || not(is_tree) || show_trees
    }
    if should_print {
      let display_path = make_display_path(path, cwd_prefix)
      if name_only {
        print_line(display_path)
      } else {
        let mode_str = if entry.mode == "40000" { "040000" } else { entry.mode }
        let type_str = if is_tree {
          "tree"
        } else if is_submodule {
          "commit"
        } else {
          "blob"
        }
        print_line(
          "\{mode_str} \{type_str} \{entry.id.to_hex()}\t\{display_path}",
        )
      }
    }
    // Recurse if -r is set, or if we need to look deeper for path filters
    // (but only for filter recursion when actually needed, not when filters are empty)
    let need_recurse = recursive ||
      (should_recurse_for_filter && path_filters.length() > 0)
    if need_recurse && is_tree {
      print_tree_entries(
        db,
        fs,
        entry.id,
        path,
        recursive,
        show_trees,
        only_trees,
        name_only,
        recurse_submodules,
        root,
        submodules,
        cwd_prefix,
        path_filters,
      )
    }
  }
}

///|
