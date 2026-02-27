///|
fn need_real_git_for_autocrlf(root : String) -> Bool {
  let fs = OsFs::new()
  let git_dir = resolve_git_dir(fs, root)
  match @bitlib.read_config_value(fs, git_dir + "/config", "core", "autocrlf") {
    Some(value) =>
      match @bitlib.config_strip_quotes(value).to_lower() {
        "true" => true
        "input" => true
        "false" => false
        _ => true
      }
    None => false
  }
}

///|
fn need_real_git_for_gitattributes(root : String) -> Bool {
  let fs = OsFs::new()
  let attr_path = root + "/.gitattributes"
  if not(fs.is_file(attr_path)) {
    return false
  }
  let content = decode_bytes(
    fs.read_file(attr_path) catch {
      _ => Bytes::default()
    },
  )
  for line_view in content.split("\n") {
    let line = trim_string(line_view.to_string())
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    for token_view in line.split(" ") {
      let token = trim_string(token_view.to_string())
      if token.length() == 0 {
        continue
      }
      if token == "crlf" ||
        token == "-crlf" ||
        token == "text" ||
        token == "-text" ||
        token == "eol" ||
        token == "filter" ||
        token.has_prefix("eol=") ||
        token.has_prefix("text=") ||
        token.has_prefix("filter=") ||
        token.has_prefix("working-tree-encoding=") {
        return true
      }
    }
  }
  false
}

///|
fn need_real_git_for_filtering(root : String) -> Bool {
  need_real_git_for_autocrlf(root) || need_real_git_for_gitattributes(root)
}

///|
fn real_git_binary() -> String {
  match @sys.get_env_var("SHIM_REAL_GIT") {
    Some(path) if path.length() > 0 => path
    _ =>
      match @sys.get_env_var("GIT_SHIM_REAL_GIT") {
        Some(path) if path.length() > 0 => path
        _ => "git"
      }
  }
}

///|
async fn run_real_git(cmd : String, args : Array[String]) -> Unit raise Error {
  let real_args : Array[String] = [cmd]
  for arg in args {
    real_args.push(arg)
  }
  let real_git = real_git_binary()
  let code = @process.run(real_git, real_args, inherit_env=true) catch {
    err => {
      eprint_line(err.to_string())
      1
    }
  }
  if code != 0 {
    @sys.exit(code)
  }
}
