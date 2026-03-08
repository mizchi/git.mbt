///|
async fn handle_rev_parse(args : Array[String]) -> Unit raise Error {
  let mut sq_quote_mode = false
  let sq_quote_values : Array[String] = []
  for arg in args {
    if sq_quote_mode {
      sq_quote_values.push(arg)
      continue
    }
    if arg == "--sq-quote" {
      sq_quote_mode = true
    }
  }
  if sq_quote_mode {
    let quoted : Array[String] = []
    for value in sq_quote_values {
      quoted.push(shell_single_quote(value))
    }
    if quoted.length() > 0 {
      print_line(" " + quoted.join(" "))
    }
    return
  }
  // Handle --parseopt before any repo checks (it doesn't need a repo)
  for i = 0; i < args.length(); i = i + 1 {
    if args[i] == "--parseopt" {
      handle_parseopt(args)
      return
    }
    if args[i] == "--" {
      break
    }
  }
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  // Check if we're actually in a git repository
  let in_repo = rfs.is_file(git_dir + "/HEAD") || is_bare_repo_dir(git_dir)
  if in_repo {
    match repository_format_error(rfs, git_dir) {
      Some(err_msg) => {
        eprint_line(err_msg)
        @sys.exit(128)
      }
      None => ()
    }
  }
  let cwd_abs = match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(v) => v
    None =>
      match @sys.get_env_var("GIT_SHIM_PWD") {
        Some(v) => v
        None => @sys.get_env_var("PWD").unwrap_or(root)
      }
  }
  // When GIT_DIR is explicitly set (env var or --git-dir flag) and
  // GIT_WORK_TREE is not set, git uses CWD as the work tree root.
  // Override root accordingly for --show-prefix/--show-cdup/--show-toplevel.
  let explicit_git_dir = @sys.get_env_var("GIT_DIR") is Some(_)
  let root = if explicit_git_dir &&
    @sys.get_env_var("GIT_WORK_TREE") is None &&
    @sys.get_env_var("GIT_SHIM_CWD") is Some(_) {
    cwd_abs
  } else {
    root
  }
  let abs_git_dir = if git_dir.has_prefix("/") {
    git_dir
  } else if git_dir == "." {
    cwd_abs
  } else {
    cwd_abs + "/" + git_dir
  }
  let mut revs_only = false
  let mut verify = false
  let mut quiet = false
  let mut show_ref_format = false
  let mut show_object_format = false
  let mut short_length : Int? = None
  let mut abbrev_ref = false
  let mut default_rev : String? = None
  let mut symbolic_full_name = false
  let exclude_patterns : Array[String] = []
  let exclude_hidden : Map[String, Bool] = {} // section -> seen
  let mut path_format : String? = None // "absolute" or "relative"
  let mut prefix : String? = None // --prefix <dir>
  let mut output_object_format : String? = None
  let output_object_format_arg_indices : Map[Int, Bool] = {}
  let mut arg_index = 0
  while arg_index < args.length() {
    let arg = args[arg_index]
    match arg {
      "--revs-only" => revs_only = true
      "--verify" => verify = true
      "--quiet" | "-q" => quiet = true
      "--default" =>
        if arg_index + 1 < args.length() {
          default_rev = Some(args[arg_index + 1])
          arg_index += 2
          continue
        }
      "--prefix" =>
        if arg_index + 1 < args.length() {
          prefix = Some(args[arg_index + 1])
          arg_index += 2
          continue
        } else {
          eprint_line("fatal: --prefix requires an argument")
          @sys.exit(128)
        }
      "--show-ref-format" => show_ref_format = true
      "--show-object-format" => show_object_format = true
      "--short" => short_length = Some(7)
      "--abbrev-ref" => abbrev_ref = true
      "--symbolic-full-name" => symbolic_full_name = true
      "--output-object-format" => {
        output_object_format_arg_indices[arg_index] = true
        if arg_index + 1 >= args.length() {
          eprint_line("fatal: option '--output-object-format' requires a value")
          @sys.exit(128)
        }
        output_object_format = Some(args[arg_index + 1])
        output_object_format_arg_indices[arg_index + 1] = true
        arg_index += 2
        continue
      }
      _ if arg.has_prefix("--short=") =>
        match
          parse_rev_parse_short_length(
            String::unsafe_substring(arg, start=8, end=arg.length()),
          ) {
          Some(value) => short_length = Some(value)
          None => short_length = Some(7)
        }
      _ if arg.has_prefix("--abbrev-ref=") => abbrev_ref = true
      _ if arg.has_prefix("--show-object-format=") => show_object_format = true
      _ if arg.has_prefix("--path-format=") => {
        let mode = String::unsafe_substring(arg, start=14, end=arg.length())
        if mode == "absolute" || mode == "relative" {
          path_format = Some(mode)
        } else {
          eprint_line("error: unsupported argument to --path-format: '\{mode}'")
          @sys.exit(129)
        }
      }
      "--path-format" => {
        eprint_line(
          "error: option `--path-format` requires a value (absolute|relative)",
        )
        @sys.exit(129)
      }
      _ if arg.has_prefix("--output-object-format=") => {
        output_object_format_arg_indices[arg_index] = true
        output_object_format = Some(
          String::unsafe_substring(arg, start=23, end=arg.length()),
        )
      }
      _ => ()
    }
    arg_index += 1
  }
  if output_object_format is Some(raw_output_format) {
    let requested_format = @bitlib.config_strip_quotes(raw_output_format).to_lower()
    if !rev_parse_output_object_format_supported(fs, git_dir, requested_format) {
      eprint_line("fatal: unsupported object format: \{requested_format}")
      @sys.exit(128)
    }
  }
  // --verify mode: exactly one revision argument required
  if verify {
    let rev_args : Array[String] = []
    let mut vi = 0
    let mut end_of_opts = false
    while vi < args.length() {
      if output_object_format_arg_indices.contains(vi) {
        vi += 1
        continue
      }
      let a = args[vi]
      if not(end_of_opts) {
        match a {
          "--verify"
          | "--quiet"
          | "-q"
          | "--short"
          | "--symbolic-full-name"
          | "--abbrev-ref"
          | "--revs-only" => {
            vi += 1
            continue
          }
          "--output-object-format" | "--default" | "--prefix" => {
            vi += 2
            continue
          }
          "--end-of-options" => {
            end_of_opts = true
            vi += 1
            continue
          }
          _ if a.has_prefix("--short=") ||
            a.has_prefix("--abbrev-ref=") ||
            a.has_prefix("--output-object-format=") => {
            vi += 1
            continue
          }
          _ => ()
        }
      }
      if not(a.has_prefix("-")) || end_of_opts {
        rev_args.push(a)
      }
      vi += 1
    }
    if rev_args.length() == 0 && default_rev is Some(d) {
      rev_args.push(d)
    }
    if rev_args.length() != 1 {
      if not(quiet) {
        eprint_line("fatal: Needed a single revision")
      }
      @sys.exit(128)
    }
    let spec = rev_args[0]
    let effective_spec = match parse_at_minus_prefix(spec) {
      Some((n, rest)) =>
        match resolve_at_minus(fs, git_dir, n) {
          Some(branch) => branch + rest
          None => spec
        }
      None => spec
    }
    let id = if effective_spec.find("@{") is Some(_) {
      match resolve_upstream_push_oid(fs, git_dir, effective_spec, quiet) {
        Some(oid) => Some(oid)
        None => resolve_reflog_selector(fs, git_dir, effective_spec, quiet~)
      }
    } else {
      @bitrepo.rev_parse(fs, git_dir, effective_spec)
    }
    match id {
      Some(oid) => {
        let output_oid_hex = rev_parse_resolve_output_oid_hex(
          fs, git_dir, oid, output_object_format,
        )
        match short_length {
          Some(length) => print_line(shorten_oid_hex(output_oid_hex, length))
          None => print_line(output_oid_hex)
        }
      }
      None => {
        if not(quiet) {
          eprint_line("fatal: Needed a single revision")
        }
        @sys.exit(128)
      }
    }
    return
  }
  ignore(quiet)
  let mut process_index = 0
  while process_index < args.length() {
    if output_object_format_arg_indices.contains(process_index) {
      process_index += 1
      continue
    }
    let arg = args[process_index]
    if arg == "--git-path" {
      if process_index + 1 >= args.length() {
        eprint_line("fatal: option '--git-path' requires a value")
        @sys.exit(128)
      }
      let requested = args[process_index + 1]
      let result = rev_parse_resolve_git_path_with_config(
        fs, cwd_abs, git_dir, abs_git_dir, requested, path_format,
      )
      print_line(result)
      process_index += 2
      continue
    }
    if arg.has_prefix("--git-path=") {
      let requested = String::unsafe_substring(arg, start=11, end=arg.length())
      let result = rev_parse_resolve_git_path_with_config(
        fs, cwd_abs, git_dir, abs_git_dir, requested, path_format,
      )
      print_line(result)
      process_index += 1
      continue
    }
    if arg == "--resolve-git-dir" {
      if process_index + 1 >= args.length() {
        eprint_line("fatal: option '--resolve-git-dir' requires a value")
        @sys.exit(128)
      }
      let path = args[process_index + 1]
      let resolved = rev_parse_resolve_git_dir_arg(fs, cwd_abs, path)
      match resolved {
        Some(dir) => print_line(dir)
        None => {
          eprint_line("fatal: not a gitdir '\{path}'")
          @sys.exit(128)
        }
      }
      process_index += 2
      continue
    }
    if arg.has_prefix("--resolve-git-dir=") {
      let path = String::unsafe_substring(arg, start=18, end=arg.length())
      let resolved = rev_parse_resolve_git_dir_arg(fs, cwd_abs, path)
      match resolved {
        Some(dir) => print_line(dir)
        None => {
          eprint_line("fatal: not a gitdir '\{path}'")
          @sys.exit(128)
        }
      }
      process_index += 1
      continue
    }
    match arg {
      "--git-dir" => {
        rev_parse_require_repo(in_repo)
        match path_format {
          Some("absolute") => print_line(abs_git_dir)
          Some("relative") =>
            print_line(rev_parse_make_relative(abs_git_dir, cwd_abs))
          _ => {
            // When GIT_DIR was explicitly set by the user (env var),
            // use the raw value for display (e.g. "../.git")
            let display_git_dir = if explicit_git_dir {
              @sys.get_env_var("GIT_DIR").unwrap_or(git_dir)
            } else {
              git_dir
            }
            print_line(
              rev_parse_display_git_dir(cwd_abs, root, display_git_dir),
            )
          }
        }
      }
      "--absolute-git-dir" => {
        rev_parse_require_repo(in_repo)
        print_line(abs_git_dir)
      }
      "--git-common-dir" =>
        // For now, git-common-dir == git-dir (no worktree support)
        // Default: relative path from cwd (unlike --git-dir which returns absolute)
        match path_format {
          Some("absolute") => print_line(abs_git_dir)
          _ => print_line(rev_parse_make_relative(abs_git_dir, cwd_abs))
        }
      "--is-bare-repository" =>
        print_line(
          if rev_parse_is_bare_repository(fs, git_dir, root) {
            "true"
          } else {
            "false"
          },
        )
      "--is-inside-git-dir" =>
        print_line(
          if rev_parse_is_inside_git_dir(cwd_abs, abs_git_dir) {
            "true"
          } else {
            "false"
          },
        )
      "--is-inside-work-tree" =>
        print_line(
          if rev_parse_is_inside_work_tree(
              fs, git_dir, root, cwd_abs, abs_git_dir,
            ) {
            "true"
          } else {
            "false"
          },
        )
      "--show-prefix" => {
        rev_parse_require_repo(in_repo)
        // Inside .git dir, prefix is empty
        if rev_parse_is_inside_git_dir(cwd_abs, abs_git_dir) {
          print_line("")
        } else {
          let prefix = rev_parse_show_prefix(root, cwd_abs)
          print_line(prefix)
        }
      }
      "--show-cdup" => {
        rev_parse_require_repo(in_repo)
        let cdup = rev_parse_show_cdup(root, cwd_abs)
        print_line(cdup)
      }
      "--show-toplevel" => {
        rev_parse_require_repo(in_repo)
        // Inside .git dir, --show-toplevel should fail
        if rev_parse_is_inside_git_dir(cwd_abs, abs_git_dir) {
          eprint_line("fatal: this operation must be run in a work tree")
          @sys.exit(128)
        }
        let abs_root = rev_parse_resolve_abs_root(root, cwd_abs)
        let display = match path_format {
          Some("relative") => rev_parse_make_relative(abs_root, cwd_abs)
          _ => abs_root
        }
        print_line(display)
      }
      "--local-env-vars" => {
        // Output the list of GIT_* env vars that affect the local repository
        let env_vars = [
          "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG", "GIT_CONFIG_GLOBAL",
          "GIT_CONFIG_SYSTEM", "GIT_DIR", "GIT_COMMON_DIR", "GIT_GRAFT_FILE", "GIT_INDEX_FILE",
          "GIT_NO_REPLACE_OBJECTS", "GIT_OBJECT_DIRECTORY", "GIT_PREFIX", "GIT_REPLACE_REF_BASE",
          "GIT_SHALLOW_FILE", "GIT_WORK_TREE",
        ]
        for v in env_vars {
          print_line(v)
        }
      }
      "--show-ref-format" => {
        let config_path = git_dir + "/config"
        match
          @bitlib.read_config_value(fs, config_path, "extensions", "refstorage") {
          Some(raw_val) => {
            let val = @bitlib.config_strip_quotes(raw_val).to_lower()
            if val == "reftable" {
              print_line("reftable")
            } else if val == "files" || val == "" {
              print_line("files")
            } else {
              eprint_line(
                "error: invalid value for 'extensions.refstorage': '\{val}'",
              )
              @sys.exit(128)
            }
          }
          None =>
            print_line(
              if is_reftable_repo(fs, git_dir) {
                "reftable"
              } else {
                "files"
              },
            )
        }
      }
      "--show-object-format" => print_line(repo_object_format(fs, git_dir))
      _ if arg.has_prefix("--show-object-format=") => {
        let mode = String::unsafe_substring(arg, start=21, end=arg.length())
        if mode == "storage" || mode == "input" || mode == "output" {
          print_line(repo_object_format(fs, git_dir))
        } else if mode == "compat" {
          match repo_compat_object_format(fs, git_dir) {
            Some(compat) => print_line(compat)
            None => print_line("")
          }
        } else {
          eprint_line("fatal: unknown mode for --show-object-format: \{mode}")
          @sys.exit(128)
        }
      }
      "--is-shallow-repository" => {
        // Check if .git/shallow exists
        let shallow_file = git_dir + "/shallow"
        let is_shallow = @fs.is_file(shallow_file) catch { _ => false }
        print_line(if is_shallow { "true" } else { "false" })
      }
      "--revs-only" => ()
      "--verify" => ()
      "--quiet" => ()
      "--short" => ()
      _ if arg.has_prefix("--short=") => ()
      "--abbrev-ref" => ()
      _ if arg.has_prefix("--abbrev-ref=") => ()
      "--symbolic-full-name" => ()
      "--end-of-options" => {
        // Output --end-of-options itself in non-verify mode
        if not(verify) && not(revs_only) {
          print_line("--end-of-options")
        }
        // All remaining args are revisions/paths, not options
        process_index += 1
        while process_index < args.length() {
          let rev_arg = args[process_index]
          // "--" still acts as separator in this mode
          if rev_arg == "--" {
            if not(revs_only) {
              print_line("--")
            }
            process_index += 1
            // Everything after "--" is a path
            while process_index < args.length() {
              if not(revs_only) {
                let file_arg = args[process_index]
                match prefix {
                  Some(p) => print_line(p + file_arg)
                  None => print_line(file_arg)
                }
              }
              process_index += 1
            }
            break
          }
          let effective_arg = match parse_at_minus_prefix(rev_arg) {
            Some((n, rest)) =>
              match resolve_at_minus(fs, git_dir, n) {
                Some(branch) => branch + rest
                None => rev_arg
              }
            None => rev_arg
          }
          // Handle ^@, ^!, ^- parent suffixes (multi-output)
          if rev_parse_handle_parent_suffix(
              fs, git_dir, rev_arg, effective_arg, symbolic_full_name, short_length,
              output_object_format, quiet, revs_only,
            ) {
            process_index += 1
            continue
          }
          if rev_parse_handle_range_op(
              fs, git_dir, rev_arg, effective_arg, symbolic_full_name, short_length,
              output_object_format, quiet, revs_only,
            ) {
            process_index += 1
            continue
          }
          // Handle ^ negation prefix
          if effective_arg.has_prefix("^") && effective_arg.length() > 1 {
            let neg_spec = String::unsafe_substring(
              effective_arg,
              start=1,
              end=effective_arg.length(),
            )
            let id = @bitrepo.rev_parse(fs, git_dir, neg_spec)
            match id {
              Some(oid) => {
                let hex = rev_parse_resolve_output_oid_hex(
                  fs, git_dir, oid, output_object_format,
                )
                match short_length {
                  Some(length) => print_line("^" + shorten_oid_hex(hex, length))
                  None => print_line("^" + hex)
                }
              }
              None =>
                if not(revs_only) {
                  raise @bitcore.GitError::InvalidObject(
                    "unknown revision: " + rev_arg,
                  )
                }
            }
            process_index += 1
            continue
          }
          let id = if effective_arg.find("@{") is Some(_) {
            match resolve_upstream_push_oid(fs, git_dir, effective_arg, quiet) {
              Some(oid) => Some(oid)
              None =>
                resolve_reflog_selector(fs, git_dir, effective_arg, quiet~)
            }
          } else {
            @bitrepo.rev_parse(fs, git_dir, effective_arg)
          }
          match id {
            Some(oid) => {
              let output_oid_hex = rev_parse_resolve_output_oid_hex(
                fs, git_dir, oid, output_object_format,
              )
              match short_length {
                Some(length) =>
                  print_line(shorten_oid_hex(output_oid_hex, length))
                None => print_line(output_oid_hex)
              }
            }
            None =>
              if not(revs_only) {
                raise @bitcore.GitError::InvalidObject(
                  "unknown revision: " + rev_arg,
                )
              }
          }
          process_index += 1
        }
        break
      }
      "--output-object-format" => ()
      _ if arg.has_prefix("--output-object-format=") => ()
      _ if arg.has_prefix("--path-format=") => {
        // Update path_format mid-stream (can change multiple times)
        let mode = String::unsafe_substring(arg, start=14, end=arg.length())
        if mode == "absolute" || mode == "relative" {
          path_format = Some(mode)
        }
        // Error already handled in pre-pass
      }
      "--path-format" => () // Already handled in pre-pass (exits with error)
      "--default" => {
        // Skip the next argument (the default rev value), already handled in pre-pass
        process_index += 2
        continue
      }
      "--prefix" => {
        // Skip the next argument (the prefix value), already handled in pre-pass
        process_index += 2
        continue
      }
      _ if arg.has_prefix("--since=") || arg.has_prefix("--after=") => {
        // Convert --since=DATE to --max-age=TIMESTAMP
        let date_str = if arg.has_prefix("--since=") {
          String::unsafe_substring(arg, start=8, end=arg.length())
        } else {
          String::unsafe_substring(arg, start=8, end=arg.length())
        }
        let timestamp = parse_date_to_timestamp(date_str)
        print_line("--max-age=\{timestamp}")
      }
      _ if arg.has_prefix("--until=") || arg.has_prefix("--before=") => {
        let date_str = if arg.has_prefix("--until=") {
          String::unsafe_substring(arg, start=8, end=arg.length())
        } else {
          String::unsafe_substring(arg, start=9, end=arg.length())
        }
        let timestamp = parse_date_to_timestamp(date_str)
        print_line("--min-age=\{timestamp}")
      }
      "--" => {
        if not(revs_only) {
          print_line("--")
        }
        process_index += 1
        // Everything after "--" is a file path
        while process_index < args.length() {
          if not(revs_only) {
            let file_arg = args[process_index]
            match prefix {
              Some(p) => print_line(p + file_arg)
              None => print_line(file_arg)
            }
          }
          process_index += 1
        }
        break
      }
      "--bisect" =>
        // Output refs/bisect/bad-* (positive) and ^refs/bisect/good-* (negated)
        if symbolic_full_name {
          rev_parse_print_bisect_symbolic(fs, git_dir)
        } else {
          rev_parse_print_bisect(fs, git_dir)
        }
      _ if arg.has_prefix("--exclude=") => {
        let pat = String::unsafe_substring(arg, start=10, end=arg.length())
        exclude_patterns.push(pat)
      }
      _ if arg.has_prefix("--exclude-hidden=") => {
        let section = String::unsafe_substring(arg, start=17, end=arg.length())
        if exclude_hidden.contains(section) {
          eprint_line("fatal: --exclude-hidden= passed more than once")
          @sys.exit(128)
        }
        exclude_hidden[section] = true
      }
      "--branches" => {
        if exclude_hidden.length() > 0 {
          eprint_line(
            "error: options '--exclude-hidden' and '--branches' cannot be used together",
          )
          @sys.exit(1)
        }
        let refs = rev_parse_list_matching_refs(
          fs,
          git_dir,
          "refs/heads/",
          None,
          exclude_patterns,
        )
        for r in refs {
          rev_parse_output_ref(r, symbolic_full_name, short_length)
        }
        exclude_patterns.clear()
      }
      _ if arg.has_prefix("--branches=") => {
        let pat = String::unsafe_substring(arg, start=11, end=arg.length())
        // Check --exclude-hidden conflict
        if exclude_hidden.length() > 0 {
          eprint_line(
            "error: options '--exclude-hidden' and '--branches' cannot be used together",
          )
          @sys.exit(1)
        }
        let refs = rev_parse_list_matching_refs(
          fs,
          git_dir,
          "refs/heads/",
          Some(pat),
          exclude_patterns,
        )
        for r in refs {
          rev_parse_output_ref(r, symbolic_full_name, short_length)
        }
        exclude_patterns.clear()
      }
      "--tags" => {
        if exclude_hidden.length() > 0 {
          eprint_line(
            "error: options '--exclude-hidden' and '--tags' cannot be used together",
          )
          @sys.exit(1)
        }
        let refs = rev_parse_list_matching_refs(
          fs,
          git_dir,
          "refs/tags/",
          None,
          exclude_patterns,
        )
        for r in refs {
          rev_parse_output_ref(r, symbolic_full_name, short_length)
        }
        exclude_patterns.clear()
      }
      _ if arg.has_prefix("--tags=") => {
        let pat = String::unsafe_substring(arg, start=7, end=arg.length())
        if exclude_hidden.length() > 0 {
          eprint_line(
            "error: options '--exclude-hidden' and '--tags' cannot be used together",
          )
          @sys.exit(1)
        }
        let refs = rev_parse_list_matching_refs(
          fs,
          git_dir,
          "refs/tags/",
          Some(pat),
          exclude_patterns,
        )
        for r in refs {
          rev_parse_output_ref(r, symbolic_full_name, short_length)
        }
        exclude_patterns.clear()
      }
      "--remotes" => {
        if exclude_hidden.length() > 0 {
          eprint_line(
            "error: options '--exclude-hidden' and '--remotes' cannot be used together",
          )
          @sys.exit(1)
        }
        let refs = rev_parse_list_matching_refs(
          fs,
          git_dir,
          "refs/remotes/",
          None,
          exclude_patterns,
        )
        for r in refs {
          rev_parse_output_ref(r, symbolic_full_name, short_length)
        }
        exclude_patterns.clear()
      }
      _ if arg.has_prefix("--remotes=") => {
        let pat = String::unsafe_substring(arg, start=10, end=arg.length())
        if exclude_hidden.length() > 0 {
          eprint_line(
            "error: options '--exclude-hidden' and '--remotes' cannot be used together",
          )
          @sys.exit(1)
        }
        let refs = rev_parse_list_matching_refs(
          fs,
          git_dir,
          "refs/remotes/",
          Some(pat),
          exclude_patterns,
        )
        for r in refs {
          rev_parse_output_ref(r, symbolic_full_name, short_length)
        }
        exclude_patterns.clear()
      }
      "--all" => {
        // --all: list all refs (branches + tags + remotes)
        let refs = rev_parse_list_matching_refs(
          fs,
          git_dir,
          "",
          Some("refs/*"),
          exclude_patterns,
        )
        for r in refs {
          rev_parse_output_ref(r, symbolic_full_name, short_length)
        }
        exclude_patterns.clear()
      }
      _ if arg.has_prefix("--glob=") => {
        let raw_pat = String::unsafe_substring(arg, start=7, end=arg.length())
        let pat = rev_parse_normalize_glob_pattern(raw_pat)
        // --glob uses "" prefix and full pattern match
        let refs = rev_parse_list_matching_refs(
          fs,
          git_dir,
          "",
          Some(pat),
          exclude_patterns,
        )
        for r in refs {
          rev_parse_output_ref(r, symbolic_full_name, short_length)
        }
        // --glob does NOT clear exclude patterns (unlike --branches/--tags/--remotes)
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("rev-parse", arg)
      _ => {
        // Expand @{-N} prefix to actual branch name
        let effective_arg0 = match parse_at_minus_prefix(arg) {
          Some((n, rest)) =>
            match resolve_at_minus(fs, git_dir, n) {
              Some(branch) => branch + rest
              None => arg
            }
          None => arg
        }
        // Apply --prefix to revision:./path and revision:../path
        let effective_arg = match prefix {
          Some(p) => rev_parse_apply_prefix_to_colon_path(effective_arg0, p)
          None => effective_arg0
        }
        // Handle ^@, ^!, ^- parent suffixes (multi-output)
        if rev_parse_handle_parent_suffix(
            fs, git_dir, arg, effective_arg, symbolic_full_name, short_length, output_object_format,
            quiet, revs_only,
          ) {
          process_index += 1
          continue
        }
        // Handle .. and ... range operators
        if rev_parse_handle_range_op(
            fs, git_dir, arg, effective_arg, symbolic_full_name, short_length, output_object_format,
            quiet, revs_only,
          ) {
          process_index += 1
          continue
        }
        // Handle ^ negation prefix (e.g., ^HEAD, ^main~2)
        if effective_arg.has_prefix("^") && effective_arg.length() > 1 {
          let neg_spec = String::unsafe_substring(
            effective_arg,
            start=1,
            end=effective_arg.length(),
          )
          if symbolic_full_name {
            let name = resolve_symbolic_full_name(fs, git_dir, neg_spec)
            match name {
              Some(value) => print_line("^\{value}")
              None =>
                if not(revs_only) {
                  raise @bitcore.GitError::InvalidObject(
                    "unknown revision: " + arg,
                  )
                }
            }
          } else {
            let id = @bitrepo.rev_parse(fs, git_dir, neg_spec)
            match id {
              Some(oid) => {
                let hex = rev_parse_resolve_output_oid_hex(
                  fs, git_dir, oid, output_object_format,
                )
                match short_length {
                  Some(length) => print_line("^" + shorten_oid_hex(hex, length))
                  None => print_line("^" + hex)
                }
              }
              None =>
                if not(revs_only) {
                  raise @bitcore.GitError::InvalidObject(
                    "unknown revision: " + arg,
                  )
                }
            }
          }
          process_index += 1
          continue
        }
        if abbrev_ref {
          let name = resolve_abbrev_ref_name(fs, git_dir, effective_arg)
          match name {
            Some(value) => print_line(value)
            None =>
              if not(revs_only) {
                raise @bitcore.GitError::InvalidObject(
                  "unknown revision: " + arg,
                )
              }
          }
        } else if symbolic_full_name {
          // Try upstream/push resolution first for @{upstream}/@{push} specs
          let name = if effective_arg.find("@{") is Some(_) {
            match
              resolve_upstream_push_symbolic(fs, git_dir, effective_arg, quiet) {
              Some(value) => Some(value)
              None => resolve_symbolic_full_name(fs, git_dir, effective_arg)
            }
          } else {
            resolve_symbolic_full_name(fs, git_dir, effective_arg)
          }
          match name {
            Some(value) => print_line(value)
            None =>
              if not(revs_only) {
                raise @bitcore.GitError::InvalidObject(
                  "unknown revision: " + arg,
                )
              }
          }
        } else {
          let id = if effective_arg == "FETCH_HEAD" {
            resolve_fetch_head_oid(fs, git_dir)
          } else if effective_arg.has_prefix(":") &&
            effective_arg.length() > 1 &&
            not(effective_arg.has_prefix(":/")) {
            resolve_index_path_oid(fs, git_dir, effective_arg)
          } else if effective_arg.find("@{") is Some(_) {
            match resolve_upstream_push_oid(fs, git_dir, effective_arg, quiet) {
              Some(oid) => Some(oid)
              None =>
                match
                  resolve_reflog_selector(fs, git_dir, effective_arg, quiet~) {
                  Some(oid) => Some(oid)
                  None =>
                    // Fallback to rev_parse for cases like HEAD:@{upstream} (tree path)
                    @bitrepo.rev_parse(fs, git_dir, effective_arg)
                }
            }
          } else {
            @bitrepo.rev_parse(fs, git_dir, effective_arg)
          }
          match id {
            Some(oid) => {
              let output_oid_hex = rev_parse_resolve_output_oid_hex(
                fs, git_dir, oid, output_object_format,
              )
              match short_length {
                Some(length) =>
                  print_line(shorten_oid_hex(output_oid_hex, length))
                None => print_line(output_oid_hex)
              }
            }
            None =>
              if prefix is Some(p) {
                // With --prefix, treat unresolved args as file paths
                print_line(p + arg)
              } else if not(revs_only) {
                raise @bitcore.GitError::InvalidObject(
                  "unknown revision: " + arg,
                )
              }
          }
        }
      }
    }
    process_index += 1
  }
  ignore(show_ref_format)
  ignore(show_object_format)
  ignore(path_format)
  ignore(prefix)
}

