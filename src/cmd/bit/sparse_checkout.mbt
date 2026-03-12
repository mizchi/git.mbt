///|
enum SparseCheckoutListState {
  Fatal(String)
  Warning(String)
  Patterns(Array[String])
}

///|
fn sparse_checkout_sparse_index_flag(args : Array[String]) -> Bool? {
  let mut flag : Bool? = None
  for arg in args {
    match arg {
      "--sparse-index" => flag = Some(true)
      "--no-sparse-index" => flag = Some(false)
      _ => ()
    }
  }
  flag
}

///|
fn sparse_checkout_cone_flag(args : Array[String]) -> Bool? {
  let mut flag : Bool? = None
  for arg in args {
    match arg {
      "--cone" => flag = Some(true)
      "--no-cone" => flag = Some(false)
      _ => ()
    }
  }
  flag
}

///|
async fn sparse_checkout_parse_pattern_args(
  subcmd : String,
  args : Array[String],
) -> Array[String] raise Error {
  let patterns : Array[String] = []
  let mut read_from_stdin = false
  let mut end_of_options = false
  for arg in args {
    if end_of_options {
      patterns.push(arg)
      continue
    }
    match arg {
      "--stdin" => read_from_stdin = true
      "--cone" => ()
      "--no-cone" => ()
      "--sparse-index" => ()
      "--no-sparse-index" => ()
      "--end-of-options" => end_of_options = true
      _ if arg.has_prefix("-") =>
        raise @bitcore.GitError::InvalidObject(
          "unknown option for sparse-checkout \{subcmd}: \{arg}",
        )
      _ => patterns.push(arg)
    }
  }
  if read_from_stdin {
    let input = decode_bytes(read_all_stdin())
    for line_view in input.split("\n") {
      let line = sparse_checkout_trim_cr(line_view.to_string())
      if line.length() > 0 {
        patterns.push(line)
      }
    }
  }
  patterns
}

///|
fn sparse_checkout_validate_flag_only_args(
  subcmd : String,
  args : Array[String],
) -> Unit raise Error {
  for arg in args {
    match arg {
      "--cone" => ()
      "--no-cone" => ()
      "--sparse-index" => ()
      "--no-sparse-index" => ()
      _ if arg.has_prefix("-") =>
        raise @bitcore.GitError::InvalidObject(
          "unknown option for sparse-checkout \{subcmd}: \{arg}",
        )
      _ =>
        raise @bitcore.GitError::InvalidObject(
          "unexpected argument for sparse-checkout \{subcmd}: \{arg}",
        )
    }
  }
}

