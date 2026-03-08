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
    eprint_line("fatal: --separate-git-dir and --bare are incompatible")
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
  // Handle symlink .git: if .git is a symlink to a directory and we're
  // using --separate-git-dir, resolve and move the symlink target.
  // After this, the symlink becomes dangling and write_string will create
  // the target file through the dangling symlink (POSIX behavior).
  if resolved_sep_git_dir is Some(sep_dir) && not(bare) {
    let dot_git = path + "/.git"
    let readlink_result = try? @process.collect_output(
      "readlink",
      [dot_git],
      inherit_env=true,
    )
    match readlink_result {
      Ok((0, stdout, _)) => {
        let target = (stdout.text() catch { _ => "" }).trim().to_string()
        if target != "" {
          let abs_target = if target.has_prefix("/") {
            target
          } else {
            init_normalize_path(path + "/" + target)
          }
          if fs.is_dir(abs_target) {
            // Move the actual directory to the separate git dir
            let _ = @process.run("mv", [abs_target, sep_dir], inherit_env=true) catch {
              _ => 1
            }
          }
        }
      }
      _ => () // Not a symlink or readlink failed
    }
  }
  // Resolve .git file (gitdir: pointer) to actual git dir
  let mut actual_git_dir = actual_git_dir
  // Helper: resolve a .git path (file or dir) to its actual git dir, following
  // gitdir pointers and commondir redirects for linked worktrees.
  fn resolve_dot_git_to_common_dir(fs : OsFs, dot_git_path : String) -> String {
    let mut resolved = dot_git_path
    // Follow gitdir: pointer if it's a file
    if not(fs.is_dir(resolved)) && fs.is_file(resolved) {
      let content = decode_bytes((try? fs.read_file(resolved)).unwrap_or(b""))
      let trimmed = content.trim_end(chars="\r\n").to_string()
      if trimmed.has_prefix("gitdir: ") {
        let linked = (try? trimmed[8:]).unwrap_or(trimmed).to_string()
        resolved = if linked.has_prefix("/") {
          linked
        } else {
          match dot_git_path.rev_find("/") {
            Some(idx) =>
              (try? dot_git_path[:idx]).unwrap_or(dot_git_path).to_string() +
              "/" +
              linked
            None => linked
          }
        }
      }
    }
    // Follow commondir for linked worktrees
    if fs.is_dir(resolved) {
      let commondir_file = resolved + "/commondir"
      if fs.is_file(commondir_file) {
        let cd_val = decode_bytes(
            (try? fs.read_file(commondir_file)).unwrap_or(b""),
          )
          .trim_end(chars="\r\n")
          .to_string()
        if cd_val != "" {
          resolved = if cd_val.has_prefix("/") {
            cd_val
          } else {
            init_normalize_path(resolved + "/" + cd_val)
          }
        }
      }
    }
    resolved
  }

  actual_git_dir = resolve_dot_git_to_common_dir(fs, actual_git_dir)
  // Also resolve from path/.git if actual_git_dir is the sep_dir (not yet existing)
  // This handles the case where we're running from a linked worktree with
  // --separate-git-dir: actual_git_dir was set to sep_dir which doesn't exist,
  // so we need to find the existing git dir from path/.git instead.
  if resolved_sep_git_dir is Some(sep_dir) &&
    actual_git_dir == sep_dir &&
    not(bare) {
    let dot_git = path + "/.git"
    let resolved_from_dot_git = resolve_dot_git_to_common_dir(fs, dot_git)
    if resolved_from_dot_git != dot_git {
      actual_git_dir = resolved_from_dot_git
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
  // Check if the existing repo is bare (including linked worktrees of bare repos)
  // If bare, --separate-git-dir is incompatible
  if resolved_sep_git_dir is Some(_) && is_reinit {
    // Resolve the existing git dir from .git file/dir
    let dot_git = path + "/.git"
    let mut existing_git_dir : String? = None
    if fs.is_dir(dot_git) {
      existing_git_dir = Some(dot_git)
    } else if fs.is_file(dot_git) {
      let gf_content = decode_bytes(fs.read_file(dot_git))
        .trim_end(chars="\r\n")
        .to_string()
      if gf_content.has_prefix("gitdir: ") {
        let linked = (try? gf_content[8:]).unwrap_or(gf_content).to_string()
        let resolved = if linked.has_prefix("/") {
          linked
        } else {
          init_normalize_path(path + "/" + linked)
        }
        existing_git_dir = Some(resolved)
      }
    }
    match existing_git_dir {
      Some(egd) => {
        let mut check_bare_dir = egd
        // For linked worktrees, resolve commondir to find the main repo
        let commondir_path = egd + "/commondir"
        if fs.is_file(commondir_path) {
          let cd_content = decode_bytes(fs.read_file(commondir_path))
            .trim_end(chars="\r\n")
            .to_string()
          if cd_content != "" {
            check_bare_dir = if cd_content.has_prefix("/") {
              cd_content
            } else {
              init_normalize_path(egd + "/" + cd_content)
            }
          }
        }
        // Check config for bare = true
        let config_path = check_bare_dir + "/config"
        if fs.is_file(config_path) {
          let rfs_bare : &@bitcore.RepoFileSystem = fs
          let bare_val = get_config_value(
            rfs_bare,
            config_path,
            "core.bare",
            None,
            false,
          ) catch {
            _ => None
          }
          match bare_val {
            Some(v) if v.to_lower() == "true" => {
              eprint_line(
                "fatal: --separate-git-dir and --bare are incompatible",
              )
              @sys.exit(128)
              return
            }
            _ => ()
          }
        }
      }
      None => ()
    }
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
        if not(ref_format_from_config) &&
          not(ref_format_from_env) &&
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
  let resolved_git_dir = if is_reinit &&
    effective_git_dir is None &&
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
  // For linked worktree with --separate-git-dir: pre-move the common dir.
  // The library function only handles .git file/dir at `path/.git`, but for
  // linked worktrees the common dir (actual_git_dir) is elsewhere and needs
  // to be moved first. Also create a gitdir file at the old common dir location.
  let mut pre_moved_common_dir = false
  let mut old_common_dir : String? = None
  if resolved_sep_git_dir is Some(sep_dir) && is_reinit && not(bare) {
    // Check if actual_git_dir is not the default location for this path
    let default_git_dir = path + "/.git"
    // Only pre-move for linked worktrees (where actual_git_dir was resolved via commondir).
    // For simple gitdir redirects (no commondir), the library handles the move itself.
    let dot_git_for_premove = path + "/.git"
    let has_commondir = if not(fs.is_dir(dot_git_for_premove)) &&
      fs.is_file(dot_git_for_premove) {
      // Follow gitdir: pointer to check for commondir
      let gf = decode_bytes(
          (try? fs.read_file(dot_git_for_premove)).unwrap_or(b""),
        )
        .trim_end(chars="\r\n")
        .to_string()
      if gf.has_prefix("gitdir: ") {
        let linked = (try? gf[8:]).unwrap_or(gf).to_string()
        let abs_linked = if linked.has_prefix("/") {
          linked
        } else {
          init_normalize_path(path + "/" + linked)
        }
        fs.is_file(abs_linked + "/commondir")
      } else {
        false
      }
    } else if fs.is_dir(dot_git_for_premove) {
      fs.is_file(dot_git_for_premove + "/commondir")
    } else {
      false
    }
    if actual_git_dir != default_git_dir &&
      actual_git_dir != sep_dir &&
      has_commondir {
      // actual_git_dir is a common dir elsewhere (e.g., mainwt/.git from a linked worktree)
      if fs.is_dir(actual_git_dir) {
        // Remove destination if it exists (library may have created partial dirs)
        if fs.is_dir(sep_dir) {
          let _ = @process.run("rm", ["-rf", sep_dir], inherit_env=true) catch {
            _ => 1
          }
        }
        // Move common dir to separate-git-dir
        let _ = @process.run("mv", [actual_git_dir, sep_dir], inherit_env=true) catch {
          _ => 1
        }
        // Create gitdir file at old common dir location (e.g., mainwt/.git)
        old_common_dir = Some(actual_git_dir)
        fs.write_string(actual_git_dir, "gitdir: " + sep_dir + "\n")
        actual_git_dir = sep_dir
        pre_moved_common_dir = true
      }
    }
  }
  // Build init options
  let separate_git_dir_for_opts = if pre_moved_common_dir {
    // Already moved, library just needs to write config/templates to actual_git_dir
    None
  } else {
    resolved_sep_git_dir
  }
  let opts : @bitlib.InitOptions = {
    default_branch: branch,
    bare,
    separate_git_dir: separate_git_dir_for_opts,
    template_dir,
    ref_format,
    object_format: object_format.unwrap_or("sha1"),
    is_reinit,
    git_dir: if pre_moved_common_dir {
      Some(actual_git_dir)
    } else {
      resolved_git_dir
    },
    work_tree: config_work_tree,
    shared: shared_mode,
  }
  // Initialize repository
  @bitrepo.init_repo_with_options_with_repo_fs(fs, fs, path, opts)
  // For pre-moved case, update path/.git to point to the correct worktree dir.
  // The .git file still has the old gitdir pointer; extract the worktree name
  // and update it to the new location under actual_git_dir/worktrees/<name>.
  if pre_moved_common_dir {
    let dot_git = path + "/.git"
    if fs.is_file(dot_git) {
      let content = decode_bytes(fs.read_file(dot_git))
        .trim_end(chars="\r\n")
        .to_string()
      if content.has_prefix("gitdir: ") {
        let old_wt_dir = (try? content[8:]).unwrap_or(content).to_string()
        // Extract worktree name from old path (e.g., .../worktrees/linkwt → linkwt)
        let wt_name = match old_wt_dir.rev_find("/") {
          Some(idx) =>
            (try? old_wt_dir[idx + 1:]).unwrap_or(old_wt_dir).to_string()
          None => old_wt_dir
        }
        let new_wt_dir = actual_git_dir + "/worktrees/" + wt_name
        if fs.is_dir(new_wt_dir) {
          fs.write_string(dot_git, "gitdir: " + new_wt_dir + "\n")
        }
      }
    }
  }
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
  // After --separate-git-dir move, update linked worktree gitdir pointers.
  // When the main git dir moves (e.g., mainwt/.git → seprepo/), each linked
  // worktree's .git file still points to the old location. We need to update
  // it to point to the new seprepo/worktrees/<name>/ path.
  if resolved_sep_git_dir is Some(_) && is_reinit {
    let worktrees_dir = actual_git_dir + "/worktrees"
    if fs.is_dir(worktrees_dir) {
      for entry in fs.readdir(worktrees_dir) {
        if entry == "." || entry == ".." {
          continue
        }
        let wt_dir = worktrees_dir + "/" + entry
        let gitdir_file = wt_dir + "/gitdir"
        if fs.is_file(gitdir_file) {
          // Read the linked worktree's working directory path
          let wt_path = decode_bytes(fs.read_file(gitdir_file))
            .trim_end(chars="\r\n")
            .to_string()
          if wt_path != "" {
            // Resolve to absolute path. For relative paths, resolve against the
            // OLD worktree dir location (before move), since the gitdir file
            // still contains the relative path from the original location.
            let abs_wt_path = if wt_path.has_prefix("/") {
              wt_path
            } else {
              // Determine the old worktree dir where the gitdir was originally created.
              // For pre-moved case, old_common_dir has the original common dir.
              // For library-moved case, the original was path/.git.
              let old_base = match old_common_dir {
                Some(old_dir) => old_dir
                None => path + "/.git"
              }
              let old_wt_dir = old_base + "/worktrees/" + entry
              init_normalize_path(old_wt_dir + "/" + wt_path)
            }
            // Update the linked worktree's .git file to point to new location
            // The .git file in the working tree should point to our new worktrees/<name> dir
            let wt_dot_git = if abs_wt_path.has_suffix("/.git") {
              abs_wt_path
            } else {
              abs_wt_path + "/.git"
            }
            if fs.is_file(wt_dot_git) {
              fs.write_string(wt_dot_git, "gitdir: " + wt_dir + "\n")
              // Also update the gitdir file in worktrees/<name>/
              // to have correct path from new location
              if not(wt_path.has_prefix("/")) {
                // Was relative, recalculate from new location
                let rel = compute_relative_path(wt_dir, wt_dot_git)
                fs.write_string(gitdir_file, rel + "\n")
              }
            }
          }
        }
      }
    }
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
/// Compute a relative path from `from_dir` (a directory) to `to_path` (a file/dir).
/// Both paths must be absolute.
fn compute_relative_path(from_dir : String, to_path : String) -> String {
  let from_parts = init_normalize_path(from_dir)
    .split("/")
    .map(fn(v) { v.to_string() })
    .to_array()
  let to_parts = init_normalize_path(to_path)
    .split("/")
    .map(fn(v) { v.to_string() })
    .to_array()
  // Find common prefix length
  let mut common = 0
  let min_len = if from_parts.length() < to_parts.length() {
    from_parts.length()
  } else {
    to_parts.length()
  }
  while common < min_len && from_parts[common] == to_parts[common] {
    common += 1
  }
  let result : Array[String] = []
  // Go up from from_dir
  for i = common; i < from_parts.length(); i = i + 1 {
    if from_parts[i] != "" {
      result.push("..")
    }
  }
  // Go down to to_path
  for i = common; i < to_parts.length(); i = i + 1 {
    result.push(to_parts[i])
  }
  if result.length() == 0 {
    "."
  } else {
    result.join("/")
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
      ".." => if result.length() > 1 { let _ = result.pop() }
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
