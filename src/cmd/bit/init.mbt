///|

///|
async fn show_init_command_help() -> Unit {
  show_simple_command_help(
    "git init [<options>] [<directory>]",
    summary="Create an empty Git repository or reinitialize an existing one.",
  )
}

///|
async fn handle_init(args : Array[String]) -> Unit raise Error {
  let root = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(dir) => dir
    None => @sys.get_env_var("GIT_SHIM_PWD").unwrap_or(".")
  }
  let fs = OsFs::new()
  // Parse options
  let mut bare = false
  let mut quiet = false
  let mut initial_branch : String? = None
  let mut target_dir : String? = None
  let mut separate_git_dir : String? = None
  let mut template_dir : String? = None
  // Ref format: resolved later after parsing args (--ref-format may override env)
  let mut ref_format = "files"
  let mut ref_format_explicit = false
  let ref_format_env_deferred = true
  let mut object_format : String? = None
  let mut object_format_explicit = false
  let mut shared_mode : String? = None
  let mut use_bit = false
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--bare" => bare = true
      "--bit" => use_bit = true
      "-q" | "--quiet" => quiet = true
      "-b" if i + 1 < args.length() => {
        initial_branch = Some(args[i + 1])
        i += 1
      }
      "--separate-git-dir" if i + 1 < args.length() => {
        separate_git_dir = Some(args[i + 1])
        i += 1
      }
      "--template" if i + 1 < args.length() => {
        template_dir = Some(args[i + 1])
        i += 1
      }
      "--shared" =>
        if i + 1 < args.length() && not(args[i + 1].has_prefix("-")) {
          shared_mode = Some(args[i + 1])
          i += 1
        } else {
          shared_mode = Some("group")
        }
      "--ref-format" if i + 1 < args.length() => {
        let value = args[i + 1].to_lower()
        if value != "files" && value != "reftable" {
          eprint_line("fatal: unknown ref storage format '\{value}'")
          @sys.exit(128)
        }
        ref_format = value
        ref_format_explicit = true
        i += 1
      }
      "--object-format" if i + 1 < args.length() => {
        let value = args[i + 1].to_lower()
        if value != "sha1" && value != "sha256" {
          eprint_line("fatal: unknown hash algorithm '\{value}'")
          @sys.exit(128)
        }
        object_format = Some(value)
        object_format_explicit = true
        i += 1
      }
      _ if arg.has_prefix("--initial-branch=") =>
        initial_branch = Some((try! arg[17:]).to_string())
      _ if arg.has_prefix("--separate-git-dir=") =>
        separate_git_dir = Some((try! arg[19:]).to_string())
      _ if arg.has_prefix("--template=") =>
        template_dir = Some((try! arg[11:]).to_string())
      _ if arg.has_prefix("--shared=") =>
        shared_mode = Some((try! arg[9:]).to_string())
      _ if arg.has_prefix("--ref-format=") => {
        let value = (try! arg[13:]).to_string().to_lower()
        if value != "files" && value != "reftable" {
          eprint_line("fatal: unknown ref storage format '\{value}'")
          @sys.exit(128)
        }
        ref_format = value
        ref_format_explicit = true
      }
      _ if arg.has_prefix("--object-format=") => {
        let value = (try! arg[16:]).to_string().to_lower()
        if value != "sha1" && value != "sha256" {
          eprint_line("fatal: unknown hash algorithm '\{value}'")
          @sys.exit(128)
        }
        object_format = Some(value)
        object_format_explicit = true
      }
      _ if not(arg.has_prefix("-")) => target_dir = Some(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("init", arg)
      _ => ()
    }
    i += 1
  }
  // Resolve ref format from env if not explicitly set via --ref-format
  let mut ref_format_from_env = false
  if ref_format_env_deferred && not(ref_format_explicit) {
    let env_ref_format = match @sys.get_env_var("GIT_DEFAULT_REF_FORMAT") {
      Some(value) => Some(value)
      None => @sys.get_env_var("GIT_TEST_DEFAULT_REF_FORMAT")
    }
    match env_ref_format {
      Some(value) => {
        let normalized = value.to_lower()
        if normalized == "reftable" {
          ref_format = "reftable"
          ref_format_from_env = true
        } else if normalized == "files" || normalized == "" {
          ref_format = "files"
          ref_format_from_env = true
        } else {
          eprint_line("fatal: unknown ref storage format '\{value}'")
          @sys.exit(128)
        }
      }
      None => ()
    }
  }
  // Check --bare and --separate-git-dir incompatibility
  if bare && separate_git_dir is Some(_) {
    eprint_line(
      "fatal: options '--separate-git-dir' and '--bare' cannot be used together",
    )
    @sys.exit(128)
    return
  }
  // Check GIT_DIR and GIT_WORK_TREE environment variables
  let bit_dir_env = @sys.get_env_var("GIT_DIR")
  let work_tree_env = @sys.get_env_var("GIT_WORK_TREE")
  // GIT_WORK_TREE without GIT_DIR is an error during init
  if work_tree_env is Some(_) && (bit_dir_env is None || bare) {
    eprint_line(
      "fatal: GIT_WORK_TREE (or --work-tree=<directory>) not allowed without specifying GIT_DIR (or --git-dir=<directory>)",
    )
    @sys.exit(128)
    return
  }
  // Check GIT_TEMPLATE_DIR environment variable, then config
  if template_dir is None {
    template_dir = @sys.get_env_var("GIT_TEMPLATE_DIR")
  }
  if template_dir is None {
    // Read init.templatedir from global config
    let rfs : &@bitcore.RepoFileSystem = fs
    match find_global_gitconfig_path() {
      Some(config_path) => {
        let tpl_val = get_config_value(
          rfs,
          config_path,
          "init.templatedir",
          None,
          false,
        ) catch {
          _ => None
        }
        match tpl_val {
          Some(tpl_path) => {
            // Expand ~ to HOME
            let expanded = if tpl_path.has_prefix("~/") {
              match @sys.get_env_var("HOME") {
                Some(home) =>
                  home +
                  String::unsafe_substring(
                    tpl_path,
                    start=1,
                    end=tpl_path.length(),
                  )
                None => tpl_path
              }
            } else {
              tpl_path
            }
            template_dir = Some(expanded)
          }
          None => ()
        }
      }
      None => ()
    }
  }
  // Determine the target path and git directory
  let (path, effective_git_dir) : (String, String?) = match
    (target_dir, bit_dir_env) {
    (Some(dir), _) => {
      let p = if dir.has_prefix("/") { dir } else { root + "/" + dir }
      (p, None)
    }
    (None, Some(gd)) => {
      // When GIT_DIR is set without target
      let g = if gd.has_prefix("/") { gd } else { root + "/" + gd }
      // If GIT_WORK_TREE is also set, it's not bare (work tree exists)
      // If only GIT_DIR is set, it's a bare repo
      if work_tree_env is Some(_) {
        (root, Some(g))
      } else {
        (g, Some(g))
      }
    }
    (None, None) => (root, None)
  }
  // Determine if bare: only bare if explicitly requested or GIT_DIR without GIT_WORK_TREE
  // GIT_DIR without GIT_WORK_TREE: bare unless GIT_DIR ends with /.git (inferred work tree)
  if bit_dir_env is Some(_) && work_tree_env is None && target_dir is None {
    match effective_git_dir {
      Some(gd) => {
        let basename = match gd.rev_find("/") {
          Some(idx) => (try? gd[idx + 1:]).unwrap_or(gd).to_string()
          None => gd
        }
        if basename != ".git" {
          bare = true
        }
      }
      _ => bare = true
    }
  }
  // Check bare and --separate-git-dir incompatibility (after implicit bare detection)
  if bare && separate_git_dir is Some(_) {
    eprint_line(
      "fatal: --separate-git-dir and --bare are incompatible",
    )
    @sys.exit(128)
    return
  }
  // If GIT_WORK_TREE is set with --bare, that's an error
  if bare && work_tree_env is Some(_) {
    eprint_line(
      "fatal: GIT_WORK_TREE (or --work-tree=<directory>) not allowed without specifying a repository to work with",
    )
    @sys.exit(128)
  }
  // Resolve separate_git_dir to absolute path
  let resolved_sep_git_dir : String? = match separate_git_dir {
    Some(d) =>
      Some(
        init_normalize_path(if d.has_prefix("/") { d } else { root + "/" + d }),
      )
    None =>
      if use_bit && not(bare) && effective_git_dir is None {
        Some(path + "/.bit")
      } else {
        None
      }
  }
  // Determine default branch: CLI flag > GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME > config > "master"
  let branch = match initial_branch {
    Some(b) => b
    None =>
      match @sys.get_env_var("GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME") {
        Some(env_branch) if env_branch != "" => env_branch
        _ => {
          let config_branch = init_read_default_branch(fs)
          config_branch.unwrap_or("master")
        }
      }
  }
  // Validate branch name
  if branch.contains(" ") ||
    branch.contains("~") ||
    branch.contains("^") ||
    branch.contains(":") ||
    branch.contains("\\") ||
    branch.has_prefix("-") ||
    branch.has_prefix(".") ||
    branch.has_suffix(".") ||
    branch.has_suffix(".lock") ||
    branch.contains("..") ||
    branch.contains("@{") ||
    branch == "" {
    eprint_line("fatal: invalid branch name: '\{branch}'")
    @sys.exit(128)
    return
  }
  // Determine actual git directory path for output message
  let actual_git_dir = match (resolved_sep_git_dir, effective_git_dir) {
    (Some(sep), _) => sep
    (None, Some(gd)) => gd
    (None, None) => if bare { path } else { path + "/.git" }
  }
  // Resolve .git file (gitdir: pointer) to actual git dir
  let mut actual_git_dir = actual_git_dir
  if not(fs.is_dir(actual_git_dir)) && fs.is_file(actual_git_dir) {
    // .git is a file pointing to the real git dir
    let content = decode_bytes(fs.read_file(actual_git_dir))
    let trimmed = content.trim_end(chars="\r\n").to_string()
    if trimmed.has_prefix("gitdir: ") {
      let linked = (try? trimmed[8:]).unwrap_or(trimmed).to_string()
      let resolved = if linked.has_prefix("/") {
        linked
      } else {
        // Relative to the directory containing the .git file
        match actual_git_dir.rev_find("/") {
          Some(idx) =>
            (try? actual_git_dir[:idx]).unwrap_or(actual_git_dir).to_string() +
            "/" +
            linked
          None => linked
        }
      }
      actual_git_dir = resolved
    }
  }
  // Check if this is a reinit (repository already exists)
  let is_reinit = if fs.is_dir(actual_git_dir) &&
    fs.is_file(actual_git_dir + "/HEAD") {
    true
  } else if resolved_sep_git_dir is Some(_) {
    // --separate-git-dir: check if work tree already has a repo (.git dir or file)
    let dot_git = path + "/.git"
    (fs.is_dir(dot_git) && fs.is_file(dot_git + "/HEAD")) || fs.is_file(dot_git)
  } else {
    false
  }
  let mut reinit_tables_list_content : String? = None
  if object_format is None {
    // Check config init.defaultObjectFormat first
    let rfs2 : &@bitcore.RepoFileSystem = fs
    let config_obj_format = match find_global_gitconfig_path() {
      Some(config_path) =>
        get_config_value(
          rfs2,
          config_path,
          "init.defaultObjectFormat",
          None,
          false,
        ) catch {
          _ => None
        }
      None => None
    }
    match config_obj_format {
      Some(fmt) => {
        let normalized = fmt.to_lower()
        if normalized == "sha1" || normalized == "sha256" {
          object_format = Some(normalized)
        } else {
          eprint_line("warning: unknown hash algorithm '\{fmt}'")
          // Fall through to env/default
        }
      }
      None => ()
    }
    if object_format is None {
      let env_default = @sys.get_env_var("GIT_DEFAULT_HASH").unwrap_or("sha1")
      let normalized = env_default.to_lower()
      if normalized != "sha1" && normalized != "sha256" {
        eprint_line("fatal: unknown hash algorithm '\{normalized}'")
        @sys.exit(128)
      }
      object_format = Some(normalized)
    }
  }
  // Read init.defaultRefFormat from config, and feature.experimental fallback
  let mut ref_format_from_config = false
  if not(ref_format_explicit) && ref_format == "files" {
    let rfs3 : &@bitcore.RepoFileSystem = fs
    match find_global_gitconfig_path() {
      Some(config_path) => {
        let ref_val = get_config_value(
          rfs3,
          config_path,
          "init.defaultRefFormat",
          None,
          false,
        ) catch {
          _ => None
        }
        match ref_val {
          Some(fmt) => {
            let normalized = fmt.to_lower()
            if normalized == "files" || normalized == "reftable" {
              ref_format = normalized
              ref_format_from_config = true
            } else {
              eprint_line("warning: unknown ref storage format '\{fmt}'")
            }
          }
          None => ()
        }
        // feature.experimental=true → default to reftable (only if no explicit env, flag, or config)
        if not(ref_format_from_config) && not(ref_format_from_env) &&
          ref_format == "files" {
          let fe_val = get_config_value(
            rfs3,
            config_path,
            "feature.experimental",
            None,
            false,
          ) catch {
            _ => None
          }
          match fe_val {
            Some(v) if v.to_lower() == "true" => ref_format = "reftable"
            _ => ()
          }
        }
      }
      None => ()
    }
  }
  if is_reinit {
    let existing_ref_format = if is_reftable_repo(fs, actual_git_dir) {
      "reftable"
    } else {
      "files"
    }
    if existing_ref_format == "reftable" {
      let tables_list_path = actual_git_dir + "/reftable/tables.list"
      if fs.is_file(tables_list_path) {
        reinit_tables_list_content = Some(
          decode_bytes(fs.read_file(tables_list_path)),
        )
      }
    }
    if ref_format_explicit && ref_format != existing_ref_format {
      eprint_line(
        "fatal: attempt to reinitialize repository with different reference storage format",
      )
      @sys.exit(128)
    }
    ref_format = existing_ref_format
    let existing_object_format = repo_object_format(fs, actual_git_dir)
    if object_format_explicit &&
      object_format.unwrap_or("sha1") != existing_object_format {
      eprint_line(
        "fatal: attempt to reinitialize repository with different hash",
      )
      @sys.exit(128)
    }
    object_format = Some(existing_object_format)
  }
  // Read core.sharedRepository from global config if --shared not specified
  if shared_mode is None {
    let rfs_shared : &@bitcore.RepoFileSystem = fs
    match find_global_gitconfig_path() {
      Some(config_path) => {
        let shared_val = get_config_value(
          rfs_shared,
          config_path,
          "core.sharedRepository",
          None,
          false,
        ) catch {
          _ => None
        }
        match shared_val {
          Some(v) => shared_mode = Some(v)
          None => ()
        }
      }
      None => ()
    }
  }
  // Determine work_tree for config
  let config_work_tree : String? = match work_tree_env {
    Some(wt) if bit_dir_env is Some(_) && not(bare) =>
      Some(if wt.has_prefix("/") { wt } else { root + "/" + wt })
    _ => None
  }
  // If reiniting and actual_git_dir differs from default (e.g., .git file redirect),
  // pass it as git_dir so init_repo uses the correct directory
  let resolved_git_dir = if is_reinit && effective_git_dir is None &&
    resolved_sep_git_dir is None {
    let default_git_dir = if bare { path } else { path + "/.git" }
    if actual_git_dir != default_git_dir {
      Some(actual_git_dir)
    } else {
      effective_git_dir
    }
  } else {
    effective_git_dir
  }
  // Build init options
  let opts : @bitlib.InitOptions = {
    default_branch: branch,
    bare,
    separate_git_dir: resolved_sep_git_dir,
    template_dir,
    ref_format,
    object_format: object_format.unwrap_or("sha1"),
    is_reinit,
    git_dir: resolved_git_dir,
    work_tree: config_work_tree,
    shared: shared_mode,
  }
  // Initialize repository
  @bitrepo.init_repo_with_options_with_repo_fs(fs, fs, path, opts)
  match reinit_tables_list_content {
    Some(content) =>
      fs.write_string(actual_git_dir + "/reftable/tables.list", content)
    None => ()
  }
  // Apply template if specified
  match template_dir {
    Some(tpl) =>
      if fs.is_dir(tpl) {
        @bitrepo.apply_template(fs, fs, actual_git_dir, tpl)
      }
    None => ()
  }
  if ref_format == "reftable" && not(is_reinit) {
    bootstrap_reftable_head_table(fs, actual_git_dir, branch)
  }
  if ref_format == "reftable" {
    apply_reftable_shared_permissions(fs, actual_git_dir, shared_mode)
  }
  // Warn about ignored --initial-branch on re-init
  if is_reinit {
    match initial_branch {
      Some(b) => eprint_line("warning: re-init: ignored --initial-branch=\{b}")
      None => ()
    }
  }
  // Print appropriate message (unless quiet)
  if not(quiet) {
    let verb = if is_reinit {
      "Reinitialized existing"
    } else {
      "Initialized empty"
    }
    print_line(verb + " Git repository in " + actual_git_dir + "/")
  }
}