///|
fn sparse_checkout_list_state(
  rfs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> SparseCheckoutListState {
  if not(@bitlib.is_sparse_checkout_enabled(rfs, git_dir)) {
    return Fatal("this worktree is not sparse")
  }
  let sparse_path = git_dir + "/info/sparse-checkout"
  if not(rfs.is_file(sparse_path)) {
    return Warning(
      "this worktree is not sparse (sparse-checkout file may not exist)",
    )
  }
  Patterns(@bitlib.read_sparse_display_patterns(rfs, git_dir) catch { _ => [] })
}

///|
fn sparse_checkout_trim_cr(line : String) -> String {
  if line.has_suffix("\r") {
    line[:line.length() - 1].to_string()
  } else {
    line
  }
}

///|
fn sparse_checkout_unquote_c_style(text : String) -> String {
  let trimmed = sparse_checkout_trim_cr(text)
  if trimmed.length() < 2 || !trimmed.has_prefix("\"") || !trimmed.has_suffix("\"") {
    return trimmed
  }
  let inner = trimmed[1:trimmed.length() - 1].to_string()
  let buf = StringBuilder::new()
  let mut escape = false
  for c in inner {
    if escape {
      let out = match c {
        '"' => '"'
        '\\' => '\\'
        'n' => '\n'
        'r' => '\r'
        't' => '\t'
        _ => c
      }
      buf.write_char(out)
      escape = false
      continue
    }
    if c == '\\' {
      escape = true
      continue
    }
    buf.write_char(c)
  }
  if escape {
    buf.write_char('\\')
  }
  buf.to_string()
}

///|
fn sparse_checkout_compile_cone_patterns(patterns : Array[String]) -> Array[String] {
  let out = @bitlib.sparse_default_patterns()
  for pattern in patterns {
    if pattern == "/*" || pattern == "!/*/" {
      continue
    }
    let anchored = if pattern.has_prefix("/") { pattern } else { "/" + pattern }
    let trimmed = if anchored.has_suffix("/") && anchored.length() > 1 {
      anchored[:anchored.length() - 1].to_string()
    } else {
      anchored
    }
    let relative = if trimmed.has_prefix("/") {
      trimmed[1:].to_string()
    } else {
      trimmed
    }
    if relative.length() == 0 {
      continue
    }
    let parts : Array[String] = []
    for part_view in relative.split("/") {
      let part = part_view.to_string()
      if part.length() > 0 {
        parts.push(part)
      }
    }
    let mut current = ""
    if parts.length() > 1 {
      for i in 0..<(parts.length() - 1) {
        current = if current == "" {
          parts[i]
        } else {
          current + "/" + parts[i]
        }
        let parent = "/" + current + "/"
        if !out.contains(parent) {
          out.push(parent)
        }
        let exclude_children = "!/" + current + "/*/"
        if !out.contains(exclude_children) {
          out.push(exclude_children)
        }
      }
    }
    let stored = "/" + relative + "/"
    if !out.contains(stored) {
      out.push(stored)
    }
  }
  out
}

///|
fn sparse_checkout_split_check_rules_input(
  input : String,
  nul_terminated : Bool,
) -> Array[(String, String)] {
  let entries : Array[(String, String)] = []
  if nul_terminated {
    let buf = StringBuilder::new()
    for c in input {
      if c == '\u{0}' {
        let raw = buf.to_string()
        if raw.length() > 0 {
          entries.push((raw, raw))
        }
        buf.reset()
      } else {
        buf.write_char(c)
      }
    }
    let raw = buf.to_string()
    if raw.length() > 0 {
      entries.push((raw, raw))
    }
    return entries
  }
  for line_view in input.split("\n") {
    let raw = sparse_checkout_trim_cr(line_view.to_string())
    if raw.length() == 0 {
      continue
    }
    entries.push((raw, sparse_checkout_unquote_c_style(raw)))
  }
  entries
}

///|
fn sparse_checkout_filter_check_rules_input(
  input : String,
  patterns : Array[String],
  nul_terminated : Bool,
) -> String {
  let out = StringBuilder::new()
  for entry in sparse_checkout_split_check_rules_input(input, nul_terminated) {
    let raw = entry.0
    let path = entry.1
    if @bitlib.matches_sparse_pattern(path, patterns) {
      out.write_string(raw)
      out.write_char(if nul_terminated { '\u{0}' } else { '\n' })
    }
  }
  out.to_string()
}

///|
fn sparse_checkout_read_check_rules_patterns(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  args : Array[String],
) -> (Array[String], Bool) raise Error {
  let mut nul_terminated = false
  let mut cone_mode : Bool? = None
  let mut rules_file : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-z" => nul_terminated = true
      "--cone" => cone_mode = Some(true)
      "--no-cone" => cone_mode = Some(false)
      "--rules-file" => {
        i = i + 1
        if i >= args.length() {
          raise @bitcore.GitError::InvalidObject(
            "option '--rules-file' requires a value",
          )
        }
        rules_file = Some(args[i])
      }
      _ if arg.has_prefix("--rules-file=") =>
        rules_file = Some(arg["--rules-file=".length():].to_string())
      _ =>
        raise @bitcore.GitError::InvalidObject(
          "unknown option for sparse-checkout check-rules: \{arg}",
        )
    }
    i = i + 1
  }
  let patterns = match rules_file {
    Some(path) => {
      let resolved = if path.has_prefix("/") { path } else { root + "/" + path }
      let raw_rules = decode_bytes(fs.read_file(resolved))
      let decoded_rules : Array[String] = []
      for line_view in raw_rules.split("\n") {
        let line = sparse_checkout_trim_cr(line_view.to_string())
        if line.length() > 0 {
          decoded_rules.push(sparse_checkout_unquote_c_style(line))
        }
      }
      let use_cone = match cone_mode {
        Some(flag) => flag
        None => true
      }
      if use_cone {
        sparse_checkout_compile_cone_patterns(decoded_rules)
      } else {
        decoded_rules
      }
    }
    None => @bitlib.read_sparse_patterns(fs, git_dir)
  }
  (patterns, nul_terminated)
}

