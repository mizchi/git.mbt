///|
async fn handle_checkout(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  check_and_exit_unsupported_attrs(root)
  // Parse arguments
  let mut saw_separator = false
  let mut create_branch = false
  let mut force_create = false
  let mut force_checkout = false
  let mut orphan_branch = false
  let mut track_branch = false
  let pre_separator_targets : Array[String] = []
  let post_separator_targets : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--" => saw_separator = true
      "-b" => create_branch = true
      "-B" => {
        create_branch = true
        force_create = true
      }
      "--track" => track_branch = true
      "-f" | "--force" => force_checkout = true
      "--orphan" => orphan_branch = true
      "-" =>
        if saw_separator {
          post_separator_targets.push(arg)
        } else {
          pre_separator_targets.push(arg)
        }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("checkout", arg)
      _ =>
        if saw_separator {
          post_separator_targets.push(arg)
        } else {
          pre_separator_targets.push(arg)
        }
    }
    i += 1
  }
  let targets = pre_separator_targets
  if not(saw_separator) && targets.length() == 0 {
    raise @bitcore.GitError::InvalidObject("No target specified for checkout")
  }
  if is_bare_repo_dir(root) {
    raise @bitcore.GitError::InvalidObject(
      "this operation must be run in a work tree",
    )
  }
  if orphan_branch {
    if saw_separator || targets.length() != 1 {
      raise @bitcore.GitError::InvalidObject("No branch specified")
    }
    let previous_location = current_checkout_location(rfs, git_dir)
    let branch_name = targets[0]
    match checkout_branch_in_use_path(rfs, root, branch_name) {
      Some(path) => checkout_raise_branch_in_use(branch_name, path)
      None => ()
    }
    if @bitlib.resolve_ref(fs, git_dir, "refs/heads/" + branch_name) is Some(_) {
      raise @bitcore.GitError::InvalidObject(
        "branch '\{branch_name}' already exists",
      )
    }
    fs.write_string(git_dir + "/HEAD", "ref: refs/heads/" + branch_name + "\n")
    save_previous_checkout_location(fs, git_dir, previous_location)
    return ()
  }
  // git checkout -b <branch> [start-point]
  if create_branch {
    let previous_location = current_checkout_location(rfs, git_dir)
    let branch_name = targets[0]
    let start_point = if targets.length() > 1 { Some(targets[1]) } else { None }
    match checkout_branch_in_use_path(rfs, root, branch_name) {
      Some(path) => checkout_raise_branch_in_use(branch_name, path)
      None => ()
    }
    // Check if branch already exists
    let branch_exists = @bitlib.resolve_ref(
        fs,
        git_dir,
        "refs/heads/" + branch_name,
      )
      is Some(_)
    if branch_exists && not(force_create) {
      raise @bitcore.GitError::InvalidObject(
        "branch '\{branch_name}' already exists",
      )
    }
    // For start point, first checkout to that commit, then create branch
    match start_point {
      Some(ref_name) => {
        let commit_id = @bitrepo.rev_parse(fs, git_dir, ref_name)
        guard commit_id is Some(_) else {
          raise @bitcore.GitError::InvalidObject(
            "unknown revision: \{ref_name}",
          )
        }
        // Checkout the start point first (detached)
        let _ = checkout_with_promisor_retry(fs, root, ref_name, detach=true)
        // Then create and switch to new branch
        @bitlib.switch_branch(fs, fs, root, branch_name, create=true)
        if track_branch {
          checkout_apply_tracking_config(
            fs, rfs, git_dir, branch_name, ref_name,
          )
        }
      }
      None =>
        // Same commit, just create branch ref and update HEAD
        @bitlib.switch_branch(
          fs,
          fs,
          root,
          branch_name,
          create=true,
          checkout_files=false,
        )
    }
    save_previous_checkout_location(fs, git_dir, previous_location)
    return ()
  }
  // If -- was used, treat suffix arguments as file paths, optionally from a tree-ish.
  if saw_separator {
    if post_separator_targets.length() == 0 {
      raise @bitcore.GitError::InvalidObject("No paths specified for checkout")
    }
    if targets.length() == 0 {
      @bitlib.restore_paths(fs, fs, root, post_separator_targets)
    } else if targets.length() == 1 {
      checkout_restore_paths_from_spec(
        fs,
        rfs,
        root,
        git_dir,
        targets[0],
        post_separator_targets,
      )
    } else {
      raise @bitcore.GitError::InvalidObject(
        "Only one tree-ish can be used with path checkout",
      )
    }
    return ()
  }
  // Single target: determine if it's a branch or file
  if targets.length() == 1 {
    let target = resolve_checkout_target(rfs, git_dir, targets[0])
    let is_path = fs.is_file(root + "/" + target) ||
      fs.is_dir(root + "/" + target) ||
      checkout_target_is_tracked_path(rfs, git_dir, target)
    let is_branch = @bitlib.resolve_ref(fs, git_dir, "refs/heads/" + target)
      is Some(_)
    let current_branch_matches = match @bitlib.read_head_ref(rfs, git_dir) {
      Branch(name) => name == target
      _ => false
    }
    if is_branch && current_branch_matches {
      return ()
    }
    let previous_location = current_checkout_location(rfs, git_dir)
    let previous_head_id = @bitrepo.rev_parse(rfs, git_dir, "HEAD")
    let mut switched_head = false
    let mut switched_head_id : @bitcore.ObjectId? = None
    let mut switched_target : String? = None
    if is_path && is_branch {
      // Ambiguous - default to branch (like git)
      match checkout_branch_in_use_path(rfs, root, target) {
        Some(path) => checkout_raise_branch_in_use(target, path)
        None => ()
      }
      switched_head_id = Some(checkout_with_promisor_retry(fs, root, target))
      switched_target = Some(targets[0])
      switched_head = true
    } else if is_path {
      // Restore single file
      @bitlib.restore_paths(fs, fs, root, [target])
    } else {
      // Try as branch/commit
      match checkout_branch_in_use_path(rfs, root, target) {
        Some(path) => checkout_raise_branch_in_use(target, path)
        None => ()
      }
      switched_head_id = Some(checkout_with_promisor_retry(fs, root, target))
      switched_target = Some(targets[0])
      switched_head = true
    }
    if switched_head {
      if force_checkout {
        checkout_cleanup_merge_state_files(fs, git_dir)
      }
      match (previous_head_id, switched_head_id) {
        (Some(old_id), Some(new_id)) =>
          checkout_append_head_reflog(
            fs,
            rfs,
            git_dir,
            previous_location.unwrap_or(old_id.to_hex()),
            switched_target.unwrap_or(targets[0]),
            old_id,
            new_id,
          )
        _ => ()
      }
      save_previous_checkout_location(fs, git_dir, previous_location)
    }
  } else {
    // Multiple targets: treat as file paths
    @bitlib.restore_paths(fs, fs, root, targets)
  }
}

