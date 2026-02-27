///|

///|
async fn show_status_command_help() -> Unit {
  show_simple_command_help(
    "git status [<options>] [--] [<pathspec>...]",
    summary="Show the working tree status.",
  )
}

///|
fn status_need_real_git() -> Bool {
  let root = get_work_root()
  need_real_git_for_filtering(root)
}

///|
fn status_storage_runtime_parsed_args(
  args : Array[String],
) -> @runtime.StorageStatusArgs? {
  if status_need_real_git() {
    return None
  }
  let parsed = storage_runtime_parse_command("status", args) catch {
    _ => return None
  }
  match parsed {
    @runtime.StorageCommand::Status(status_args) => Some(status_args)
    _ => None
  }
}

///|
fn status_should_use_storage_runtime(args : Array[String]) -> Bool {
  match status_storage_runtime_parsed_args(args) {
    Some(parsed) => parsed.porcelain || parsed.short
    None => false
  }
}

///|
async fn handle_status(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let mut root = get_work_root()
  let mut git_dir = resolve_git_dir(fs, root)
  let mut has_git_dir = fs.is_dir(git_dir)
  let mut has_git_file = if has_git_dir { false } else { fs.is_file(git_dir) }
  if not(has_git_dir) && not(has_git_file) {
    match find_repo_root(".") {
      Some(found) => {
        root = found
        git_dir = resolve_git_dir(fs, root)
        has_git_dir = fs.is_dir(git_dir)
        has_git_file = if has_git_dir { false } else { fs.is_file(git_dir) }
      }
      None =>
        raise @bitcore.GitError::InvalidObject(
          "Not a git repository (or any of the parent directories): .git/.bit",
        )
    }
  }
  if not(has_git_dir) && not(has_git_file) {
    raise @bitcore.GitError::InvalidObject(
      "Not a git repository (or any of the parent directories): .git/.bit",
    )
  }
  if status_should_use_storage_runtime(args) {
    match status_storage_runtime_parsed_args(args) {
      Some(parsed) => {
        @runtime.run_storage_command(
          fs,
          fs,
          root,
          @runtime.StorageCommand::Status(parsed),
        )
        return
      }
      None => ()
    }
  }
  let mut porcelain = false
  let mut short = false
  let mut show_branch = false
  for arg in args {
    match arg {
      "--porcelain" | "--porcelain=v1" => porcelain = true
      "-s" | "--short" => short = true
      "-b" | "--branch" => show_branch = true
      "-sb" => {
        short = true
        show_branch = true
      }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("status", arg)
      _ => ()
    }
  }
  // Show subdir-clone info if applicable (only in non-porcelain mode)
  if not(porcelain) && not(short) {
    match get_subdir_info(fs, git_dir) {
      Some((remote, path, base)) => {
        print_line("# subdir-clone: \{path} from \{remote}")
        print_line("# base: \{base[:7].to_string()}")
        print_line("")
      }
      None => ()
    }
  }
  if porcelain || short {
    if show_branch {
      let head = @bitlib.read_head_ref(fs, git_dir) catch {
        err if @async.is_cancellation_error(err) => raise err
        _ => return ()
      }
      match head {
        @bitlib.HeadRef::Branch(name) => print_line("## \{name}")
        @bitlib.HeadRef::Detached(id) =>
          print_line("## HEAD (detached at \{id.to_hex()[:7].to_string()})")
      }
    }
    let lines = @bitlib.status_porcelain(fs, root)
    for line in lines {
      print_line(line)
    }
  } else {
    let text = @bitlib.status_text(fs, root)
    print_str(text)
  }
}