///|
async fn sparse_checkout_run_check_rules(
  fs : &@bitcore.RepoFileSystem,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let (patterns, nul_terminated) = sparse_checkout_read_check_rules_patterns(
    fs,
    root,
    git_dir,
    args,
  )
  let input = decode_bytes(read_all_stdin())
  let output = sparse_checkout_filter_check_rules_input(
    input,
    patterns,
    nul_terminated,
  )
  @stdio.stdout.write(output)
}

///|
fn sparse_checkout_path_exists(
  fs : &@bitcore.RepoFileSystem,
  path : String,
) -> Bool {
  fs.is_file(path) || fs.is_dir(path)
}

///|
fn sparse_checkout_unique_push(paths : Array[String], path : String) -> Unit {
  if !paths.contains(path) {
    paths.push(path)
  }
}

///|
fn sparse_checkout_clean_covers_path(
  root : String,
  path : String,
) -> Bool {
  path == root || path.has_prefix(root + "/")
}

///|
fn sparse_checkout_clean_managed_root(
  path : String,
  skipped_paths : Array[String],
  kept_paths : Array[String],
) -> String? {
  let parts : Array[String] = []
  for part_view in path.split("/") {
    let part = part_view.to_string()
    if part.length() > 0 {
      parts.push(part)
    }
  }
  let mut prefix = ""
  for i in 0..<parts.length() {
    prefix = if prefix == "" {
      parts[i]
    } else {
      prefix + "/" + parts[i]
    }
    let has_skipped = skipped_paths.any(fn(item) {
      sparse_checkout_clean_covers_path(prefix, item)
    })
    let has_kept = kept_paths.any(fn(item) {
      sparse_checkout_clean_covers_path(prefix, item)
    })
    if has_skipped && !has_kept {
      return Some(prefix)
    }
  }
  None
}