///|
fn checkout_cleanup_merge_state_files(
  fs : &@bitcore.FileSystem,
  git_dir : String,
) -> Unit raise Error {
  let files = ["MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "SQUASH_MSG"]
  for file in files {
    fs.remove_file(git_dir + "/" + file) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
  }
}

///|
fn checkout_append_head_reflog(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  from_label : String,
  to_label : String,
  old_id : @bitcore.ObjectId,
  new_id : @bitcore.ObjectId,
) -> Unit raise Error {
  let name = match @sys.get_env_var("GIT_COMMITTER_NAME") {
    Some(n) => n
    None => @sys.get_env_var("USER").unwrap_or("Unknown")
  }
  let email = match @sys.get_env_var("GIT_COMMITTER_EMAIL") {
    Some(e) => e
    None =>
      match @sys.get_env_var("USER") {
        Some(u) => u + "@localhost"
        None => "unknown@localhost"
      }
  }
  @bitlib.append_reflog(
    fs,
    rfs,
    git_dir,
    "HEAD",
    old_id,
    new_id,
    name,
    email,
    get_commit_timestamp(),
    get_commit_timezone(),
    "checkout: moving from " + from_label + " to " + to_label,
  )
}

///|
fn checkout_branch_in_use_path(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  branch : String,
) -> String? raise Error {
  let git_dir = resolve_git_dir(fs, root)
  match @bitlib.read_head_ref(fs, git_dir) {
    Branch(current) if current == branch => return None
    _ => ()
  }
  match @bitlib.is_branch_checked_out(fs, root, branch) {
    Some(path) =>
      if normalize_path(path) == normalize_path(root) {
        None
      } else {
        Some(path)
      }
    None => None
  }
}

///|
fn checkout_raise_branch_in_use(
  branch : String,
  path : String,
) -> Unit raise Error {
  raise @bitcore.GitError::InvalidObject(
    "'\{branch}' is already used by worktree at '\{path}'",
  )
}

///|
fn checkout_parse_tracking_source(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> (String, String)? {
  let normalized = if spec.has_prefix("refs/remotes/") {
    String::unsafe_substring(
      spec,
      start="refs/remotes/".length(),
      end=spec.length(),
    )
  } else {
    spec
  }
  let parts : Array[String] = []
  for part in normalized.split("/") {
    parts.push(part.to_string())
  }
  if parts.length() < 2 {
    return None
  }
  let remote = parts[0]
  let (remotes, _) = @bitlib.read_repo_config(rfs, git_dir)
  if not(remotes.contains(remote)) {
    return None
  }
  let branch = String::unsafe_substring(
    normalized,
    start=remote.length() + 1,
    end=normalized.length(),
  )
  Some((remote, "refs/heads/" + branch))
}

///|
fn checkout_apply_tracking_config(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  branch_name : String,
  start_point : String,
) -> Unit raise Error {
  match checkout_parse_tracking_source(rfs, git_dir, start_point) {
    Some((remote, merge_ref)) => {
      @bitlib.set_config_key(
        fs, rfs, git_dir, "branch", branch_name, "remote", remote,
      )
      @bitlib.set_config_key(
        fs, rfs, git_dir, "branch", branch_name, "merge", merge_ref,
      )
    }
    None => ()
  }
}

///|
fn checkout_restore_paths_from_spec(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  spec : String,
  paths : Array[String],
) -> Unit raise Error {
  checkout_restore_paths_from_spec_mode(
    fs,
    rfs,
    root,
    git_dir,
    spec,
    paths,
    update_worktree=true,
    update_index=true,
  )
}

///|
fn checkout_restore_remove_worktree_path(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  path : String,
) -> Unit {
  let abs_path = root + "/" + path
  if rfs.is_dir(abs_path) {
    @bitlib.subdir_remove_dir(rfs, fs, abs_path)
  } else {
    fs.remove_file(abs_path) catch {
      _ => ()
    }
  }
}

///|
fn checkout_restore_paths_from_spec_mode(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  spec : String,
  paths : Array[String],
  update_worktree? : Bool = true,
  update_index? : Bool = true,
) -> Unit raise Error {
  let target = resolve_checkout_target(rfs, git_dir, spec)
  let resolved = @bitrepo.rev_parse(rfs, git_dir, target)
  guard resolved is Some(raw_id) else {
    raise @bitcore.GitError::InvalidObject("Invalid ref: \{target}")
  }
  let tree_id = @bitrepo.rev_parse(rfs, git_dir, target + "^{tree}").unwrap_or(
    raw_id,
  )
  let object_git_dir = checkout_resolve_common_git_dir(rfs, git_dir)
  let db = @bitlib.ObjectDb::load(rfs, object_git_dir)
  let files = @bitlib.collect_tree_files(db, rfs, tree_id)
  let current_entries = @bitlib.read_index_entries(rfs, git_dir)
  let tracked_paths : Map[String, Bool] = {}
  for entry in current_entries {
    tracked_paths[entry.path] = true
  }
  let selected : Map[String, @bitlib.TreeFileEntry] = {}
  let removed_paths : Map[String, Bool] = {}
  for path in paths {
    let safe_path = @bitlib.normalize_repo_path(path)
    match files.get(safe_path) {
      Some(entry) => selected[safe_path] = entry
      None =>
        if tracked_paths.contains(safe_path) {
          removed_paths[safe_path] = true
        } else {
          raise @bitcore.GitError::InvalidObject(
            "error: pathspec '\{path}' did not match any file(s) known to git",
          )
        }
    }
  }
  if update_worktree {
    if selected.to_array().length() > 0 {
      @bitlib.write_worktree_from_files(db, fs, rfs, root, git_dir, selected)
    }
    for path, _ in removed_paths {
      checkout_restore_remove_worktree_path(fs, rfs, root, path)
    }
  }
  if update_index {
    let restored_entries = @bitlib.tree_files_to_index(db, rfs, selected)
    let selected_paths : Map[String, Bool] = {}
    for path, _ in selected {
      selected_paths[path] = true
    }
    for path, _ in removed_paths {
      selected_paths[path] = true
    }
    let merged_entries : Array[@bitlib.IndexEntry] = []
    for entry in current_entries {
      if not(selected_paths.contains(entry.path)) {
        merged_entries.push(entry)
      }
    }
    for entry in restored_entries {
      merged_entries.push(entry)
    }
    @bitlib.write_index_entries(fs, git_dir, merged_entries)
  }
}

///|
fn checkout_resolve_common_git_dir(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> String {
  let commondir_path = git_dir + "/commondir"
  if not(fs.is_file(commondir_path)) {
    return git_dir
  }
  let raw = decode_bytes(fs.read_file(commondir_path) catch { _ => b"" })
  let rel = trim_string(raw)
  if rel.length() == 0 {
    return git_dir
  }
  if rel.has_prefix("/") {
    normalize_path(rel)
  } else {
    normalize_path(git_dir + "/" + rel)
  }
}

///|
fn checkout_target_is_tracked_path(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  target : String,
) -> Bool {
  if target == "-" {
    return false
  }
  let normalized = if target.has_prefix("./") {
    String::unsafe_substring(target, start=2, end=target.length())
  } else {
    target
  }
  if normalized.length() == 0 {
    return false
  }
  let path = @bitlib.normalize_repo_path(normalized) catch { _ => return false }
  let entries = @bitlib.read_index_entries(fs, git_dir) catch {
    _ => return false
  }
  for entry in entries {
    if entry.path == path || entry.path.has_prefix(path + "/") {
      return true
    }
  }
  false
}

///|
async fn checkout_with_promisor_retry(
  fs : OsFs,
  root : String,
  spec : String,
  detach? : Bool = false,
) -> @bitcore.ObjectId raise Error {
  let git_dir = resolve_git_dir(fs, root)
  let mut checkout_spec = spec
  let mut checkout_detach = detach
  let mut resolved_target : @bitcore.ObjectId? = None
  if spec.contains("^") || spec.contains("~") {
    match @bitrepo.rev_parse(fs, git_dir, spec) {
      Some(id) => {
        resolved_target = Some(id)
        checkout_spec = id.to_hex()
        checkout_detach = true
      }
      None => ()
    }
  }
  let mut promisor_db : @bitlib.PromisorDb? = None
  let mut wrote_trace_round = false
  match resolved_target {
    Some(target_id) => {
      let pdb = @bitlibnative.native_promisor_db(fs, git_dir)
      if pdb.has_promisor() {
        let missing_ids = collect_missing_checkout_blob_ids(
          fs, git_dir, target_id,
        )
        if missing_ids.length() > 0 {
          ignore(pdb.fetch_missing(fs, missing_ids))
          if not(wrote_trace_round) {
            append_checkout_fetch_trace(fs)
            wrote_trace_round = true
          }
        }
        promisor_db = Some(pdb)
      }
    }
    None => ()
  }
  let mut attempts = 0
  while attempts < 16 {
    let result : Result[@bitcore.ObjectId, Error] = try? run_checkout_with_sensitive_hooks(
      fs,
      fs,
      root,
      checkout_spec,
      detach=checkout_detach,
    )
    match result {
      Ok(id) => {
        if @bitlib.is_sparse_checkout_enabled(fs, git_dir) {
          @bitlib.sparse_checkout_reapply(fs, fs, root)
        }
        return id
      }
      Err(err) =>
        match parse_checkout_missing_object_id(err) {
          Some(missing_id) => {
            let pdb = match promisor_db {
              Some(db) => db
              None => {
                let db = @bitlibnative.native_promisor_db(fs, git_dir)
                if not(db.has_promisor()) {
                  raise err
                }
                promisor_db = Some(db)
                db
              }
            }
            let fetched = pdb.fetch_missing(fs, [missing_id])
            if fetched.length() == 0 {
              raise err
            }
            if not(wrote_trace_round) {
              append_checkout_fetch_trace(fs)
              wrote_trace_round = true
            }
            attempts += 1
          }
          None => raise err
        }
    }
  }
  raise @bitcore.GitError::InvalidObject(
    "checkout lazy-fetch retry limit exceeded",
  )
}

///|
fn collect_missing_checkout_blob_ids(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  commit_id : @bitcore.ObjectId,
) -> Array[@bitcore.ObjectId] raise Error {
  let db = @bitlib.ObjectDb::load_lazy(fs, git_dir)
  db.set_skip_verify(true)
  let files = @bitlib.collect_tree_files_from_commit(db, fs, commit_id) catch {
    _ => return []
  }
  let missing : Array[@bitcore.ObjectId] = []
  let seen : Map[String, Bool] = {}
  for item in files.to_array() {
    let (_, entry) = item
    if entry.mode == 0o160000 {
      continue
    }
    let hex = entry.id.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    if db.get(fs, entry.id) is None {
      missing.push(entry.id)
    }
  }
  missing
}

///|
fn append_checkout_fetch_trace(fs : OsFs) -> Unit {
  match @sys.get_env_var("GIT_TRACE_PACKET") {
    Some(path) => append_checkout_trace_line(fs, path, "fetch> done\n")
    None => ()
  }
  match @sys.get_env_var("GIT_TRACE2_EVENT") {
    Some(path) =>
      append_checkout_trace_line(
        fs, path, "{\"event\":\"data\",\"category\":\"fetch\",\"key\":\"total_rounds\",\"value\":\"1\"}\n",
      )
    None => ()
  }
}

///|
fn append_checkout_trace_line(fs : OsFs, path : String, line : String) -> Unit {
  let existing = decode_bytes(fs.read_file(path) catch { _ => b"" })
  fs.write_string(path, existing + line) catch {
    _ => ()
  }
}

///|
fn resolve_checkout_target(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  target : String,
) -> String raise Error {
  if target != "-" {
    return target
  }
  match load_previous_checkout_location(fs, git_dir) {
    Some(prev) => prev
    None =>
      raise @bitcore.GitError::InvalidObject(
        "No previous checkout target available",
      )
  }
}

///|
fn current_checkout_location(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> String? raise Error {
  let head_path = git_dir + "/HEAD"
  match @bitio.read_symlink_target_path(head_path) {
    Some(target) if target.has_prefix("refs/heads/") =>
      return Some(
        String::unsafe_substring(target, start=11, end=target.length()),
      )
    Some(target) if target.has_prefix("refs/") => return Some(target)
    _ => ()
  }
  if not(fs.is_file(head_path)) {
    return None
  }
  let head = trim_string(@utf8.decode_lossy(fs.read_file(head_path)[:]))
  if head.length() == 0 {
    return None
  }
  if head.has_prefix("ref: refs/heads/") {
    return Some(String::unsafe_substring(head, start=16, end=head.length()))
  }
  if head.has_prefix("ref: ") {
    return Some(String::unsafe_substring(head, start=5, end=head.length()))
  }
  Some(head)
}

///|
fn checkout_prev_location_path(git_dir : String) -> String {
  git_dir + "/bit-prev-checkout"
}

///|
fn load_previous_checkout_location(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> String? raise Error {
  let path = checkout_prev_location_path(git_dir)
  if not(fs.is_file(path)) {
    return None
  }
  let prev = trim_string(@utf8.decode_lossy(fs.read_file(path)[:]))
  if prev.length() == 0 {
    None
  } else {
    Some(prev)
  }
}

///|
fn save_previous_checkout_location(
  fs : &@bitcore.FileSystem,
  git_dir : String,
  location : String?,
) -> Unit raise Error {
  match location {
    Some(value) if value.length() > 0 =>
      fs.write_string(checkout_prev_location_path(git_dir), value + "\n")
    _ => ()
  }
}

///|
fn parse_checkout_missing_object_id(err : Error) -> @bitcore.ObjectId? {
  let prefixes = [
    "Missing blob object: ", "Missing tree object: ", "Object not found: ",
  ]
  match err {
    @bitcore.GitError::InvalidObject(msg) => {
      for prefix in prefixes {
        if msg.has_prefix(prefix) {
          let hex = String::unsafe_substring(
            msg,
            start=prefix.length(),
            end=msg.length(),
          )
          return Some(@bitcore.ObjectId::from_hex(trim_string(hex))) catch {
            _ => None
          }
        }
      }
      None
    }
    _ => None
  }
}

///|