///|
async fn apply_reftable_shared_permissions(
  fs : OsFs,
  git_dir : String,
  shared_mode : String?,
) -> Unit {
  let chmod_mode = match shared_mode {
    Some(value) => {
      let normalized = value.to_lower()
      if normalized == "world" ||
        normalized == "all" ||
        normalized == "everybody" ||
        normalized == "2" {
        Some(0o664)
      } else {
        None
      }
    }
    None => None
  }
  match chmod_mode {
    Some(mode) => {
      let reftable_dir = git_dir + "/reftable"
      let tables_list_path = reftable_dir + "/tables.list"
      if fs.is_file(tables_list_path) {
        @asyncfs.chmod(tables_list_path[:], mode) catch {
          _ => ()
        }
      }
      if fs.is_dir(reftable_dir) {
        for entry in fs.readdir(reftable_dir) {
          if entry.has_suffix(".ref") {
            let table_path = reftable_dir + "/" + entry
            @asyncfs.chmod(table_path[:], mode) catch {
              _ => ()
            }
          }
        }
      }
    }
    None => ()
  }
}

///|
async fn bootstrap_reftable_head_table(
  fs : OsFs,
  git_dir : String,
  branch : String,
) -> Unit {
  let reftable_dir = git_dir + "/reftable"
  if not(fs.is_dir(reftable_dir)) {
    return
  }
  for entry in fs.readdir(reftable_dir) {
    if entry.has_suffix(".ref") {
      return
    }
  }
  // Write a proper reftable binary with HEAD as symref
  let record : @reftable.RefRecord = {
    refname: "HEAD",
    update_index: 1UL,
    value: @reftable.RefValue::Symref("refs/heads/" + branch),
  }
  let table_data = @reftable.write_reftable([record], 4096, 1UL, 1UL)
  let table_name = "0x000000000001-0x000000000001-00000000.ref"
  let table_path = reftable_dir + "/" + table_name
  @fs.write_bytes_to_file(table_path, table_data) catch {
    _ => return
  }
  fs.write_string(reftable_dir + "/tables.list", table_name + "\n")
}

///|
fn init_read_default_branch(fs : OsFs) -> String? {
  // Read init.defaultBranch from global config
  let rfs : &@bitcore.RepoFileSystem = fs
  match find_global_gitconfig_path() {
    Some(path) =>
      get_config_value(rfs, path, "init.defaultBranch", None, false) catch {
        _ => None
      }
    None => None
  }
}

///|
/// Normalize a path by resolving `.` and `..` components.
fn init_normalize_path(p : String) -> String {
  let parts = p.split("/")
  let result : Array[String] = []
  for part in parts {
    match part {
      "." => continue
      ".." =>
        if result.length() > 1 {
          let _ = result.pop()
        }
      "" if result.length() > 0 => continue
      _ => result.push(part.to_string())
    }
  }
  if result.length() == 0 {
    "/"
  } else {
    result.join("/")
  }
}