///|
async fn sparse_checkout_warn_reapply_preserved_paths(
  fs : OsFs,
  root : String,
  git_dir : String,
) -> Unit raise Error {
  let stage_entries = @bitlib.read_index_stage_entries(fs, git_dir)
  let skip_worktree_paths = @bitlib.read_skip_worktree_paths(fs, git_dir)
  let skipped_paths : Array[String] = []
  let kept_paths : Array[String] = []
  for item in stage_entries {
    if item.stage != 0 {
      continue
    }
    let raw_path = item.entry.path
    let path = if raw_path.has_suffix("/") {
      raw_path[:raw_path.length() - 1].to_string()
    } else {
      raw_path
    }
    if path.length() == 0 {
      continue
    }
    if raw_path.has_suffix("/") || skip_worktree_paths.contains(raw_path) {
      sparse_checkout_unique_push(skipped_paths, path)
    } else {
      kept_paths.push(path)
    }
  }

  let status = @bitlib.status(fs, root)
  let not_up_to_date_roots : Array[String] = []
  let untracked_roots : Array[String] = []
  let unmerged_roots : Array[String] = []
  let tracked_paths_in_worktree : Array[String] = []
  for item in stage_entries {
    if item.stage != 0 {
      continue
    }
    let path = item.entry.path
    if path.has_suffix("/") {
      continue
    }
    if sparse_checkout_path_exists(fs, root + "/" + path) {
      sparse_checkout_unique_push(tracked_paths_in_worktree, path)
    }
  }
  for path in status.staged_added {
    if sparse_checkout_path_exists(fs, root + "/" + path) {
      sparse_checkout_unique_push(tracked_paths_in_worktree, path)
    }
  }
  for path in status.staged_modified {
    if sparse_checkout_path_exists(fs, root + "/" + path) {
      sparse_checkout_unique_push(tracked_paths_in_worktree, path)
    }
  }
  for path in status.unstaged_modified {
    if sparse_checkout_path_exists(fs, root + "/" + path) {
      sparse_checkout_unique_push(tracked_paths_in_worktree, path)
    }
  }
  for path in tracked_paths_in_worktree {
    match sparse_checkout_clean_managed_root(path, skipped_paths, kept_paths) {
      Some(clean_root) =>
        sparse_checkout_unique_push(not_up_to_date_roots, clean_root)
      None => ()
    }
  }
  for path in status.untracked {
    match sparse_checkout_clean_managed_root(path, skipped_paths, kept_paths) {
      Some(clean_root) => sparse_checkout_unique_push(untracked_roots, clean_root)
      None => ()
    }
  }
  for item in @bitlib.read_unmerged_paths(fs, git_dir).to_array() {
    let (path, _) = item
    match sparse_checkout_clean_managed_root(path, skipped_paths, kept_paths) {
      Some(clean_root) => sparse_checkout_unique_push(unmerged_roots, clean_root)
      None => ()
    }
  }

  not_up_to_date_roots.sort()
  unmerged_roots.sort()
  if not_up_to_date_roots.length() > 0 {
    eprint_line(
      "warning: The following paths are not up to date and were left despite sparse patterns:",
    )
    for path in not_up_to_date_roots {
      eprint_line(path)
    }
  }
  untracked_roots.sort()
  if unmerged_roots.length() > 0 {
    eprint_line(
      "warning: The following paths are unmerged and were left despite sparse patterns:",
    )
    for path in unmerged_roots {
      eprint_line(path)
    }
  }
  if untracked_roots.length() > 0 {
    eprint_line(
      "warning: The following paths contain untracked files and were left despite sparse patterns:",
    )
    for path in untracked_roots {
      eprint_line(path)
    }
  }
}

