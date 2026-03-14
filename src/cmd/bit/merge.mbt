///|
async fn delegate_merge_to_real_git(args : Array[String], cwd : String) -> Unit {
  let argv : Array[String] = ["merge"]
  for arg in args {
    argv.push(arg)
  }
  let code = @process.run(
    resolve_real_git_for_dispatch(),
    argv,
    inherit_env=true,
    cwd~,
    stdin=@stdio.stdin,
    stdout=@stdio.stdout,
    stderr=@stdio.stderr,
  )
  @sys.exit(code)
}

///|
fn merge_count_merge_heads(args : Array[String]) -> Int {
  let mut count = 0
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" | "--message" | "-s" | "--strategy" | "-X" | "--strategy-option" => {
        i += 2
        continue
      }
      _ if arg.has_prefix("--message=") ||
        arg.has_prefix("--strategy=") ||
        arg.has_prefix("--strategy-option=") ||
        (arg.has_prefix("-m") && not(arg.has_prefix("--")) && arg.length() > 2) ||
        (arg.has_prefix("-X") && not(arg.has_prefix("--")) && arg.length() > 2) ||
        (arg.has_prefix("-s") && not(arg.has_prefix("--")) && arg.length() > 2) =>
        ()
      "--no-ff"
      | "--ff-only"
      | "--squash"
      | "--abort"
      | "--continue"
      | "--allow-unrelated-histories" => ()
      _ if not(arg.has_prefix("-")) => count += 1
      _ => ()
    }
    i += 1
  }
  count
}

///|
fn merge_need_real_git(args : Array[String]) -> Bool {
  if merge_count_merge_heads(args) > 1 {
    return true
  }
  for arg in args {
    if arg == "-s" ||
      arg == "--strategy" ||
      arg == "-X" ||
      arg == "--strategy-option" ||
      arg == "--allow-unrelated-histories" ||
      arg.has_prefix("--strategy=") ||
      arg.has_prefix("--strategy-option=") ||
      (arg.has_prefix("-X") && not(arg.has_prefix("--")) && arg.length() > 2) ||
      (arg.has_prefix("-s") && not(arg.has_prefix("--")) && arg.length() > 2) {
      return true
    }
  }
  false
}