///|
fn rev_parse_display_git_dir(
  cwd_abs : String,
  root : String,
  git_dir : String,
) -> String {
  if git_dir == ".git" || git_dir == ".bit" || git_dir == "." {
    return git_dir
  }
  let root_abs = if root == "." { cwd_abs } else { root }
  if cwd_abs == root_abs {
    if git_dir == root_abs + "/.git" {
      return ".git"
    }
    if git_dir == root_abs + "/.bit" {
      return ".bit"
    }
    if git_dir == root_abs {
      return "."
    }
  }
  // When in a subdirectory, --git-dir returns absolute path
  git_dir
}

///|
fn rev_parse_resolve_git_path_with_config(
  fs : &@bitcore.RepoFileSystem,
  cwd_abs : String,
  git_dir : String,
  abs_git_dir : String,
  requested_path : String,
  path_format : String?,
) -> String {
  // Handle core.hooksPath override for hooks/ paths
  if requested_path == "hooks" || requested_path.has_prefix("hooks/") {
    let config_path = git_dir + "/config"
    let hooks_path = get_config_value(
      fs,
      config_path,
      "core.hookspath",
      None,
      false,
    ) catch {
      _ => None
    }
    match hooks_path {
      Some(custom_hooks) => {
        let suffix = if requested_path.length() > 5 {
          String::unsafe_substring(
            requested_path,
            start=5,
            end=requested_path.length(),
          )
        } else {
          ""
        }
        return custom_hooks + suffix
      }
      None => ()
    }
  }
  // Fall through to normal resolution
  match path_format {
    Some("absolute") => {
      let abs = if abs_git_dir.has_suffix("/") {
        abs_git_dir + requested_path
      } else {
        abs_git_dir + "/" + requested_path
      }
      abs
    }
    Some("relative") => {
      let abs = if abs_git_dir.has_suffix("/") {
        abs_git_dir + requested_path
      } else {
        abs_git_dir + "/" + requested_path
      }
      rev_parse_make_relative(abs, cwd_abs)
    }
    _ => rev_parse_resolve_git_path(cwd_abs, git_dir, requested_path)
  }
}