///|
fn sparse_checkout_clean_requires_force(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Bool {
  @bitlib.read_config_bool(fs, git_dir + "/config", "clean", "requireforce").unwrap_or(
    true,
  )
}

///|
fn sparse_checkout_clean_remove_root(
  fs : OsFs,
  root : String,
  path : String,
) -> String {
  let abs_path = root + "/" + path
  if fs.is_dir(abs_path) {
    remove_dir_recursive(fs, abs_path)
    path + "/"
  } else {
    fs.remove_file(abs_path) catch {
      _ => ()
    }
    path
  }
}

///|
async fn sparse_checkout_run_clean(
  fs : OsFs,
  root : String,
  git_dir : String,
  args : Array[String],
) -> Unit raise Error {
  let mut force = false
  let mut dry_run = false
  let mut verbose = false
  for arg in args {
    match arg {
      "-f" | "--force" => force = true
      "-n" | "--dry-run" => dry_run = true
      "-v" | "--verbose" => verbose = true
      _ if arg.has_prefix("-") =>
        raise @bitcore.GitError::InvalidObject(
          "unknown option for sparse-checkout clean: \{arg}",
        )
      _ => ()
    }
  }

  if @bitlib.read_unmerged_paths(fs, git_dir).length() > 0 {
    eprint_line("fatal: failed to convert index to a sparse index")
    @sys.exit(1)
  }

  if !force &&
    !dry_run &&
    sparse_checkout_clean_requires_force(fs, git_dir) {
    @stdio.stderr.write(
      "fatal: clean.requireForce defaults to true and neither -i, -n, nor -f given; refusing to clean",
    )
    @sys.exit(1)
  }

  let stage_entries = @bitlib.read_index_stage_entries(fs, git_dir)
  let skip_worktree_paths = @bitlib.read_skip_worktree_paths(fs, git_dir)
  let skipped_paths : Array[String] = []
  let kept_paths : Array[String] = []
  for item in stage_entries {
    if item.stage != 0 {
      continue
    }
    let raw_path = item.entry.path
    let path = if raw_path.has_suffix("/") {
      raw_path[:raw_path.length() - 1].to_string()
    } else {
      raw_path
    }
    if path.length() == 0 {
      continue
    }
    if raw_path.has_suffix("/") || skip_worktree_paths.contains(raw_path) {
      sparse_checkout_unique_push(skipped_paths, path)
    } else {
      kept_paths.push(path)
    }
  }
  let status = @bitlib.status(fs, root)
  let tracked_paths_in_worktree : Array[String] = []
  let blocked_roots : Array[String] = []
  for item in stage_entries {
    if item.stage != 0 {
      continue
    }
    let path = item.entry.path
    if path.has_suffix("/") {
      continue
    }
    if sparse_checkout_path_exists(fs, root + "/" + path) {
      sparse_checkout_unique_push(tracked_paths_in_worktree, path)
    }
  }
  for path in status.staged_added {
    if sparse_checkout_path_exists(fs, root + "/" + path) {
      sparse_checkout_unique_push(tracked_paths_in_worktree, path)
    }
  }
  for path in status.staged_modified {
    if sparse_checkout_path_exists(fs, root + "/" + path) {
      sparse_checkout_unique_push(tracked_paths_in_worktree, path)
    }
  }
  for path in status.unstaged_modified {
    if sparse_checkout_path_exists(fs, root + "/" + path) {
      sparse_checkout_unique_push(tracked_paths_in_worktree, path)
    }
  }
  for path in tracked_paths_in_worktree {
    match sparse_checkout_clean_managed_root(path, skipped_paths, kept_paths) {
      Some(clean_root) => sparse_checkout_unique_push(blocked_roots, clean_root)
      None => ()
    }
  }
  if blocked_roots.length() > 0 {
    return
  }
  let clean_roots : Array[String] = []
  let verbose_paths : Array[String] = []
  for path in status.untracked {
    match sparse_checkout_clean_managed_root(path, skipped_paths, kept_paths) {
      Some(clean_root) => {
        if blocked_roots.contains(clean_root) {
          continue
        }
        sparse_checkout_unique_push(clean_roots, clean_root)
        verbose_paths.push(path)
      }
      None => ()
    }
  }

  clean_roots.sort()
  verbose_paths.sort()
  if verbose {
    for path in verbose_paths {
      if dry_run {
        print_line("Would remove \{path}")
      } else {
        let abs_path = root + "/" + path
        fs.remove_file(abs_path) catch {
          _ => ()
        }
        print_line("Removing \{path}")
      }
    }
    return
  }

  for path in clean_roots {
    if dry_run {
      let suffix = if fs.is_dir(root + "/" + path) { "/" } else { "" }
      print_line("Would remove \{path}\{suffix}")
    } else {
      let removed = sparse_checkout_clean_remove_root(fs, root, path)
      print_line("Removing \{removed}")
    }
  }
}

///|
async fn handle_sparse_checkout_at_root(
  root : String,
  args : Array[String],
) -> Unit raise Error {
  let git_dir = root + "/.git"
  let fs = OsFs::new()
  if args.length() == 0 {
    raise @bitcore.GitError::InvalidObject(
      "usage: git sparse-checkout <init|set|add|list|reapply|check-rules|clean|disable>",
    )
  }
  let subcmd = args[0]
  let sparse_index_flag = sparse_checkout_sparse_index_flag(args)
  let rest : Array[String] = []
  for i in 1..<args.length() {
    rest.push(args[i])
  }
  match subcmd {
    "init" => {
      sparse_checkout_validate_flag_only_args("init", rest)
      let cone = match sparse_checkout_cone_flag(rest) {
        Some(flag) => flag
        None => false
      }
      @bitlib.sparse_checkout_init(fs, fs, root, cone~)
      match sparse_index_flag {
        Some(flag) => {
          @bitlib.sparse_set_index_sparse_config(fs, fs, git_dir, flag)
          @bitlib.sparse_checkout_reapply(fs, fs, root)
        }
        None => ()
      }
      sparse_checkout_warn_reapply_preserved_paths(fs, root, git_dir)
      print_line("Sparse checkout initialized")
    }
    "set" => {
      let cone_flag = sparse_checkout_cone_flag(rest)
      if not(@bitlib.is_sparse_checkout_enabled(fs, git_dir)) {
        @bitlib.sparse_checkout_init(
          fs,
          fs,
          root,
          cone=match cone_flag {
            Some(flag) => flag
            None => false
          },
        )
      }
      match cone_flag {
        Some(flag) => @bitlib.sparse_set_cone_config(fs, fs, git_dir, flag)
        None => ()
      }
      let patterns = sparse_checkout_parse_pattern_args("set", rest)
      let patterns = if patterns.length() == 0 {
        @bitlib.sparse_default_patterns()
      } else {
        patterns
      }
      @bitlib.sparse_checkout_set(fs, fs, root, patterns)
      match sparse_index_flag {
        Some(flag) => {
          @bitlib.sparse_set_index_sparse_config(fs, fs, git_dir, flag)
          @bitlib.sparse_checkout_reapply(fs, fs, root)
        }
        None => ()
      }
      sparse_checkout_warn_reapply_preserved_paths(fs, root, git_dir)
      print_line("Sparse checkout patterns set")
    }
    "add" => {
      let patterns = sparse_checkout_parse_pattern_args("add", rest)
      if patterns.length() == 0 {
        raise @bitcore.GitError::InvalidObject("patterns required for add")
      }
      @bitlib.sparse_checkout_add(fs, fs, root, patterns)
      sparse_checkout_warn_reapply_preserved_paths(fs, root, git_dir)
      print_line("Sparse checkout patterns added")
    }
    "list" =>
      match sparse_checkout_list_state(fs, git_dir) {
        Fatal(msg) => raise @bitcore.GitError::InvalidObject(msg)
        Warning(msg) => eprint_line(msg)
        Patterns(patterns) =>
          for p in patterns {
            print_line(p)
          }
      }
    "reapply" => {
      sparse_checkout_validate_flag_only_args("reapply", rest)
      match sparse_checkout_cone_flag(rest) {
        Some(flag) => @bitlib.sparse_set_cone_config(fs, fs, git_dir, flag)
        None => ()
      }
      match sparse_index_flag {
        Some(flag) =>
          @bitlib.sparse_set_index_sparse_config(fs, fs, git_dir, flag)
        None => ()
      }
      @bitlib.sparse_checkout_reapply(fs, fs, root)
      sparse_checkout_warn_reapply_preserved_paths(fs, root, git_dir)
    }
    "check-rules" => {
      sparse_checkout_run_check_rules(fs, root, git_dir, rest)
    }
    "clean" => {
      sparse_checkout_run_clean(fs, root, git_dir, rest)
    }
    "disable" => {
      sparse_checkout_warn_reapply_preserved_paths(fs, root, git_dir)
      @bitlib.sparse_checkout_disable(fs, fs, root)
      print_line("Sparse checkout disabled")
    }
    _ =>
      raise @bitcore.GitError::InvalidObject(
        "unknown sparse-checkout subcommand: \{subcmd}",
      )
  }
}

///|
async fn handle_sparse_checkout(args : Array[String]) -> Unit raise Error {
  handle_sparse_checkout_at_root(get_work_root(), args)
}

///|