///|
async fn handle_merge(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let cwd = root
  if merge_need_real_git(args) {
    delegate_merge_to_real_git(args, cwd)
    return
  }
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  check_and_exit_unsupported_attrs(root)
  let git_dir = root + "/.git"
  let wfs : &@bitcore.FileSystem = fs
  let mut target_ref : String? = None
  let mut message : String? = None
  let mut no_ff = false
  let mut ff_only = false
  let mut squash = false
  let mut quiet = false
  let mut abort_merge = false
  let mut continue_merge = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-m" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 2
        continue
      }
      "--message" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 2
        continue
      }
      "-m" =>
        raise @bitcore.GitError::InvalidObject("option '-m' requires a value")
      "--message" =>
        raise @bitcore.GitError::InvalidObject(
          "option '--message' requires a value",
        )
      _ if arg.has_prefix("-m") => {
        message = Some(string_slice_from(arg, 2))
        i += 1
        continue
      }
      _ if arg.has_prefix("--message=") => {
        message = Some(string_slice_from(arg, 10))
        i += 1
        continue
      }
      "--no-ff" => {
        no_ff = true
        i += 1
        continue
      }
      "--ff-only" => {
        ff_only = true
        i += 1
        continue
      }
      "--squash" => {
        squash = true
        i += 1
        continue
      }
      "-q" | "--quiet" => {
        quiet = true
        i += 1
        continue
      }
      "--abort" => {
        abort_merge = true
        i += 1
        continue
      }
      "--continue" => {
        continue_merge = true
        i += 1
        continue
      }
      _ if not(arg.has_prefix("-")) =>
        match target_ref {
          Some(_) =>
            raise @bitcore.GitError::InvalidObject(
              "multiple merge heads are not supported",
            )
          None => target_ref = Some(arg)
        }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("merge", arg)
      _ => ()
    }
    i += 1
  }
  // Handle --abort
  if abort_merge {
    let orig_head_path = git_dir + "/ORIG_HEAD"
    let merge_head_path = git_dir + "/MERGE_HEAD"
    if rfs.is_file(orig_head_path) {
      let orig_hex = rfs.read_file(orig_head_path)
        |> decode_bytes
        |> trim_string
      ignore(@bitlib.reset(wfs, rfs, root, orig_hex, @bitlib.ResetMode::Hard))
      wfs.remove_file(orig_head_path) catch {
        err if @async.is_cancellation_error(err) => raise err
        _ => ()
      }
      wfs.remove_file(merge_head_path) catch {
        err if @async.is_cancellation_error(err) => raise err
        _ => ()
      }
      wfs.remove_file(git_dir + "/MERGE_MSG") catch {
        err if @async.is_cancellation_error(err) => raise err
        _ => ()
      }
      if not(quiet) {
        print_line("Merge aborted.")
      }
    } else {
      @stdio.stderr.write(
        "fatal: There is no merge to abort (ORIG_HEAD missing).",
      )
      @sys.exit(128)
    }
    return
  }
  // Handle --continue
  if continue_merge {
    let merge_head_path = git_dir + "/MERGE_HEAD"
    let merge_msg_path = git_dir + "/MERGE_MSG"
    if not(rfs.is_file(merge_head_path)) {
      @stdio.stderr.write(
        "fatal: There is no merge in progress (MERGE_HEAD missing).",
      )
      @sys.exit(128)
    }
    // Commit the merge
    let msg = if rfs.is_file(merge_msg_path) {
      rfs.read_file(merge_msg_path) |> decode_bytes |> trim_string
    } else {
      "Merge commit"
    }
    let author = get_author_string()
    let timestamp = get_commit_timestamp()
    let merge_heads = read_merge_head_ids(rfs, git_dir)
    let commit_id = if merge_heads.length() > 0 {
      commit_with_merge_heads(
        wfs, rfs, root, msg, author, timestamp, author, timestamp, merge_heads, false,
      )
    } else {
      @bitlib.commit(wfs, rfs, root, msg, author, timestamp)
    }
    let short = String::unsafe_substring(commit_id.to_hex(), start=0, end=7)
    // Clean up merge state
    wfs.remove_file(merge_head_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    wfs.remove_file(merge_msg_path) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    wfs.remove_file(git_dir + "/ORIG_HEAD") catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
    if not(quiet) {
      print_line("[\{short}] \{msg}")
    }
    return
  }
  guard target_ref is Some(refspec) else {
    raise @bitcore.GitError::InvalidObject("No commit to merge specified")
  }
  validate_current_branch_mergeoptions(rfs, git_dir)
  // Check if subdir-clone and handle specially
  match get_subdir_info(fs, git_dir) {
    Some((_, subdir_path, _)) => {
      handle_subdir_merge(fs, root, git_dir, refspec, subdir_path, message) catch {
        err => raise err
      }
      return
    }
    None => ()
  }
  // Resolve target
  let target_id = @bitrepo.rev_parse(fs, git_dir, refspec)
  guard target_id is Some(tid) else {
    raise @bitcore.GitError::InvalidObject("unknown revision: \{refspec}")
  }
  if merge_target_requires_real_git(rfs, git_dir, tid) {
    delegate_merge_to_real_git(args, cwd)
    return
  }
  let author = get_author_string()
  let timestamp = get_commit_timestamp()
  let msg = message.unwrap_or("Merge \{refspec}")
  // Handle --squash
  if squash {
    // Squash merge: apply changes but don't commit
    let result = run_merge_with_sensitive_hooks(
      fs, fs, root, tid, msg, author, timestamp,
    )
    match result.status {
      @bitlib.MergeStatus::AlreadyUpToDate =>
        if not(quiet) {
          print_line("Already up to date.")
        }
      @bitlib.MergeStatus::FastForward | @bitlib.MergeStatus::Merged => {
        // Reset HEAD but keep working tree changes
        let head = @bitrepo.rev_parse(rfs, git_dir, "HEAD")
        match head {
          Some(h) =>
            // Reset index to HEAD but keep working tree
            ignore(
              @bitlib.reset(wfs, rfs, root, h.to_hex(), @bitlib.ResetMode::Soft),
            )
          None => ()
        }
        if not(quiet) {
          print_line("Squash commit -- not updating HEAD")
        }
        // Save merge message for later commit
        wfs.write_string(
          git_dir + "/SQUASH_MSG",
          "Squashed commit of the following:\n\n" + msg + "\n",
        )
      }
      @bitlib.MergeStatus::Conflicted => {
        if not(quiet) {
          print_line("CONFLICT: Merge conflict")
          for path in result.conflicts {
            print_line("  \{path}")
          }
        }
        @sys.exit(1)
      }
    }
    return
  }
  // Check if fast-forward is possible
  let head = @bitrepo.rev_parse(rfs, git_dir, "HEAD")
  let is_ff = match head {
    Some(h) => is_ancestor(rfs, git_dir, h, tid)
    None => false
  }
  // Handle --ff-only
  if ff_only && not(is_ff) {
    @stdio.stderr.write("fatal: Not possible to fast-forward, aborting.")
    @sys.exit(128)
  }
  // Handle --no-ff: force merge commit even if fast-forward possible
  if no_ff && is_ff {
    // Create merge commit even though ff is possible
    let db = @bitlib.ObjectDb::load(rfs, git_dir)
    let head_id = @bitrepo.rev_parse(rfs, git_dir, "HEAD")
    guard head_id is Some(hid) else {
      raise @bitcore.GitError::InvalidObject("Cannot resolve HEAD")
    }
    // Use target's tree
    let target_obj = db.get(rfs, tid)
    guard target_obj is Some(to) else {
      raise @bitcore.GitError::InvalidObject("Cannot read target commit")
    }
    let target_info = @bitcore.parse_commit(to.data)
    // Write tree (use target's tree)
    let tree_id = target_info.tree
    // Create merge commit with two parents
    let commit = @bitcore.Commit::new(
      tree_id,
      [hid, tid],
      author,
      timestamp,
      "+0000",
      author,
      timestamp,
      "+0000",
      msg + "\n",
    )
    let (commit_id, commit_data) = @bitcore.create_commit(commit)
    @bitlib.write_object_bytes(wfs, git_dir, commit_id, commit_data)
    // Update HEAD
    let head_path = git_dir + "/HEAD"
    let head_content = rfs.read_file(head_path) |> decode_bytes |> trim_string
    if head_content.has_prefix("ref: ") {
      let ref_path = git_dir +
        "/" +
        String::unsafe_substring(
          head_content,
          start=5,
          end=head_content.length(),
        )
      wfs.write_string(ref_path, commit_id.to_hex() + "\n")
    } else {
      wfs.write_string(head_path, commit_id.to_hex() + "\n")
    }
    // Checkout the new tree
    ignore(
      run_checkout_with_sensitive_hooks(
        wfs,
        rfs,
        root,
        commit_id.to_hex(),
        detach=false,
      ),
    )
    let short = String::unsafe_substring(commit_id.to_hex(), start=0, end=7)
    if not(quiet) {
      print_line("Merge made by the 'ort' strategy (--no-ff). [\{short}]")
    }
    return
  }
  // Regular merge
  let result = run_merge_with_sensitive_hooks(
    fs, fs, root, tid, msg, author, timestamp,
  )
  match result.status {
    @bitlib.MergeStatus::AlreadyUpToDate =>
      if not(quiet) {
        print_line("Already up to date.")
      }
    @bitlib.MergeStatus::FastForward =>
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          if not(quiet) {
            print_line("Fast-forward to \{short}")
          }
        }
        None => if not(quiet) { print_line("Fast-forward") }
      }
    @bitlib.MergeStatus::Merged =>
      match result.commit_id {
        Some(id) => {
          let short = String::unsafe_substring(id.to_hex(), start=0, end=7)
          if not(quiet) {
            print_line("Merge made by the 'ort' strategy. [\{short}]")
          }
        }
        None => if not(quiet) { print_line("Merged") }
      }
    @bitlib.MergeStatus::Conflicted => {
      if not(quiet) {
        print_line("CONFLICT (content): Merge conflict in the following files:")
        for path in result.conflicts {
          print_line("  \{path}")
        }
        print_line("Automatic merge failed; fix conflicts and then commit.")
      }
      @sys.exit(1)
    }
  }
}

