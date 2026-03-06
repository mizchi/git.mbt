///|
/// git commit-tree: Create a new commit object

///|
async fn handle_commit_tree(args : Array[String]) -> Unit raise Error {
  let root = get_work_root()
  let fs = OsFs::new()
  let rfs : &@bitcore.RepoFileSystem = fs
  let wfs : &@bitcore.FileSystem = fs
  let git_dir = resolve_git_dir(rfs, root)
  // Parse arguments
  let parents : Array[@bitcore.ObjectId] = []
  let mut tree_hex : String? = None
  let mut message : String? = None
  let mut message_file : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-p" if i + 1 < args.length() => {
        let parent_hex = args[i + 1]
        let parent_id = commit_tree_resolve_hex(rfs, git_dir, parent_hex)
        if not(parents.contains(parent_id)) {
          parents.push(parent_id)
        }
        i += 2
        continue
      }
      "-m" if i + 1 < args.length() => {
        message = Some(args[i + 1])
        i += 2
        continue
      }
      "-F" if i + 1 < args.length() => {
        message_file = Some(args[i + 1])
        i += 2
        continue
      }
      "-S" | "--no-gpg-sign" | "--gpg-sign" => {
        i += 1
        continue
      }
      _ if arg.has_prefix("-S") => {
        i += 1
        continue
      }
      _ if arg.has_prefix("-m") =>
        message = Some(String::unsafe_substring(arg, start=2, end=arg.length()))
      _ if arg.has_prefix("-F") =>
        message_file = Some(
          String::unsafe_substring(arg, start=2, end=arg.length()),
        )
      _ if arg.has_prefix("--gpg-sign=") => ()
      _ if not(arg.has_prefix("-")) && tree_hex is None => tree_hex = Some(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("commit-tree", arg)
      _ => ()
    }
    i += 1
  }
  // Validate tree
  guard tree_hex is Some(tree_str) else {
    eprint_line("fatal: must give exactly one tree")
    @sys.exit(128)
    return
  }
  let tree_id = commit_tree_resolve_hex(rfs, git_dir, tree_str)
  // Get message
  let msg = match message {
    Some(m) => m + "\n"
    None =>
      match message_file {
        Some(path) => {
          let content = if path == "-" {
            decode_bytes(read_all_stdin())
          } else {
            let abs_path = if path.has_prefix("/") {
              path
            } else {
              root + "/" + path
            }
            decode_bytes(
              rfs.read_file(abs_path) catch {
                _ => {
                  eprint_line("fatal: could not read '\{path}'")
                  @sys.exit(128)
                  return
                }
              },
            )
          }
          content
        }
        None => decode_bytes(read_all_stdin())
      }
  }
  // Get author info from environment
  let (author_name, author_email) = get_commit_tree_ident(
    rfs, git_dir, "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL",
  )
  let (committer_name, committer_email) = get_commit_tree_ident(
    rfs, git_dir, "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL",
  )
  let author_ts = get_commit_tree_timestamp("GIT_AUTHOR_DATE")
  let author_tz = get_commit_tree_timezone("GIT_AUTHOR_DATE")
  let committer_ts = get_commit_tree_timestamp("GIT_COMMITTER_DATE")
  let committer_tz = get_commit_tree_timezone("GIT_COMMITTER_DATE")
  let author = "\{author_name} <\{author_email}>"
  let committer = "\{committer_name} <\{committer_email}>"
  let commit = @bitcore.Commit::new(
    tree_id, parents, author, author_ts, author_tz, committer, committer_ts, committer_tz,
    msg,
  )
  let (commit_id, compressed) = @bitcore.create_commit(commit)
  @bitlib.write_object_bytes(wfs, git_dir, commit_id, compressed)
  print_line(commit_id.to_hex())
}

///|
fn get_commit_tree_ident(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  name_env : String,
  email_env : String,
) -> (String, String) {
  let mut name = @sys.get_env_var(name_env).unwrap_or("")
  let mut email = @sys.get_env_var(email_env).unwrap_or("")
  if name == "" || email == "" {
    let config_path = git_dir + "/config"
    if fs.is_file(config_path) {
      let content = decode_bytes(
        fs.read_file(config_path) catch {
          _ => return (name, email)
        },
      )
      let mut in_user = false
      for line_view in content.split("\n") {
        let line = trim_chars(line_view.to_string(), " \t\r")
        if line.has_prefix("[user]") {
          in_user = true
          continue
        }
        if line.has_prefix("[") {
          in_user = false
          continue
        }
        if in_user {
          if name == "" && line.has_prefix("name") {
            match line.find("=") {
              Some(idx) =>
                name = trim_chars(
                  String::unsafe_substring(
                    line,
                    start=idx + 1,
                    end=line.length(),
                  ),
                  " \t",
                )
              None => ()
            }
          }
          if email == "" && line.has_prefix("email") {
            match line.find("=") {
              Some(idx) =>
                email = trim_chars(
                  String::unsafe_substring(
                    line,
                    start=idx + 1,
                    end=line.length(),
                  ),
                  " \t",
                )
              None => ()
            }
          }
        }
      }
    }
  }
  if name == "" {
    name = "Unknown"
  }
  if email == "" {
    email = "unknown@unknown"
  }
  (name, email)
}

///|
fn get_commit_tree_timestamp(env_name : String) -> Int64 {
  match @sys.get_env_var(env_name) {
    Some(raw) =>
      match parse_git_env_timestamp(raw) {
        Some(ts) => ts
        None => get_current_timestamp()
      }
    None => get_current_timestamp()
  }
}

///|
fn get_commit_tree_timezone(env_name : String) -> String {
  match @sys.get_env_var(env_name) {
    Some(raw) =>
      match parse_git_env_timezone(raw) {
        Some(tz) => tz
        None => "+0000"
      }
    None => "+0000"
  }
}

///|
fn commit_tree_resolve_hex(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
  hex : String,
) -> @bitcore.ObjectId raise Error {
  if hex.length() == 40 {
    return @bitcore.ObjectId::from_hex(hex)
  }
  match @bitrepo.rev_parse(fs, git_dir, hex) {
    Some(id) => id
    None =>
      raise @bitcore.GitError::InvalidObject("not a valid object name '\{hex}'")
  }
}