///|
fn rev_parse_resolve_git_path(
  cwd_abs : String,
  git_dir : String,
  requested_path : String,
) -> String {
  if requested_path.length() == 0 {
    if git_dir == "." {
      return "."
    }
    return git_dir
  }
  if requested_path.has_prefix("/") {
    return requested_path
  }
  let abs_git_dir = if git_dir.has_prefix("/") {
    git_dir
  } else if git_dir == "." {
    cwd_abs
  } else {
    cwd_abs + "/" + git_dir
  }
  let abs_target = if abs_git_dir.has_suffix("/") {
    abs_git_dir + requested_path
  } else {
    abs_git_dir + "/" + requested_path
  }
  // Always compute relative from cwd
  rev_parse_make_relative(abs_target, cwd_abs)
}

///|
fn rev_parse_resolve_output_oid_hex(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  oid : @bitcore.ObjectId,
  output_object_format : String?,
) -> String {
  let oid_hex = oid.to_hex()
  guard output_object_format is Some(raw_requested_format) else {
    return oid_hex
  }
  let requested_format = @bitlib.config_strip_quotes(raw_requested_format).to_lower()
  let storage_format = repo_object_format(fs, git_dir)
  if requested_format == storage_format {
    return oid_hex
  }
  match repo_compat_object_format(fs, git_dir) {
    Some(compat_format) if compat_format == requested_format =>
      match rev_parse_lookup_loose_object_idx(fs, git_dir, oid_hex) {
        Some(mapped) => mapped
        None => oid_hex
      }
    _ => oid_hex
  }
}

///|
fn rev_parse_output_object_format_supported(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  requested_format : String,
) -> Bool {
  if requested_format.length() == 0 {
    return false
  }
  let storage_format = repo_object_format(fs, git_dir)
  if requested_format == storage_format {
    return true
  }
  match repo_compat_object_format(fs, git_dir) {
    Some(compat_format) => compat_format == requested_format
    None => false
  }
}