///|
fn merge_target_requires_real_git(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  target_id : @bitcore.ObjectId,
) -> Bool {
  try {
    match @bitlib.ObjectDb::load_lazy(rfs, git_dir).get(rfs, target_id) {
      Some(obj) if obj.obj_type == @bitcore.ObjectType::Commit =>
        @bitcore.parse_commit(obj.data).parents.length() > 1
      _ => false
    }
  } catch {
    _ => false
  }
}

///|
async fn validate_current_branch_mergeoptions(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Unit raise Error {
  let head_path = git_dir + "/HEAD"
  if not(rfs.is_file(head_path)) {
    return
  }
  let head = decode_bytes(rfs.read_file(head_path) catch { _ => return })
    |> trim_string
  if not(head.has_prefix("ref: refs/heads/")) {
    return
  }
  let branch_name = String::unsafe_substring(head, start=16, end=head.length())
  let merge_key = "branch." + branch_name + ".mergeoptions"
  match get_config_value(rfs, git_dir + "/config", merge_key, None, false) {
    Some(value) =>
      if split_cmdline_has_unclosed_quote(value) {
        eprint_line("fatal: bad " + merge_key + " string: unclosed quote")
        @sys.exit(128)
      }
    None => ()
  }
}

///|
fn split_cmdline_has_unclosed_quote(value : String) -> Bool {
  let mut in_single = false
  let mut in_double = false
  let mut escape = false
  for c in value {
    if escape {
      escape = false
      continue
    }
    if c == '\\' && not(in_single) {
      escape = true
      continue
    }
    if c == '\'' && not(in_double) {
      in_single = not(in_single)
      continue
    }
    if c == '"' && not(in_single) {
      in_double = not(in_double)
      continue
    }
  }
  in_single || in_double
}

///|
fn is_ancestor(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
  ancestor : @bitcore.ObjectId,
  descendant : @bitcore.ObjectId,
) -> Bool {
  // Check if ancestor is an ancestor of descendant
  let db = @bitlib.ObjectDb::load(rfs, git_dir) catch { _ => return false }
  let ancestor_hex = ancestor.to_hex()
  let visited : Map[String, Bool] = {}
  let queue : Array[@bitcore.ObjectId] = [descendant]
  while queue.length() > 0 {
    let current = queue.pop()
    guard current is Some(cid) else { break }
    let hex = cid.to_hex()
    if hex == ancestor_hex {
      return true
    }
    if visited.get(hex).unwrap_or(false) {
      continue
    }
    visited[hex] = true
    let obj = db.get(rfs, cid) catch { _ => continue }
    match obj {
      Some(o) => {
        let info = @bitcore.parse_commit(o.data) catch { _ => continue }
        for p in info.parents {
          queue.push(p)
        }
      }
      None => ()
    }
  }
  false
}

///|