///|
fn resolve_index_path_oid(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> @bitcore.ObjectId? raise Error {
  let (stage, path_opt) = parse_index_pathspec(spec)
  guard path_opt is Some(path) else { return None }
  // Current index reader keeps one entry per path; stage lookup is supported for :0:path only.
  if stage != 0 {
    return None
  }
  let normalized = normalize_index_pathspec_path(path)
  let entries = @bitlib.read_index_entries(fs, git_dir)
  for entry in entries {
    if normalize_index_pathspec_path(entry.path) == normalized {
      return Some(entry.id)
    }
  }
  None
}

///|
fn parse_index_pathspec(spec : String) -> (Int, String?) {
  if not(spec.has_prefix(":")) || spec.length() <= 1 {
    return (0, None)
  }
  let rest = String::unsafe_substring(spec, start=1, end=spec.length())
  let mut stage = 0
  let mut path = rest
  if rest.length() >= 3 && rest[0] >= '0' && rest[0] <= '3' && rest[1] == ':' {
    stage = rest[0].to_int() - '0'.to_int()
    path = String::unsafe_substring(rest, start=2, end=rest.length())
  }
  if path.length() == 0 {
    (stage, None)
  } else {
    (stage, Some(path))
  }
}

///|
fn normalize_index_pathspec_path(path : String) -> String {
  let mut out = path
  while out.has_prefix("./") {
    out = String::unsafe_substring(out, start=2, end=out.length())
  }
  while out.length() > 1 && out.has_suffix("/") {
    out = String::unsafe_substring(out, start=0, end=out.length() - 1)
  }
  out
}

///|
fn parse_rev_parse_short_length(value : String) -> Int? {
  if value.length() == 0 {
    return None
  }
  let mut result = 0
  for c in value {
    if c < '0' || c > '9' {
      return None
    }
    result = result * 10 + (c.to_int() - '0'.to_int())
  }
  Some(result)
}

///|
fn parse_reflog_selector(spec : String) -> (String, Int)? {
  guard spec.has_suffix("}") else { return None }
  match spec.find("@{") {
    Some(idx) => {
      let number_start = idx + 2
      guard number_start < spec.length() - 1 else { return None }
      let number_text = String::unsafe_substring(
        spec,
        start=number_start,
        end=spec.length() - 1,
      )
      let mut number = 0
      for c in number_text {
        if c < '0' || c > '9' {
          return None
        }
        number = number * 10 + (c.to_int() - '0'.to_int())
      }
      let raw_ref = String::unsafe_substring(spec, start=0, end=idx)
      let refname = if raw_ref == "HEAD" {
        "HEAD"
      } else if raw_ref.length() == 0 {
        // Bare @{N} — use empty string as marker; resolve_reflog_selector
        // will map this to the current branch (not HEAD)
        ""
      } else if raw_ref.has_prefix("refs/") {
        raw_ref
      } else {
        "refs/heads/" + raw_ref
      }
      Some((refname, number))
    }
    None => None
  }
}

///|
/// Parse a reflog date selector like "main@{May 25 2005}" or "HEAD@{2005-05-26}".
/// Returns (refname, date_string) if the @{...} content looks like a date.
fn parse_reflog_date_selector(spec : String) -> (String, String)? {
  guard spec.has_suffix("}") else { return None }
  match spec.find("@{") {
    Some(idx) => {
      let content_start = idx + 2
      guard content_start < spec.length() - 1 else { return None }
      let content = String::unsafe_substring(
        spec,
        start=content_start,
        end=spec.length() - 1,
      )
      let mut all_digits = true
      for c in content {
        if c < '0' || c > '9' {
          all_digits = false
          break
        }
      }
      if all_digits {
        return None
      }
      let raw_ref = String::unsafe_substring(spec, start=0, end=idx)
      let refname = if raw_ref == "HEAD" {
        "HEAD"
      } else if raw_ref.length() == 0 {
        // Bare @{date} — use empty string as marker; resolved later
        // to current branch
        ""
      } else if raw_ref.has_prefix("refs/") {
        raw_ref
      } else {
        "refs/heads/" + raw_ref
      }
      Some((refname, content))
    }
    None => None
  }
}

///|
fn parse_reflog_date(date_str : String) -> Int64? {
  let s = date_str
  if s.find("T") is Some(_) {
    let ts = parse_approxidate_iso8601(s)
    if ts > 0L {
      return Some(ts)
    }
  }
  match parse_approxidate_relative(s) {
    Some(ts) => return Some(ts)
    None => ()
  }
  match parse_approxidate_human(s) {
    Some(ts) => return Some(ts)
    None => ()
  }
  match parse_approxidate_iso_date(s) {
    Some(ts) => return Some(ts)
    None => ()
  }
  None
}

///|
fn parse_approxidate_iso8601(s : String) -> Int64 {
  let chars = s.to_array()
  if chars.length() < 10 {
    return 0L
  }
  let year = parse_date_digits(chars, 0, 4)
  let month = parse_date_digits(chars, 5, 7)
  let day = parse_date_digits(chars, 8, 10)
  let mut hour = 0
  let mut minute = 0
  let mut second = 0
  if chars.length() >= 19 {
    hour = parse_date_digits(chars, 11, 13)
    minute = parse_date_digits(chars, 14, 16)
    second = parse_date_digits(chars, 17, 19)
  }
  let days = days_since_epoch(year, month, day)
  days.to_int64() * 86400L +
  hour.to_int64() * 3600L +
  minute.to_int64() * 60L +
  second.to_int64()
}

///|
fn parse_approxidate_iso_date(s : String) -> Int64? {
  let chars = s.to_array()
  if chars.length() < 10 {
    return None
  }
  guard chars[4] == '-' && chars[7] == '-' else { return None }
  let year = parse_date_digits(chars, 0, 4)
  let month = parse_date_digits(chars, 5, 7)
  let day = parse_date_digits(chars, 8, 10)
  if year < 1970 || month < 1 || month > 12 || day < 1 || day > 31 {
    return None
  }
  let mut hour = 0
  let mut minute = 0
  let mut second = 0
  if chars.length() >= 19 && (chars[10] == ' ' || chars[10] == 'T') {
    hour = parse_date_digits(chars, 11, 13)
    minute = parse_date_digits(chars, 14, 16)
    second = parse_date_digits(chars, 17, 19)
  }
  let days = days_since_epoch(year, month, day)
  Some(
    days.to_int64() * 86400L +
    hour.to_int64() * 3600L +
    minute.to_int64() * 60L +
    second.to_int64(),
  )
}

///|
fn month_name_to_number(name : String) -> Int? {
  let lower = name.to_lower()
  if lower == "jan" || lower == "january" {
    Some(1)
  } else if lower == "feb" || lower == "february" {
    Some(2)
  } else if lower == "mar" || lower == "march" {
    Some(3)
  } else if lower == "apr" || lower == "april" {
    Some(4)
  } else if lower == "may" {
    Some(5)
  } else if lower == "jun" || lower == "june" {
    Some(6)
  } else if lower == "jul" || lower == "july" {
    Some(7)
  } else if lower == "aug" || lower == "august" {
    Some(8)
  } else if lower == "sep" || lower == "september" {
    Some(9)
  } else if lower == "oct" || lower == "october" {
    Some(10)
  } else if lower == "nov" || lower == "november" {
    Some(11)
  } else if lower == "dec" || lower == "december" {
    Some(12)
  } else {
    None
  }
}

///|
fn parse_approxidate_human(s : String) -> Int64? {
  let parts : Array[String] = []
  for p in s.split(" ") {
    let ps = p.to_string()
    if ps.length() > 0 {
      parts.push(ps)
    }
  }
  if parts.length() < 3 {
    return None
  }
  match month_name_to_number(parts[0]) {
    Some(month) => {
      let day = reflog_parse_int_string(parts[1])
      let year = reflog_parse_int_string(parts[2])
      if day <= 0 || year < 1970 {
        return None
      }
      let mut hour = 0
      let mut minute = 0
      let mut second = 0
      if parts.length() >= 4 {
        let time_parts : Array[String] = []
        for tp in parts[3].split(":") {
          time_parts.push(tp.to_string())
        }
        if time_parts.length() >= 1 {
          hour = reflog_parse_int_string(time_parts[0])
        }
        if time_parts.length() >= 2 {
          minute = reflog_parse_int_string(time_parts[1])
        }
        if time_parts.length() >= 3 {
          second = reflog_parse_int_string(time_parts[2])
        }
      }
      let days = days_since_epoch(year, month, day)
      Some(
        days.to_int64() * 86400L +
        hour.to_int64() * 3600L +
        minute.to_int64() * 60L +
        second.to_int64(),
      )
    }
    None => None
  }
}

///|
fn reflog_parse_int_string(s : String) -> Int {
  let mut result = 0
  let mut found = false
  for c in s {
    if c >= '0' && c <= '9' {
      result = result * 10 + (c.to_int() - '0'.to_int())
      found = true
    } else {
      break
    }
  }
  if found {
    result
  } else {
    0
  }
}

///|
fn parse_approxidate_relative(s : String) -> Int64? {
  let lower = s.to_lower()
  let now = get_current_timestamp()
  if lower == "now" {
    return Some(now)
  }
  if lower == "yesterday" {
    return Some(now - 86400L)
  }
  // Split by spaces and dots (git treats both as separators)
  let normalized = lower.replace_all(old=".", new=" ")
  let parts : Array[String] = []
  for p in normalized.split(" ") {
    let ps = p.to_string()
    if ps.length() > 0 {
      parts.push(ps)
    }
  }
  if parts.length() >= 3 && parts[parts.length() - 1] == "ago" {
    let n = reflog_parse_int_string(parts[0])
    if n <= 0 {
      return None
    }
    let unit = parts[1]
    let seconds_per_unit : Int64 = if unit == "second" ||
      unit == "seconds" ||
      unit == "sec" ||
      unit == "secs" {
      1L
    } else if unit == "minute" ||
      unit == "minutes" ||
      unit == "min" ||
      unit == "mins" {
      60L
    } else if unit == "hour" || unit == "hours" {
      3600L
    } else if unit == "day" || unit == "days" {
      86400L
    } else if unit == "week" || unit == "weeks" {
      604800L
    } else if unit == "month" || unit == "months" {
      2592000L
    } else if unit == "year" || unit == "years" {
      31536000L
    } else {
      return None
    }
    return Some(now - n.to_int64() * seconds_per_unit)
  }
  None
}

///|
async fn resolve_reflog_by_date(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  refname : String,
  at_time : Int64,
  quiet? : Bool = false,
) -> @bitcore.ObjectId? raise Error {
  let entries = @bitrepo.read_reflog(fs, git_dir, refname)
  let len = entries.length()
  if len == 0 {
    return None
  }
  let display_ref = if refname.has_prefix("refs/heads/") {
    String::unsafe_substring(refname, start=11, end=refname.length())
  } else {
    refname
  }
  let mut prev_ooid : @bitcore.ObjectId? = None
  let mut found = false
  let mut result_oid : @bitcore.ObjectId? = None
  for i = len - 1; i >= 0; i = i - 1 {
    let entry = entries[i]
    if entry.timestamp <= at_time {
      let cutoff_date = format_timestamp_rfc2822(
        entry.timestamp,
        entry.timezone,
      )
      match prev_ooid {
        Some(po) => {
          result_oid = Some(entry.new_id)
          if po != entry.new_id && not(quiet) {
            eprint_line(
              "warning: log for ref \{refname} has gap after \{cutoff_date}",
            )
          }
        }
        None =>
          if entry.timestamp == at_time {
            result_oid = Some(entry.new_id)
          } else {
            let current = @bitrepo.rev_parse(fs, git_dir, refname)
            result_oid = current
            if not(quiet) {
              match current {
                Some(cur_oid) =>
                  if cur_oid != entry.new_id {
                    eprint_line(
                      "warning: log for ref \{refname} unexpectedly ended on \{cutoff_date}",
                    )
                  }
                None =>
                  eprint_line(
                    "warning: log for ref \{refname} unexpectedly ended on \{cutoff_date}",
                  )
              }
            }
          }
      }
      found = true
      break
    }
    prev_ooid = Some(entry.old_id)
  }
  if found {
    return result_oid
  }
  let oldest = entries[0]
  let oldest_date = format_timestamp_rfc2822(oldest.timestamp, oldest.timezone)
  let zero_oid = @bitcore.ObjectId::zero()
  let oid = if oldest.old_id == zero_oid {
    oldest.new_id
  } else {
    oldest.old_id
  }
  if not(quiet) {
    eprint_line(
      "warning: log for '\{display_ref}' only goes back to \{oldest_date}",
    )
  }
  Some(oid)
}

///|
async fn resolve_reflog_selector(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  spec : String,
  quiet? : Bool = false,
) -> @bitcore.ObjectId? raise Error {
  match parse_reflog_selector(spec) {
    Some(parsed) => {
      let mut refname = parsed.0
      let index = parsed.1
      // Bare @{N}: resolve "" to current branch refname
      if refname.length() == 0 {
        match @bitlib.read_head_ref(fs, git_dir) {
          @bitlib.HeadRef::Branch(name) => refname = "refs/heads/" + name
          @bitlib.HeadRef::Detached(_) =>
            // Detached HEAD: bare @{N} is nonsensical
            return None
        }
      }
      let entries = @bitrepo.read_reflog(fs, git_dir, refname)
      let len = entries.length()
      if index == 0 && len == 0 {
        // @{0} with empty reflog: fall back to reading the ref directly
        return @bitlib.resolve_ref(fs, git_dir, refname)
      }
      if index < len {
        return Some(entries[len - 1 - index].new_id)
      }
      if index == len && len > 0 {
        // @{N} where N == len: return old_id of the oldest entry
        // But if old_id is zero (ref was created at that point), there's
        // no valid state before that
        let old_id = entries[0].old_id
        if old_id != @bitcore.ObjectId::zero() {
          return Some(old_id)
        }
      }
      None
    }
    None =>
      match parse_reflog_date_selector(spec) {
        Some(parsed) => {
          let mut refname = parsed.0
          let date_str = parsed.1
          // Bare @{date}: resolve "" to current branch refname
          if refname.length() == 0 {
            match @bitlib.read_head_ref(fs, git_dir) {
              @bitlib.HeadRef::Branch(name) => refname = "refs/heads/" + name
              @bitlib.HeadRef::Detached(_) => refname = "HEAD"
            }
          }
          match parse_reflog_date(date_str) {
            Some(at_time) =>
              resolve_reflog_by_date(fs, git_dir, refname, at_time, quiet~)
            None => None
          }
        }
        None => None
      }
  }
}

///|
/// Resolve @{-N} to the Nth previously checked-out branch name.
/// Returns the branch name (e.g. "refs/heads/old-branch") or None.
fn resolve_at_minus(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  n : Int,
) -> String? raise Error {
  if n <= 0 {
    return None
  }
  let entries = @bitrepo.read_reflog(fs, git_dir, "HEAD")
  let mut count = 0
  // Walk reflog from newest to oldest (entries are stored oldest-first)
  let len = entries.length()
  for i = len - 1; i >= 0; i = i - 1 {
    let msg = entries[i].message
    // Look for "checkout: moving from X to Y"
    if msg.has_prefix("checkout: moving from ") {
      count += 1
      if count == n {
        // Extract the "from" branch name
        let rest = String::unsafe_substring(msg, start=22, end=msg.length())
        match rest.find(" to ") {
          Some(idx) => {
            let branch = String::unsafe_substring(rest, start=0, end=idx)
            return Some(branch)
          }
          None => return None
        }
      }
    }
  }
  None
}

///|
/// Parse @{-N} from the beginning of a spec.
/// Returns (N, rest_of_spec) if spec starts with @{-N}.
fn parse_at_minus_prefix(spec : String) -> (Int, String)? {
  guard spec.has_prefix("@{-") else { return None }
  let chars = spec.to_array()
  let mut i = 3
  let mut n = 0
  let mut found_digit = false
  while i < chars.length() && chars[i] != '}' {
    if chars[i] < '0' || chars[i] > '9' {
      return None
    }
    n = n * 10 + (chars[i].to_int() - '0'.to_int())
    found_digit = true
    i += 1
  }
  guard found_digit && i < chars.length() && chars[i] == '}' else {
    return None
  }
  let rest = String::unsafe_substring(spec, start=i + 1, end=spec.length())
  Some((n, rest))
}

///|
/// Try to resolve a @{upstream}/@{u}/@{push}/@{p} spec to a ref name.
/// Returns:
///   Some(Ok(ref_name_or_with_rest)) — resolved successfully
///   Some(Err(msg))                  — spec IS upstream/push but resolution failed
///   None                            — spec is NOT upstream/push syntax
fn try_resolve_upstream_push_ref(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> Result[String, String]? {
  match @bitrepo.parse_upstream_push_spec(spec) {
    None => None
    Some((branch, kind, rest)) => {
      let ref_result : Result[String, String] = Ok(
        if kind == "upstream" {
          @bitrepo.resolve_upstream_ref(fs, git_dir, branch)
        } else {
          @bitrepo.resolve_push_ref(fs, git_dir, branch)
        },
      ) catch {
        @bitcore.GitError::InvalidObject(msg) => Err(msg)
        e => Err(e.to_string())
      }
      match ref_result {
        Ok(ref_name) =>
          if rest.length() > 0 {
            Some(Ok(ref_name + rest))
          } else {
            Some(Ok(ref_name))
          }
        Err(msg) => Some(Err(msg))
      }
    }
  }
}

///|
/// Resolve @{upstream}/@{push} spec to a symbolic ref name.
/// Returns None if the spec is not upstream/push syntax.
/// On resolution failure, outputs fatal error and exits 128.
async fn resolve_upstream_push_symbolic(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  spec : String,
  quiet : Bool,
) -> String? raise Error {
  match try_resolve_upstream_push_ref(fs, git_dir, spec) {
    None => None
    Some(Ok(ref_name)) =>
      if ref_name.find("@{") is Some(_) {
        // Has suffix after @{u}/@{push}, e.g. my-side@{u}@{1}
        let id = resolve_reflog_selector(fs, git_dir, ref_name)
        match id {
          Some(oid) => Some(oid.to_hex())
          None => None
        }
      } else {
        Some(ref_name)
      }
    Some(Err(msg)) => {
      if not(quiet) {
        eprint_line("fatal: " + msg)
      }
      @sys.exit(128)
      None
    }
  }
}

///|
/// Resolve @{upstream}/@{push} spec to an OID.
/// Returns None if the spec is not upstream/push syntax.
/// On resolution failure, outputs fatal error and exits 128.
async fn resolve_upstream_push_oid(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  spec : String,
  quiet : Bool,
) -> @bitcore.ObjectId? raise Error {
  match try_resolve_upstream_push_ref(fs, git_dir, spec) {
    None => None
    Some(Ok(ref_name)) =>
      if ref_name.find("@{") is Some(_) {
        // Has suffix, e.g. my-side@{u}@{1} → refs/remotes/origin/side@{1}
        resolve_reflog_selector(fs, git_dir, ref_name)
      } else {
        @bitrepo.rev_parse(fs, git_dir, ref_name)
      }
    Some(Err(msg)) => {
      if not(quiet) {
        eprint_line("fatal: " + msg)
      }
      @sys.exit(128)
      None
    }
  }
}

///|
fn resolve_abbrev_ref_name(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> String? raise Error {
  if spec == "HEAD" {
    return match @bitlib.read_head_ref(fs, git_dir) {
      @bitlib.HeadRef::Branch(name) => Some(name)
      @bitlib.HeadRef::Detached(_) => Some("HEAD")
    }
  }
  if spec.has_prefix("refs/heads/") {
    return Some(String::unsafe_substring(spec, start=11, end=spec.length()))
  }
  if @bitlib.resolve_ref(fs, git_dir, "refs/heads/" + spec) is Some(_) {
    return Some(spec)
  }
  None
}

///|
fn resolve_symbolic_full_name(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> String? raise Error {
  if spec == "HEAD" {
    return match @bitlib.read_head_ref(fs, git_dir) {
      @bitlib.HeadRef::Branch(name) => Some("refs/heads/" + name)
      @bitlib.HeadRef::Detached(_) => Some("HEAD")
    }
  }
  if spec.has_prefix("refs/") {
    return if @bitlib.resolve_ref(fs, git_dir, spec) is Some(_) {
      Some(spec)
    } else {
      None
    }
  }
  let head_ref = "refs/heads/" + spec
  if @bitlib.resolve_ref(fs, git_dir, head_ref) is Some(_) {
    return Some(head_ref)
  }
  let tag_ref = "refs/tags/" + spec
  if @bitlib.resolve_ref(fs, git_dir, tag_ref) is Some(_) {
    return Some(tag_ref)
  }
  let remote_ref = "refs/remotes/" + spec
  if @bitlib.resolve_ref(fs, git_dir, remote_ref) is Some(_) {
    return Some(remote_ref)
  }
  None
}

///|
fn shorten_oid_hex(hex : String, requested : Int) -> String {
  let mut length = requested
  if length < 4 {
    length = 4
  }
  if length > hex.length() {
    length = hex.length()
  }
  String::unsafe_substring(hex, start=0, end=length)
}

///|
fn resolve_fetch_head_oid(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> @bitcore.ObjectId? {
  let fetch_head_path = git_dir + "/FETCH_HEAD"
  guard fs.is_file(fetch_head_path) else { return None }
  let content = decode_bytes(
    fs.read_file(fetch_head_path) catch {
      _ => return None
    },
  )
  let mut result : @bitcore.ObjectId? = None
  for line_view in content.split("\n") {
    let line = line_view.to_string().trim().to_string()
    if line.length() == 0 {
      continue
    }
    let oid_hex = match line.find("\t") {
      Some(idx) => String::unsafe_substring(line, start=0, end=idx)
      None =>
        match line.find(" ") {
          Some(space_idx) =>
            String::unsafe_substring(line, start=0, end=space_idx)
          None => line
        }
    }
    if oid_hex.length() == 0 {
      continue
    }
    let oid = @bitcore.ObjectId::from_hex(oid_hex) catch { _ => continue }
    result = Some(oid)
    break
  }
  result
}

///|
fn shell_single_quote(value : String) -> String {
  let out = StringBuilder::new()
  out.write_char('\'')
  for c in value {
    if c == '\'' {
      out.write_char('\'')
      out.write_char('\\')
      out.write_char('\'')
      out.write_char('\'')
    } else {
      out.write_char(c)
    }
  }
  out.write_char('\'')
  out.to_string()
}

///|
fn peel_cat_file_object_to_type(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  object_id : @bitcore.ObjectId,
  expected_type : @bitcore.ObjectType,
) -> Bytes raise @bitcore.GitError {
  let mut current_id = object_id
  for _ in 0..<8 {
    let current_obj = db.get(fs, current_id)
    guard current_obj is Some(current) else {
      raise @bitcore.GitError::InvalidObject(
        "Object not found: " + current_id.to_hex(),
      )
    }
    if current.obj_type == expected_type {
      return current.data
    }
    guard current.obj_type == @bitcore.ObjectType::Tag else {
      raise @bitcore.GitError::InvalidObject(
        "object is of type \{current.obj_type.to_string()}, not \{expected_type.to_string()}",
      )
    }
    let tag_text = decode_bytes(current.data)
    let tag_target = rev_parse_parse_tag_target_with_compat(db, fs, tag_text)
    guard tag_target is Some(target_id) else {
      raise @bitcore.GitError::InvalidObject("malformed tag object")
    }
    current_id = target_id
  }
  raise @bitcore.GitError::InvalidObject("tag dereference depth exceeded")
}

///|
fn rev_parse_parse_tag_target_with_compat(
  db : @bitlib.ObjectDb,
  fs : &@bitcore.RepoFileSystem,
  tag_text : String,
) -> @bitcore.ObjectId? {
  let target_name = rev_parse_extract_tag_target_name(tag_text)
  guard target_name is Some(raw_name) else { return None }
  let direct_id : @bitcore.ObjectId? = Some(
    @bitcore.ObjectId::from_hex(raw_name),
  ) catch {
    _ => None
  }
  if direct_id is Some(id) && (db.get(fs, id) catch { _ => None }) is Some(_) {
    return direct_id
  }
  let root = get_work_root()
  let git_dir = resolve_git_dir(fs, root)
  match rev_parse_lookup_loose_object_idx(fs, git_dir, raw_name) {
    Some(mapped_name) => {
      let mapped_id : @bitcore.ObjectId? = Some(
        @bitcore.ObjectId::from_hex(mapped_name),
      ) catch {
        _ => None
      }
      if mapped_id is Some(id) &&
        (db.get(fs, id) catch { _ => None }) is Some(_) {
        return mapped_id
      }
      direct_id
    }
    None => direct_id
  }
}

///|
fn rev_parse_extract_tag_target_name(tag_text : String) -> String? {
  for line_view in tag_text.split("\n") {
    let line = line_view.to_string()
    if line.has_prefix("object ") {
      return Some(
        trim_string(String::unsafe_substring(line, start=7, end=line.length())),
      )
    }
  }
  None
}

///|
fn rev_parse_lookup_loose_object_idx(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> String? {
  let idx_path = git_dir + "/objects/loose-object-idx"
  if !fs.is_file(idx_path) {
    return None
  }
  let text = decode_bytes(fs.read_file(idx_path) catch { _ => return None })
  for line_view in text.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    let cols : Array[String] = []
    for col_view in line.split(" ") {
      let col = trim_string(col_view.to_string())
      if col.length() > 0 {
        cols.push(col)
      }
    }
    if cols.length() < 2 {
      continue
    }
    let a = cols[0]
    let b = cols[1]
    if spec == a {
      return Some(b)
    }
    if spec == b {
      return Some(a)
    }
  }
  None
}

///|
fn rev_parse_is_bare_repository(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  root : String,
) -> Bool {
  // Check core.bare config first
  let config_path = git_dir + "/config"
  match @bitlib.read_config_value(fs, config_path, "core", "bare") {
    Some(value) => {
      let v = @bitlib.config_strip_quotes(value).to_lower()
      return v == "true" || v == "yes" || v == "1"
    }
    None => ()
  }
  // If git_dir == root (no separate work tree), it's bare
  let abs_root = if root == "." {
    @sys.get_env_var("PWD").unwrap_or(root)
  } else {
    root
  }
  let abs_git_dir = if git_dir.has_prefix("/") {
    git_dir
  } else {
    abs_root + "/" + git_dir
  }
  abs_git_dir == abs_root
}

///|
fn rev_parse_is_inside_git_dir(cwd_abs : String, abs_git_dir : String) -> Bool {
  if cwd_abs == abs_git_dir {
    return true
  }
  let prefix = if abs_git_dir.has_suffix("/") {
    abs_git_dir
  } else {
    abs_git_dir + "/"
  }
  cwd_abs.has_prefix(prefix)
}

///|
fn rev_parse_is_inside_work_tree(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  root : String,
  cwd_abs : String,
  abs_git_dir : String,
) -> Bool {
  if rev_parse_is_bare_repository(fs, git_dir, root) {
    return false
  }
  if rev_parse_is_inside_git_dir(cwd_abs, abs_git_dir) {
    return false
  }
  true
}

///|
fn rev_parse_show_prefix(root : String, cwd_abs : String) -> String {
  let abs_root = if root == "." {
    @sys.get_env_var("PWD").unwrap_or(root)
  } else {
    root
  }
  if cwd_abs == abs_root {
    return ""
  }
  let root_prefix = if abs_root.has_suffix("/") {
    abs_root
  } else {
    abs_root + "/"
  }
  if cwd_abs.has_prefix(root_prefix) {
    let rel = String::unsafe_substring(
      cwd_abs,
      start=root_prefix.length(),
      end=cwd_abs.length(),
    )
    if rel.has_suffix("/") {
      rel
    } else {
      rel + "/"
    }
  } else {
    ""
  }
}

///|
fn rev_parse_show_cdup(root : String, cwd_abs : String) -> String {
  let abs_root = if root == "." {
    @sys.get_env_var("PWD").unwrap_or(root)
  } else {
    root
  }
  if cwd_abs == abs_root {
    return ""
  }
  let root_prefix = if abs_root.has_suffix("/") {
    abs_root
  } else {
    abs_root + "/"
  }
  if cwd_abs.has_prefix(root_prefix) {
    let rel = String::unsafe_substring(
      cwd_abs,
      start=root_prefix.length(),
      end=cwd_abs.length(),
    )
    let depth = rel.iter().filter(fn(c) { c == '/' }).count() + 1
    let parts : Array[String] = []
    for _ in 0..<depth {
      parts.push("..")
    }
    parts.join("/") + "/"
  } else {
    ""
  }
}

///|
/// Check if a path is a valid git directory (for --resolve-git-dir)
fn rev_parse_resolve_git_dir_arg(
  fs : &@bitcore.RepoFileSystem,
  cwd_abs : String,
  path : String,
) -> String? {
  let abs_path = if path.has_prefix("/") { path } else { cwd_abs + "/" + path }
  // Check if the path is a directory containing HEAD (bare or .git dir)
  if fs.is_file(abs_path + "/HEAD") {
    return Some(abs_path)
  }
  // Check if the path is a gitfile (text file pointing to actual git dir)
  if fs.is_file(abs_path) {
    let content = decode_bytes(
      fs.read_file(abs_path) catch {
        _ => return None
      },
    )
    let trimmed = trim_string(content)
    if trimmed.has_prefix("gitdir: ") {
      let target = String::unsafe_substring(
        trimmed,
        start=8,
        end=trimmed.length(),
      )
      let target_abs = if target.has_prefix("/") {
        target
      } else {
        // Resolve relative to the directory containing the gitfile
        let chars = abs_path.to_array()
        let mut last_slash = -1
        for i in 0..<chars.length() {
          if chars[i] == '/' {
            last_slash = i
          }
        }
        let parent = if last_slash >= 0 {
          String::unsafe_substring(abs_path, start=0, end=last_slash)
        } else {
          cwd_abs
        }
        parent + "/" + target
      }
      if fs.is_file(target_abs + "/HEAD") {
        return Some(target_abs)
      }
    }
  }
  None
}

///|
async fn rev_parse_require_repo(in_repo : Bool) -> Unit {
  if not(in_repo) {
    eprint_line(
      "fatal: not a git repository (or any of the parent directories): .git",
    )
    @sys.exit(128)
  }
}

///|
fn rev_parse_resolve_abs_root(root : String, cwd_abs : String) -> String {
  if root.has_prefix("/") {
    root
  } else {
    let base = match @sys.get_env_var("GIT_SHIM_PWD") {
      Some(v) => v
      None => @sys.get_env_var("PWD").unwrap_or(cwd_abs)
    }
    if root == "." {
      base
    } else {
      normalize_path(base + "/" + root)
    }
  }
}

///|
fn rev_parse_make_relative(abs_target : String, cwd_abs : String) -> String {
  if abs_target == cwd_abs {
    return "./"
  }
  let cwd_prefix = if cwd_abs.has_suffix("/") { cwd_abs } else { cwd_abs + "/" }
  if abs_target.has_prefix(cwd_prefix) {
    return String::unsafe_substring(
      abs_target,
      start=cwd_prefix.length(),
      end=abs_target.length(),
    )
  }
  // Count how many segments we need to go up
  let mut common_len = 0
  let target_chars = abs_target.to_array()
  let cwd_chars = cwd_abs.to_array()
  let min_len = if target_chars.length() < cwd_chars.length() {
    target_chars.length()
  } else {
    cwd_chars.length()
  }
  for i in 0..<min_len {
    if target_chars[i] != cwd_chars[i] {
      break
    }
    if target_chars[i] == '/' {
      common_len = i + 1
    }
  }
  if common_len == 0 && min_len > 0 {
    common_len = 1
  }
  let remaining_cwd = String::unsafe_substring(
    cwd_abs,
    start=common_len,
    end=cwd_abs.length(),
  )
  let remaining_target = String::unsafe_substring(
    abs_target,
    start=common_len,
    end=abs_target.length(),
  )
  let depth = remaining_cwd.iter().filter(fn(c) { c == '/' }).count() + 1
  let parts : Array[String] = []
  for _ in 0..<depth {
    parts.push("..")
  }
  let up = parts.join("/")
  if remaining_target.length() == 0 {
    up
  } else {
    up + "/" + remaining_target
  }
}

///|
fn parse_date_to_timestamp(date_str : String) -> Int64 {
  // Try parsing ISO 8601 format: YYYY-MM-DDTHH:MM:SSZ
  if date_str.find("T") is Some(_) {
    return parse_iso8601_timestamp(date_str)
  }
  // Try parsing as a raw timestamp
  let mut is_numeric = true
  for c in date_str {
    if c < '0' || c > '9' {
      is_numeric = false
      break
    }
  }
  if is_numeric && date_str.length() > 0 {
    let mut result = 0L
    for c in date_str {
      result = result * 10L + (c.to_int() - '0'.to_int()).to_int64()
    }
    return result
  }
  0L
}

///|
fn parse_iso8601_timestamp(date_str : String) -> Int64 {
  let s = date_str.to_array()
  if s.length() < 19 {
    return 0L
  }
  let year = parse_date_digits(s, 0, 4)
  let month = parse_date_digits(s, 5, 7)
  let day = parse_date_digits(s, 8, 10)
  let hour = parse_date_digits(s, 11, 13)
  let minute = parse_date_digits(s, 14, 16)
  let second = parse_date_digits(s, 17, 19)
  let days = days_since_epoch(year, month, day)
  days.to_int64() * 86400L +
  hour.to_int64() * 3600L +
  minute.to_int64() * 60L +
  second.to_int64()
}

///|
fn parse_date_digits(chars : Array[Char], start : Int, end : Int) -> Int {
  let mut result = 0
  for i in start..<end {
    if i < chars.length() {
      let c = chars[i]
      if c >= '0' && c <= '9' {
        result = result * 10 + (c.to_int() - '0'.to_int())
      }
    }
  }
  result
}

///|
fn days_since_epoch(year : Int, month : Int, day : Int) -> Int {
  let mut days = 0
  for y in 1970..<year {
    days += if is_leap_year(y) { 366 } else { 365 }
  }
  let month_days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  for m in 1..<month {
    days += month_days[m - 1]
    if m == 2 && is_leap_year(year) {
      days += 1
    }
  }
  days + day - 1
}

///|
async fn rev_parse_print_bisect_symbolic(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Unit raise Error {
  let bisect_refs = rev_parse_read_bisect_refs(fs, git_dir)
  let bad_refs : Array[String] = []
  let good_refs : Array[String] = []
  for entry in bisect_refs {
    if entry.0.has_prefix("refs/bisect/bad") {
      bad_refs.push(entry.0)
    } else if entry.0.has_prefix("refs/bisect/good") {
      good_refs.push(entry.0)
    }
  }
  bad_refs.sort()
  good_refs.sort()
  for r in bad_refs {
    print_line(r)
  }
  for r in good_refs {
    print_line("^\{r}")
  }
}

///|
async fn rev_parse_print_bisect(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Unit raise Error {
  let bisect_refs = rev_parse_read_bisect_refs(fs, git_dir)
  let bad_entries : Array[(String, String)] = []
  let good_entries : Array[(String, String)] = []
  for entry in bisect_refs {
    if entry.0.has_prefix("refs/bisect/bad") {
      bad_entries.push(entry)
    } else if entry.0.has_prefix("refs/bisect/good") {
      good_entries.push(entry)
    }
  }
  bad_entries.sort_by(fn(a, b) { a.0.compare(b.0) })
  good_entries.sort_by(fn(a, b) { a.0.compare(b.0) })
  for entry in bad_entries {
    print_line(entry.1)
  }
  for entry in good_entries {
    print_line("^\{entry.1}")
  }
}

///|
fn rev_parse_read_bisect_refs(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> Array[(String, String)] raise Error {
  let result : Array[(String, String)] = []
  let bisect_dir = git_dir + "/refs/bisect"
  let is_dir = @fs.is_dir(bisect_dir) catch { _ => false }
  if not(is_dir) {
    return result
  }
  let entries = @fs.read_dir(bisect_dir) catch { _ => return result }
  for name in entries {
    let ref_path = bisect_dir + "/" + name
    let is_file = @fs.is_file(ref_path) catch { _ => false }
    if is_file {
      let content = decode_bytes(fs.read_file(ref_path) catch { e => raise e })
      let oid_hex = trim_string(content)
      result.push(("refs/bisect/" + name, oid_hex))
    }
  }
  // Also check packed-refs
  let packed_path = git_dir + "/packed-refs"
  let packed_exists = @fs.is_file(packed_path) catch { _ => false }
  if packed_exists {
    let content = decode_bytes(fs.read_file(packed_path) catch { e => raise e })
    for line_view in content.split("\n") {
      let line = trim_string(line_view.to_string())
      if line.length() == 0 || line.has_prefix("#") || line.has_prefix("^") {
        continue
      }
      match line.find(" ") {
        Some(idx) => {
          let oid = String::unsafe_substring(line, start=0, end=idx)
          let refname = String::unsafe_substring(
            line,
            start=idx + 1,
            end=line.length(),
          )
          if refname.has_prefix("refs/bisect/") {
            // Don't add if already found in loose refs
            let mut found = false
            for existing in result {
              if existing.0 == refname {
                found = true
                break
              }
            }
            if not(found) {
              result.push((refname, oid))
            }
          }
        }
        None => ()
      }
    }
  }
  result
}

///|
/// Apply --prefix to revision:path specs where the path is relative (./ or ../).
/// For example, with prefix "sub1/":
///   "HEAD:./file1" → "HEAD:sub1/file1"
///   "HEAD:../top" → "HEAD:top" (sub1/ + ../top → top)
///   "HEAD:top" → "HEAD:top" (absolute path, not affected)
fn rev_parse_apply_prefix_to_colon_path(
  spec : String,
  prefix : String,
) -> String {
  // Find the colon separator (revision:path)
  guard spec.find(":") is Some(colon_idx) else { return spec }
  guard colon_idx > 0 else { return spec }
  let path_part = String::unsafe_substring(
    spec,
    start=colon_idx + 1,
    end=spec.length(),
  )
  // Only apply prefix when path starts with ./ or ../
  if not(path_part.has_prefix("./")) && not(path_part.has_prefix("../")) {
    return spec
  }
  let rev_part = String::unsafe_substring(spec, start=0, end=colon_idx)
  let combined = prefix + path_part
  // Normalize ./ and ../ components
  let normalized = rev_parse_normalize_path(combined)
  rev_part + ":" + normalized
}

///|
/// Normalize a path by resolving . and .. components.
/// "sub1/./file1" → "sub1/file1"
/// "sub1/../top" → "top"
fn rev_parse_normalize_path(path : String) -> String {
  let parts = path.split("/")
  let result : Array[String] = []
  for part in parts {
    let s = part.to_string()
    if s == "." {
      continue
    } else if s == ".." {
      if result.length() > 0 {
        let _ = result.pop()
      }
    } else {
      result.push(s)
    }
  }
  result.join("/")
}

///|
enum ParseoptOptType {
  ParseoptOption
  ParseoptGroup
} derive(Eq)

///|
struct ParseoptOpt {
  opt_type : ParseoptOptType
  short_name : Char
  long_name : String
  help : String
  argh : String
  has_arg : Bool
  opt_arg : Bool
  non_neg : Bool
  hidden : Bool
}

///|
async fn handle_parseopt(args : Array[String]) -> Unit raise Error {
  let mut keep_dashdash = false
  let mut stop_at_non_option = false
  let mut stuck_long = false
  let mut dashdash_idx = -1
  for i = 0; i < args.length(); i = i + 1 {
    match args[i] {
      "--parseopt" => continue
      "--keep-dashdash" => keep_dashdash = true
      "--stop-at-non-option" => stop_at_non_option = true
      "--stuck-long" => stuck_long = true
      "--" => {
        dashdash_idx = i
        break
      }
      _ => ()
    }
  }
  if dashdash_idx < 0 {
    eprint_line("usage: git rev-parse --parseopt [<options>] -- [<args>...]")
    @sys.exit(129)
  }
  let parse_args : Array[String] = []
  for i = dashdash_idx + 1; i < args.length(); i = i + 1 {
    parse_args.push(args[i])
  }
  let stdin_bytes = read_all_stdin()
  let stdin_str = decode_bytes(stdin_bytes)
  let lines = parseopt_split_lines(stdin_str)
  let usage_lines : Array[String] = []
  let mut spec_start = 0
  let mut found_separator = false
  for i = 0; i < lines.length(); i = i + 1 {
    if lines[i] == "--" {
      spec_start = i + 1
      found_separator = true
      break
    }
    usage_lines.push(lines[i])
  }
  if not(found_separator) {
    eprint_line("fatal: premature end of input")
    @sys.exit(128)
  }
  if usage_lines.length() == 0 {
    eprint_line("fatal: no usage string given before the `--' separator")
    @sys.exit(128)
  }
  let opts = parseopt_parse_spec(lines, spec_start)
  let mut show_help = false
  let mut show_help_all = false
  for arg in parse_args {
    if arg == "-h" || arg == "--help" {
      show_help = true
      break
    }
    if arg == "--help-all" {
      show_help_all = true
      break
    }
    if arg == "--" {
      break
    }
  }
  if show_help || show_help_all {
    let help = parseopt_format_help(usage_lines, opts, show_help_all)
    parseopt_print_string("cat <<\\EOF\n")
    parseopt_print_string(help)
    parseopt_print_string("EOF\n")
    @sys.exit(129)
  }
  let result = parseopt_parse_args(
    parse_args, opts, keep_dashdash, stop_at_non_option, stuck_long, usage_lines,
  )
  print_line(result)
}

///|
fn parseopt_split_lines(s : String) -> Array[String] {
  let lines : Array[String] = []
  let buf = StringBuilder::new()
  for c in s {
    if c == '\n' {
      lines.push(buf.to_string())
      buf.reset()
    } else {
      buf.write_char(c)
    }
  }
  let last = buf.to_string()
  if last.length() > 0 {
    lines.push(last)
  }
  lines
}

///|
async fn parseopt_parse_spec(
  lines : Array[String],
  start : Int,
) -> Array[ParseoptOpt] raise Error {
  let opts : Array[ParseoptOpt] = []
  for i = start; i < lines.length(); i = i + 1 {
    let line = lines[i]
    if line.length() == 0 {
      continue
    }
    let help_idx = parseopt_find_space(line)
    match help_idx {
      None => {
        let header_text = parseopt_skipspaces(line)
        opts.push({
          opt_type: ParseoptGroup,
          short_name: '\u0000',
          long_name: "",
          help: header_text,
          argh: "",
          has_arg: false,
          opt_arg: false,
          non_neg: false,
          hidden: false,
        })
      }
      Some(idx) => {
        if idx == 0 {
          let header_text = parseopt_skipspaces(line)
          opts.push({
            opt_type: ParseoptGroup,
            short_name: '\u0000',
            long_name: "",
            help: header_text,
            argh: "",
            has_arg: false,
            opt_arg: false,
            non_neg: false,
            hidden: false,
          })
          continue
        }
        let name_part = String::unsafe_substring(line, start=0, end=idx)
        let help_text = parseopt_skipspaces(
          String::unsafe_substring(line, start=idx, end=line.length()),
        )
        let flags_idx = parseopt_find_flags(name_part)
        let name_str = if flags_idx < name_part.length() {
          String::unsafe_substring(name_part, start=0, end=flags_idx)
        } else {
          name_part
        }
        if name_str.length() == 0 {
          eprint_line("fatal: missing opt-spec before option flags")
          @sys.exit(128)
        }
        let mut has_arg = false
        let mut opt_arg = false
        let mut non_neg = false
        let mut hidden = false
        let mut argh_start = flags_idx
        for fi = flags_idx; fi < name_part.length(); fi = fi + 1 {
          let fc = name_part[fi]
          if fc == '=' {
            has_arg = true
            argh_start = fi + 1
          } else if fc == '?' {
            opt_arg = true
            argh_start = fi + 1
          } else if fc == '!' {
            non_neg = true
            argh_start = fi + 1
          } else if fc == '*' {
            hidden = true
            argh_start = fi + 1
          } else {
            break
          }
        }
        let argh = if argh_start < name_part.length() {
          String::unsafe_substring(
            name_part,
            start=argh_start,
            end=name_part.length(),
          )
        } else {
          ""
        }
        let mut short_name : Char = '\u0000'
        let mut long_name = ""
        if name_str.length() == 1 {
          short_name = name_str[0].to_int().unsafe_to_char()
        } else if name_str.length() > 1 && name_str[1] == ',' {
          short_name = name_str[0].to_int().unsafe_to_char()
          long_name = String::unsafe_substring(
            name_str,
            start=2,
            end=name_str.length(),
          )
        } else {
          long_name = name_str
        }
        opts.push({
          opt_type: ParseoptOption,
          short_name,
          long_name,
          help: help_text,
          argh,
          has_arg,
          opt_arg,
          non_neg,
          hidden,
        })
      }
    }
  }
  opts
}

///|
fn parseopt_find_space(s : String) -> Int? {
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i]
    if c == ' ' || c == '\t' {
      return Some(i)
    }
  }
  None
}

///|
fn parseopt_skipspaces(s : String) -> String {
  let mut i = 0
  while i < s.length() {
    let c = s[i]
    if c != ' ' && c != '\t' {
      break
    }
    i = i + 1
  }
  String::unsafe_substring(s, start=i, end=s.length())
}

///|
fn parseopt_find_flags(s : String) -> Int {
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i]
    if c == '*' || c == '=' || c == '?' || c == '!' {
      return i
    }
  }
  s.length()
}

///|
fn parseopt_format_help(
  usage_lines : Array[String],
  opts : Array[ParseoptOpt],
  show_all : Bool,
) -> String {
  let out = StringBuilder::new()
  let mut blurb_start = -1
  for i = 0; i < usage_lines.length(); i = i + 1 {
    if usage_lines[i].length() == 0 {
      blurb_start = i
      break
    }
  }
  let usage_end = if blurb_start >= 0 {
    blurb_start
  } else {
    usage_lines.length()
  }
  for i = 0; i < usage_end; i = i + 1 {
    let line = usage_lines[i]
    if i == 0 {
      out.write_string("usage: ")
      out.write_string(line)
      out.write_char('\n')
    } else {
      out.write_string("   or: ")
      out.write_string(line)
      out.write_char('\n')
    }
  }
  if blurb_start >= 0 {
    out.write_char('\n')
    for j = blurb_start + 1; j < usage_lines.length(); j = j + 1 {
      let bline = usage_lines[j]
      if bline.length() == 0 {
        out.write_char('\n')
      } else {
        out.write_string("    ")
        out.write_string(bline)
        out.write_char('\n')
      }
    }
  }
  let all_long_names : Array[String] = []
  for opt in opts {
    if opt.long_name.length() > 0 {
      all_long_names.push(opt.long_name)
    }
  }
  let mut has_visible_opts = false
  for opt in opts {
    if opt.opt_type == ParseoptOption && (show_all || not(opt.hidden)) {
      has_visible_opts = true
      break
    }
  }
  if not(has_visible_opts) {
    out.write_char('\n')
    return out.to_string()
  }
  let mut need_newline = true
  for opt in opts {
    match opt.opt_type {
      ParseoptGroup => {
        out.write_char('\n')
        need_newline = false
        if opt.help.length() > 0 {
          out.write_string(opt.help)
          out.write_char('\n')
        }
        continue
      }
      ParseoptOption => ()
    }
    if not(show_all) && opt.hidden {
      continue
    }
    if need_newline {
      out.write_char('\n')
      need_newline = false
    }
    let mut pos = 4
    out.write_string("    ")
    if opt.short_name != '\u0000' {
      out.write_char('-')
      out.write_char(opt.short_name)
      pos = pos + 2
    }
    if opt.short_name != '\u0000' && opt.long_name.length() > 0 {
      out.write_string(", ")
      pos = pos + 2
    }
    if opt.long_name.length() > 0 {
      let long_name = opt.long_name
      let mut positive_name : String? = None
      if opt.non_neg || long_name.has_prefix("no-") {
        out.write_string("--")
        out.write_string(long_name)
        pos = pos + 2 + long_name.length()
        if long_name.has_prefix("no-") && not(opt.non_neg) {
          positive_name = Some(
            String::unsafe_substring(long_name, start=3, end=long_name.length()),
          )
        }
      } else {
        out.write_string("--[no-]")
        out.write_string(long_name)
        pos = pos + 7 + long_name.length()
      }
      let argh_str = parseopt_format_argh(opt)
      out.write_string(argh_str)
      pos = pos + argh_str.length()
      parseopt_write_padded_help(out, pos, opt.help)
      match positive_name {
        Some(pname) => {
          let mut found = false
          for ln in all_long_names {
            if ln == pname {
              found = true
              break
            }
          }
          if not(found) {
            out.write_string("    --")
            out.write_string(pname)
            let ppos = 4 + 2 + pname.length()
            parseopt_write_padded_help(out, ppos, "opposite of --no-" + pname)
          }
        }
        None => ()
      }
    } else {
      let argh_str = parseopt_format_argh_short(opt)
      out.write_string(argh_str)
      pos = pos + argh_str.length()
      parseopt_write_padded_help(out, pos, opt.help)
    }
  }
  out.write_char('\n')
  out.to_string()
}

///|
fn parseopt_format_argh(opt : ParseoptOpt) -> String {
  if not(opt.has_arg) && not(opt.opt_arg) {
    return ""
  }
  let has_custom_argh = opt.argh.length() > 0
  let argh = if has_custom_argh { opt.argh } else { "..." }
  let literal = not(has_custom_argh) || parseopt_argh_is_literal(argh)
  if opt.opt_arg {
    if opt.long_name.length() > 0 {
      if literal {
        "[=" + argh + "]"
      } else {
        "[=<" + argh + ">]"
      }
    } else if literal {
      "[" + argh + "]"
    } else {
      "[<" + argh + ">]"
    }
  } else if literal {
    " " + argh
  } else {
    " <" + argh + ">"
  }
}

///|
fn parseopt_format_argh_short(opt : ParseoptOpt) -> String {
  if not(opt.has_arg) && not(opt.opt_arg) {
    return ""
  }
  let has_custom_argh = opt.argh.length() > 0
  let argh = if has_custom_argh { opt.argh } else { "..." }
  let literal = not(has_custom_argh) || parseopt_argh_is_literal(argh)
  if opt.opt_arg {
    if literal {
      "[" + argh + "]"
    } else {
      "[<" + argh + ">]"
    }
  } else if literal {
    " " + argh
  } else {
    " <" + argh + ">"
  }
}

///|
fn parseopt_argh_is_literal(argh : String) -> Bool {
  for c in argh {
    if c == '<' ||
      c == '>' ||
      c == '(' ||
      c == ')' ||
      c == '[' ||
      c == ']' ||
      c == '|' {
      return true
    }
  }
  false
}

///|
fn parseopt_write_padded_help(
  out : StringBuilder,
  pos : Int,
  help_text : String,
) -> Unit {
  let usage_opts_width = 26
  if pos < usage_opts_width {
    for p = pos; p < usage_opts_width; p = p + 1 {
      out.write_char(' ')
    }
  } else {
    out.write_char('\n')
    for p = 0; p < usage_opts_width; p = p + 1 {
      out.write_char(' ')
    }
  }
  out.write_string(help_text)
  out.write_char('\n')
}

///|
async fn parseopt_parse_args(
  args : Array[String],
  opts : Array[ParseoptOpt],
  keep_dashdash : Bool,
  stop_at_non_option : Bool,
  stuck_long : Bool,
  usage_lines : Array[String],
) -> String raise Error {
  let parsed = StringBuilder::new()
  parsed.write_string("set --")
  let remaining : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--" {
      if keep_dashdash {
        remaining.push("--")
      }
      i = i + 1
      while i < args.length() {
        remaining.push(args[i])
        i = i + 1
      }
      break
    }
    if arg.length() > 0 && arg[0] == '-' && arg.length() > 1 {
      if arg.length() > 1 && arg[1] == '-' {
        let result = parseopt_match_long(arg, opts, stuck_long, args, i)
        match result {
          ParseoptMatchOk(output, consumed) => {
            parsed.write_string(output)
            i = i + consumed
            continue
          }
          ParseoptMatchError(msg) => {
            eprint_line(msg)
            let help = parseopt_format_help(usage_lines, opts, false)
            eprint_string(help)
            @sys.exit(129)
          }
        }
      } else {
        let result = parseopt_match_short(arg, opts, stuck_long, args, i)
        match result {
          ParseoptMatchOk(output, consumed) => {
            parsed.write_string(output)
            i = i + consumed
            continue
          }
          ParseoptMatchError(msg) => {
            eprint_line(msg)
            let help = parseopt_format_help(usage_lines, opts, false)
            eprint_string(help)
            @sys.exit(129)
          }
        }
      }
    } else {
      if stop_at_non_option {
        while i < args.length() {
          remaining.push(args[i])
          i = i + 1
        }
        break
      }
      remaining.push(arg)
      i = i + 1
    }
  }
  parsed.write_string(" --")
  for r in remaining {
    parsed.write_char(' ')
    parsed.write_string(shell_single_quote(r))
  }
  parsed.to_string()
}

///|
enum ParseoptMatchResult {
  ParseoptMatchOk(String, Int)
  ParseoptMatchError(String)
}

///|
fn parseopt_match_long(
  arg : String,
  opts : Array[ParseoptOpt],
  stuck_long : Bool,
  all_args : Array[String],
  arg_idx : Int,
) -> ParseoptMatchResult {
  let arg_without_dashes = String::unsafe_substring(
    arg,
    start=2,
    end=arg.length(),
  )
  let mut opt_name = arg_without_dashes
  let mut opt_value : String? = None
  match parseopt_find_char(arg_without_dashes, '=') {
    Some(eq_idx) => {
      opt_name = String::unsafe_substring(
        arg_without_dashes,
        start=0,
        end=eq_idx,
      )
      opt_value = Some(
        String::unsafe_substring(
          arg_without_dashes,
          start=eq_idx + 1,
          end=arg_without_dashes.length(),
        ),
      )
    }
    None => ()
  }
  let mut is_unset = false
  let mut no_stripped = opt_name
  let mut arg_starts_with_no_no = false
  if opt_name.has_prefix("no-") {
    let after_no = String::unsafe_substring(
      opt_name,
      start=3,
      end=opt_name.length(),
    )
    if after_no.has_prefix("no-") {
      arg_starts_with_no_no = true
      no_stripped = String::unsafe_substring(
        after_no,
        start=3,
        end=after_no.length(),
      )
    } else {
      is_unset = true
      no_stripped = after_no
    }
  }
  let mut exact_match : (ParseoptOpt, Bool)? = None
  let mut abbrev_match : (ParseoptOpt, Bool)? = None
  let mut ambiguous_match : (ParseoptOpt, Bool)? = None
  for opt in opts {
    if opt.opt_type != ParseoptOption {
      continue
    }
    if opt.long_name.length() == 0 {
      continue
    }
    let long_name = opt.long_name
    let allow_unset = not(opt.non_neg)
    let mut opt_unset = false
    let mut check_name = long_name
    if long_name.has_prefix("no-") {
      opt_unset = true
      check_name = String::unsafe_substring(
        long_name,
        start=3,
        end=long_name.length(),
      )
    } else if arg_starts_with_no_no {
      continue
    }
    let xor_unset = if is_unset { not(opt_unset) } else { opt_unset }
    if xor_unset && not(allow_unset) {
      continue
    }
    let effective_unset = if is_unset { not(opt_unset) } else { opt_unset }
    if no_stripped == check_name {
      exact_match = Some((opt, effective_unset))
      break
    }
    if check_name.has_prefix(no_stripped) {
      match abbrev_match {
        Some(_) => ambiguous_match = abbrev_match
        None => ()
      }
      abbrev_match = Some((opt, effective_unset))
    }
    if allow_unset &&
      not(is_unset) &&
      not(arg_starts_with_no_no) &&
      not(opt_unset) {
      let full_neg = "no-" + long_name
      if full_neg.has_prefix(opt_name) && opt_name.length() < full_neg.length() {
        match abbrev_match {
          Some(_) => ambiguous_match = abbrev_match
          None => ()
        }
        abbrev_match = Some((opt, true))
      }
    }
  }
  let disallow_abbreviated = match
    @sys.get_env_var("GIT_TEST_DISALLOW_ABBREVIATED_OPTIONS") {
    Some(v) => v == "true" || v == "1" || v == "yes"
    None => false
  }
  let matched = match exact_match {
    Some(m) => Some(m)
    None => {
      if disallow_abbreviated {
        match abbrev_match {
          Some(_) =>
            return ParseoptMatchError(
              "error: disallowed abbreviated or ambiguous option '" +
              opt_name +
              "'",
            )
          None => ()
        }
      }
      match ambiguous_match {
        Some(amb) => {
          let (amb_opt, amb_unset) = amb
          let (abb_opt, abb_unset) = abbrev_match.unwrap()
          let amb_prefix = if amb_unset { "no-" } else { "" }
          let abb_prefix = if abb_unset { "no-" } else { "" }
          return ParseoptMatchError(
            "error: ambiguous option: " +
            opt_name +
            " (could be --" +
            amb_prefix +
            amb_opt.long_name +
            " or --" +
            abb_prefix +
            abb_opt.long_name +
            ")",
          )
        }
        None => ()
      }
      abbrev_match
    }
  }
  match matched {
    None => ParseoptMatchError("error: unknown option `" + opt_name + "'")
    Some((opt, unset)) =>
      parseopt_format_matched_long(
        opt, unset, opt_value, stuck_long, all_args, arg_idx,
      )
  }
}

///|
fn parseopt_format_matched_long(
  opt : ParseoptOpt,
  unset : Bool,
  opt_value : String?,
  stuck_long : Bool,
  all_args : Array[String],
  arg_idx : Int,
) -> ParseoptMatchResult {
  let out = StringBuilder::new()
  let mut consumed = 1
  if unset {
    out.write_string(" --no-")
    if opt.long_name.has_prefix("no-") {
      out.write_string(opt.long_name)
    } else {
      out.write_string(opt.long_name)
    }
  } else if opt.short_name != '\u0000' && not(stuck_long) {
    out.write_string(" -")
    out.write_char(opt.short_name)
  } else if opt.long_name.length() > 0 {
    out.write_string(" --")
    out.write_string(opt.long_name)
  } else {
    out.write_string(" -")
    out.write_char(opt.short_name)
  }
  if opt.has_arg || opt.opt_arg {
    match opt_value {
      Some(v) => {
        if stuck_long && opt.long_name.length() > 0 && not(unset) {
          let out2 = StringBuilder::new()
          out2.write_string(" --")
          out2.write_string(opt.long_name)
          out2.write_char('=')
          out2.write_string(shell_single_quote(v))
          return ParseoptMatchOk(out2.to_string(), consumed)
        }
        if not(stuck_long) {
          out.write_char(' ')
        } else if opt.long_name.length() > 0 {
          out.write_char('=')
        }
        out.write_string(shell_single_quote(v))
      }
      None =>
        if opt.has_arg && not(opt.opt_arg) {
          if arg_idx + 1 < all_args.length() {
            let next_val = all_args[arg_idx + 1]
            consumed = 2
            if stuck_long && opt.long_name.length() > 0 {
              out.write_char('=')
              out.write_string(shell_single_quote(next_val))
            } else {
              out.write_char(' ')
              out.write_string(shell_single_quote(next_val))
            }
          } else {
            return ParseoptMatchError(
              "error: option `" + opt.long_name + "' requires a value",
            )
          }
        }
    }
  }
  ParseoptMatchOk(out.to_string(), consumed)
}

///|
fn parseopt_match_short(
  arg : String,
  opts : Array[ParseoptOpt],
  stuck_long : Bool,
  all_args : Array[String],
  arg_idx : Int,
) -> ParseoptMatchResult {
  let out = StringBuilder::new()
  let mut consumed = 1
  let mut ci = 1
  while ci < arg.length() {
    let ch = arg[ci].to_int().unsafe_to_char()
    let mut found_opt : ParseoptOpt? = None
    for opt in opts {
      if opt.opt_type == ParseoptOption && opt.short_name == ch {
        found_opt = Some(opt)
        break
      }
    }
    match found_opt {
      None =>
        return ParseoptMatchError(
          "error: unknown switch `" + ch.to_string() + "'",
        )
      Some(opt) => {
        if stuck_long && opt.long_name.length() > 0 {
          out.write_string(" --")
          out.write_string(opt.long_name)
        } else {
          out.write_string(" -")
          out.write_char(ch)
        }
        if opt.has_arg || opt.opt_arg {
          let rest_start = ci + 1
          if rest_start < arg.length() {
            let rest = String::unsafe_substring(
              arg,
              start=rest_start,
              end=arg.length(),
            )
            if stuck_long && opt.long_name.length() > 0 {
              out.write_char('=')
              out.write_string(shell_single_quote(rest))
            } else {
              if not(stuck_long) {
                out.write_char(' ')
              }
              out.write_string(shell_single_quote(rest))
            }
            ci = arg.length()
          } else {
            if opt.has_arg && not(opt.opt_arg) {
              if arg_idx + consumed < all_args.length() {
                let next_val = all_args[arg_idx + consumed]
                consumed = consumed + 1
                if stuck_long && opt.long_name.length() > 0 {
                  out.write_char('=')
                  out.write_string(shell_single_quote(next_val))
                } else {
                  out.write_char(' ')
                  out.write_string(shell_single_quote(next_val))
                }
              } else {
                return ParseoptMatchError(
                  "error: option `" + ch.to_string() + "' requires a value",
                )
              }
            }
            ci = ci + 1
          }
          continue
        }
        ci = ci + 1
      }
    }
  }
  ParseoptMatchOk(out.to_string(), consumed)
}

///|
fn parseopt_find_char(s : String, ch : Char) -> Int? {
  for i = 0; i < s.length(); i = i + 1 {
    if s[i].to_int() == ch.to_int() {
      return Some(i)
    }
  }
  None
}

///|
async fn eprint_string(s : String) -> Unit {
  @stdio.stderr.write(str_to_bytes(s))
}

///|
async fn parseopt_print_string(s : String) -> Unit {
  @stdio.stdout.write(str_to_bytes(s))
}

///|
async fn rev_parse_output_ref(
  ref_entry : (String, @bitcore.ObjectId),
  symbolic_full_name : Bool,
  short_length : Int?,
) -> Unit raise Error {
  if symbolic_full_name {
    print_line(ref_entry.0)
  } else {
    let hex = ref_entry.1.to_hex()
    match short_length {
      Some(length) => print_line(shorten_oid_hex(hex, length))
      None => print_line(hex)
    }
  }
}

///|
/// Glob match for ref patterns. Supports `*` (any chars) and `?` (single char).
/// Non-glob patterns match as exact or path prefix (with `/` boundary).
fn rev_parse_glob_match(text : String, pattern : String) -> Bool {
  let has_star = pattern.find("*") is Some(_)
  let has_question = pattern.find("?") is Some(_)
  if not(has_star) && not(has_question) {
    // Non-glob: exact match or path-prefix match
    text == pattern ||
    (
      text.has_prefix(pattern) &&
      pattern.length() < text.length() &&
      (pattern[pattern.length() - 1] == '/' || text[pattern.length()] == '/')
    )
  } else {
    // Glob match with * and ?
    let t = text.to_array()
    let p = pattern.to_array()
    rev_parse_glob_match_inner(t, 0, p, 0)
  }
}

///|
fn rev_parse_glob_match_inner(
  t : Array[Char],
  ti : Int,
  p : Array[Char],
  pi : Int,
) -> Bool {
  let mut ti = ti
  let mut pi = pi
  while pi < p.length() {
    if p[pi] == '*' {
      pi += 1
      // Try matching * against 0..N chars
      for k = ti; k <= t.length(); k = k + 1 {
        if rev_parse_glob_match_inner(t, k, p, pi) {
          return true
        }
      }
      return false
    } else if p[pi] == '?' {
      if ti >= t.length() {
        return false
      }
      ti += 1
      pi += 1
    } else {
      if ti >= t.length() || t[ti] != p[pi] {
        return false
      }
      ti += 1
      pi += 1
    }
  }
  ti == t.length()
}

///|
/// List refs matching a glob pattern under a given prefix, applying exclude patterns.
/// prefix: "refs/heads/", "refs/tags/", "refs/remotes/", or "" for --glob
/// pattern: optional sub-pattern (e.g., "subspace/*" for --branches=subspace/*)
/// exclude_patterns: list of patterns to exclude (from --exclude)
fn rev_parse_list_matching_refs(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  prefix : String,
  pattern : String?,
  exclude_patterns : Array[String],
) -> Array[(String, @bitcore.ObjectId)] {
  let all_refs = @bitlib.list_refs_with_ids(fs, git_dir, Some(prefix))
  let result : Array[(String, @bitcore.ObjectId)] = []
  for refname, oid in all_refs {
    // Apply glob pattern if specified
    match pattern {
      Some(pat) => {
        // The pattern matches against the portion after prefix
        let short_name = if refname.has_prefix(prefix) {
          String::unsafe_substring(
            refname,
            start=prefix.length(),
            end=refname.length(),
          )
        } else {
          refname
        }
        // Build full pattern: prefix + pattern (for --glob, prefix is already in pattern)
        let full_pattern = if prefix.length() > 0 { prefix + pat } else { pat }
        if not(rev_parse_glob_match(refname, full_pattern)) {
          continue
        }
        // Also try short name match for simple patterns
        ignore(short_name)
      }
      None => ()
    }
    // Apply exclude patterns
    let mut excluded = false
    for excl in exclude_patterns {
      // Exclude matches against short name (after refs/heads/, refs/tags/, etc.)
      let short_name = if refname.has_prefix("refs/heads/") {
        String::unsafe_substring(refname, start=11, end=refname.length())
      } else if refname.has_prefix("refs/tags/") {
        String::unsafe_substring(refname, start=10, end=refname.length())
      } else if refname.has_prefix("refs/remotes/") {
        String::unsafe_substring(refname, start=13, end=refname.length())
      } else {
        refname
      }
      // git matches exclude against short name only (after stripping refs/heads/ etc.)
      // Also try full refname match only when exclude starts with "refs/"
      if rev_parse_glob_match(short_name, excl) ||
        (excl.has_prefix("refs/") && rev_parse_glob_match(refname, excl)) {
        excluded = true
        break
      }
    }
    if not(excluded) {
      result.push((refname, oid))
    }
  }
  // Sort by refname for deterministic output
  result.sort_by(fn(a, b) { lexicographic_compare(a.0, b.0) })
  result
}

///|
/// Handle A..B and A...B range operators. Returns true if handled.
async fn rev_parse_handle_range_op(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  arg : String,
  effective_arg : String,
  symbolic_full_name : Bool,
  short_length : Int?,
  output_object_format : String?,
  quiet : Bool,
  revs_only : Bool,
) -> Bool raise Error {
  // Check for ... (symmetric difference) first, then .. (range)
  // Don't match :/ (commit message search) or : (tree path)
  match effective_arg.find("...") {
    Some(idx) if idx > 0 && idx + 3 <= effective_arg.length() => {
      let left_spec = String::unsafe_substring(effective_arg, start=0, end=idx)
      let right_spec = String::unsafe_substring(
        effective_arg,
        start=idx + 3,
        end=effective_arg.length(),
      )
      if right_spec.length() == 0 {
        return false
      }
      let left_id = @bitrepo.rev_parse(fs, git_dir, left_spec)
      let right_id = @bitrepo.rev_parse(fs, git_dir, right_spec)
      guard left_id is Some(lid) && right_id is Some(rid) else {
        if not(quiet) && not(revs_only) {
          raise @bitcore.GitError::InvalidObject("unknown revision: " + arg)
        }
        return true
      }
      // A...B = A B ^merge-base(A,B)
      if symbolic_full_name {
        let left_name = resolve_symbolic_full_name(fs, git_dir, left_spec)
        let right_name = resolve_symbolic_full_name(fs, git_dir, right_spec)
        print_line(left_name.unwrap_or(left_spec))
        print_line(right_name.unwrap_or(right_spec))
        // merge-base output as ^OID (no symbolic form for merge-base)
        let mb = rev_parse_find_merge_base(fs, git_dir, lid, rid)
        match mb {
          Some(mb_id) => print_line("^\{mb_id.to_hex()}")
          None => ()
        }
      } else {
        let lhex = rev_parse_resolve_output_oid_hex(
          fs, git_dir, lid, output_object_format,
        )
        let rhex = rev_parse_resolve_output_oid_hex(
          fs, git_dir, rid, output_object_format,
        )
        match short_length {
          Some(length) => {
            print_line(shorten_oid_hex(lhex, length))
            print_line(shorten_oid_hex(rhex, length))
          }
          None => {
            print_line(lhex)
            print_line(rhex)
          }
        }
        let mb = rev_parse_find_merge_base(fs, git_dir, lid, rid)
        match mb {
          Some(mb_id) => {
            let mbhex = rev_parse_resolve_output_oid_hex(
              fs, git_dir, mb_id, output_object_format,
            )
            match short_length {
              Some(length) => print_line("^" + shorten_oid_hex(mbhex, length))
              None => print_line("^" + mbhex)
            }
          }
          None => ()
        }
      }
      return true
    }
    _ => ()
  }
  // Check for .. (range)
  match effective_arg.find("..") {
    Some(idx) if idx > 0 && idx + 2 <= effective_arg.length() => {
      // Make sure it's not ... (already handled above)
      if idx + 2 < effective_arg.length() &&
        effective_arg.to_array()[idx + 2] == '.' {
        return false
      }
      let left_spec = String::unsafe_substring(effective_arg, start=0, end=idx)
      let right_spec = String::unsafe_substring(
        effective_arg,
        start=idx + 2,
        end=effective_arg.length(),
      )
      if right_spec.length() == 0 {
        return false
      }
      let left_id = @bitrepo.rev_parse(fs, git_dir, left_spec)
      let right_id = @bitrepo.rev_parse(fs, git_dir, right_spec)
      guard left_id is Some(lid) && right_id is Some(rid) else {
        if not(quiet) && not(revs_only) {
          raise @bitcore.GitError::InvalidObject("unknown revision: " + arg)
        }
        return true
      }
      // A..B = ^A B
      if symbolic_full_name {
        let left_name = resolve_symbolic_full_name(fs, git_dir, left_spec)
        let right_name = resolve_symbolic_full_name(fs, git_dir, right_spec)
        print_line("^\{left_name.unwrap_or(left_spec)}")
        print_line(right_name.unwrap_or(right_spec))
      } else {
        let lhex = rev_parse_resolve_output_oid_hex(
          fs, git_dir, lid, output_object_format,
        )
        let rhex = rev_parse_resolve_output_oid_hex(
          fs, git_dir, rid, output_object_format,
        )
        match short_length {
          Some(length) => {
            print_line("^" + shorten_oid_hex(lhex, length))
            print_line(shorten_oid_hex(rhex, length))
          }
          None => {
            print_line("^" + lhex)
            print_line(rhex)
          }
        }
      }
      return true
    }
    _ => ()
  }
  false
}

///|
/// Find merge-base of two commits (simple BFS approach).
async fn rev_parse_find_merge_base(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  a : @bitcore.ObjectId,
  b : @bitcore.ObjectId,
) -> @bitcore.ObjectId? raise Error {
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  // Collect ancestors of A
  let ancestors_a : Map[String, Bool] = {}
  let queue : Array[@bitcore.ObjectId] = [a]
  while queue.length() > 0 {
    let current = queue.unsafe_pop()
    let hex = current.to_hex()
    if ancestors_a.contains(hex) {
      continue
    }
    ancestors_a[hex] = true
    let obj = db.get(fs, current)
    match obj {
      Some(o) =>
        if o.obj_type == @bitcore.ObjectType::Commit {
          let info = @bitcore.parse_commit(o.data)
          for parent in info.parents {
            queue.push(parent)
          }
        }
      None => ()
    }
  }
  // BFS from B, find first ancestor of A
  let queue2 : Array[@bitcore.ObjectId] = [b]
  let seen : Map[String, Bool] = {}
  while queue2.length() > 0 {
    let current = queue2.unsafe_pop()
    let hex = current.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    if ancestors_a.contains(hex) {
      return Some(current)
    }
    let obj = db.get(fs, current)
    match obj {
      Some(o) =>
        if o.obj_type == @bitcore.ObjectType::Commit {
          let info = @bitcore.parse_commit(o.data)
          for parent in info.parents {
            queue2.push(parent)
          }
        }
      None => ()
    }
  }
  None
}

///|
/// Parse parent suffix: ^@, ^!, ^-N from the end of a revision spec.
/// Returns (base_spec, suffix_type) or None if no parent suffix found.
/// suffix_type: "@" for ^@, "!" for ^!, "-N" for ^-N (N >= 1)
fn rev_parse_parse_parent_suffix(spec : String) -> (String, String)? {
  // Check for ^@ suffix
  if spec.has_suffix("^@") && spec.length() > 2 {
    let base = String::unsafe_substring(spec, start=0, end=spec.length() - 2)
    return Some((base, "@"))
  }
  // Check for ^! suffix
  if spec.has_suffix("^!") && spec.length() > 2 {
    let base = String::unsafe_substring(spec, start=0, end=spec.length() - 2)
    return Some((base, "!"))
  }
  // Check for ^-N or ^- suffix
  // Find last ^- in the spec
  let chars = spec.to_array()
  let len = chars.length()
  // Search backwards for "^-"
  for i = len - 1; i >= 1; i = i - 1 {
    if chars[i - 1] == '^' && chars[i] == '-' {
      let base = String::unsafe_substring(spec, start=0, end=i - 1)
      if base.length() == 0 {
        return None
      }
      let rest = String::unsafe_substring(spec, start=i + 1, end=len)
      if rest.length() == 0 {
        // ^- means ^-1
        return Some((base, "-1"))
      }
      // Check rest is all digits
      let mut all_digits = true
      for c in rest {
        if c < '0' || c > '9' {
          all_digits = false
          break
        }
      }
      if all_digits {
        return Some((base, "-" + rest))
      }
      // Contains non-digit after ^-N: invalid (e.g., ^-1x, ^-^)
      return Some((base, "-invalid:" + rest))
    }
  }
  None
}

///|
/// Get commit parents for a given OID.
async fn rev_parse_get_commit_parents(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  oid : @bitcore.ObjectId,
) -> Array[@bitcore.ObjectId] raise Error {
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let obj = db.get(fs, oid)
  guard obj is Some(o) else { return [] }
  if o.obj_type != @bitcore.ObjectType::Commit {
    return []
  }
  let info = @bitcore.parse_commit(o.data)
  info.parents
}

///|
/// Handle ^@, ^!, ^- parent suffixes. Returns true if handled.
async fn rev_parse_handle_parent_suffix(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  arg : String,
  effective_arg : String,
  symbolic_full_name : Bool,
  short_length : Int?,
  output_object_format : String?,
  quiet : Bool,
  revs_only : Bool,
) -> Bool raise Error {
  let parsed = rev_parse_parse_parent_suffix(effective_arg)
  guard parsed is Some((base_spec, suffix_type)) else { return false }
  // Resolve the base revision
  let base_id = @bitrepo.rev_parse(fs, git_dir, base_spec)
  if suffix_type == "@" {
    // ^@ = all parents
    guard base_id is Some(oid) else {
      if not(quiet) && not(revs_only) {
        eprint_line("fatal: bad revision '\{arg}'")
        @sys.exit(128)
      }
      return true
    }
    let parents = rev_parse_get_commit_parents(fs, git_dir, oid)
    if parents.length() == 0 {
      // tree object or root commit - error
      if not(quiet) && not(revs_only) {
        eprint_line("fatal: bad revision '\{arg}'")
        @sys.exit(128)
      }
      return true
    }
    if symbolic_full_name {
      // Symbolic: output base^1, base^2, etc.
      for i = 0; i < parents.length(); i = i + 1 {
        print_line("\{base_spec}^\{i + 1}")
      }
    } else {
      for parent in parents {
        let hex = rev_parse_resolve_output_oid_hex(
          fs, git_dir, parent, output_object_format,
        )
        match short_length {
          Some(length) => print_line(shorten_oid_hex(hex, length))
          None => print_line(hex)
        }
      }
    }
    return true
  }
  if suffix_type == "!" {
    // ^! = commit itself, then ^parent1 ^parent2 ...
    guard base_id is Some(oid) else {
      if not(quiet) && not(revs_only) {
        eprint_line("fatal: bad revision '\{arg}'")
        @sys.exit(128)
      }
      return true
    }
    let parents = rev_parse_get_commit_parents(fs, git_dir, oid)
    if symbolic_full_name {
      print_line(base_spec)
      for i = 0; i < parents.length(); i = i + 1 {
        print_line("^\{base_spec}^\{i + 1}")
      }
    } else {
      let hex = rev_parse_resolve_output_oid_hex(
        fs, git_dir, oid, output_object_format,
      )
      match short_length {
        Some(length) => print_line(shorten_oid_hex(hex, length))
        None => print_line(hex)
      }
      for parent in parents {
        let phex = rev_parse_resolve_output_oid_hex(
          fs, git_dir, parent, output_object_format,
        )
        match short_length {
          Some(length) => print_line("^" + shorten_oid_hex(phex, length))
          None => print_line("^" + phex)
        }
      }
    }
    return true
  }
  if suffix_type.has_prefix("-") {
    // ^-N = base^N..base
    let n_str = String::unsafe_substring(
      suffix_type,
      start=1,
      end=suffix_type.length(),
    )
    // Check for invalid suffix (garbage after ^-N)
    if n_str.has_prefix("invalid:") {
      eprint_line("fatal: bad revision '\{arg}'")
      @sys.exit(128)
      return true
    }
    let mut n = 0
    for c in n_str {
      n = n * 10 + (c.to_int() - '0'.to_int())
    }
    if n == 0 {
      eprint_line("fatal: bad revision '\{arg}'")
      @sys.exit(128)
      return true
    }
    guard base_id is Some(oid) else {
      if not(quiet) && not(revs_only) {
        eprint_line("fatal: bad revision '\{arg}'")
        @sys.exit(128)
      }
      return true
    }
    let parents = rev_parse_get_commit_parents(fs, git_dir, oid)
    if n > parents.length() {
      eprint_line("fatal: bad revision '\{arg}'")
      @sys.exit(128)
      return true
    }
    let parent_id = parents[n - 1]
    // ^-N = base^N..base = base ^base^N
    if symbolic_full_name {
      print_line("^\{base_spec}^\{n}")
      print_line(base_spec)
    } else {
      let phex = rev_parse_resolve_output_oid_hex(
        fs, git_dir, parent_id, output_object_format,
      )
      let hex = rev_parse_resolve_output_oid_hex(
        fs, git_dir, oid, output_object_format,
      )
      match short_length {
        Some(length) => {
          print_line("^" + shorten_oid_hex(phex, length))
          print_line(shorten_oid_hex(hex, length))
        }
        None => {
          print_line("^" + phex)
          print_line(hex)
        }
      }
    }
    return true
  }
  false
}

///|
/// Normalize a glob pattern, expanding shorthand prefixes.
/// "heads/*" -> "refs/heads/*", "refs/heads/*" -> "refs/heads/*"
fn rev_parse_normalize_glob_pattern(pattern : String) -> String {
  if pattern.has_prefix("refs/") {
    pattern
  } else if pattern.has_prefix("heads/") {
    "refs/" + pattern
  } else if pattern.has_prefix("tags/") {
    "refs/" + pattern
  } else if pattern.has_prefix("remotes/") {
    "refs/" + pattern
  } else {
    "refs/" + pattern
  }
}
