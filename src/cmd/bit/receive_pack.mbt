///|
async fn handle_receive_pack(args : Array[String]) -> Unit {
  // Handle -h/--help/--help-all option
  for arg in args {
    if arg == "-h" || arg == "--help" || arg == "--help-all" {
      print_line("usage: git receive-pack <git-dir>")
      @sys.exit(129)
    }
  }
  // Parse additional flags
  let mut stateless_rpc = false
  let mut skip_connectivity_check = false
  for arg in args {
    if arg == "--stateless-rpc" {
      stateless_rpc = true
    }
    if arg == "--skip-connectivity-check" {
      skip_connectivity_check = true
    }
  }
  guard parse_pack_args(args) is Some((advertise, repo_path)) else {
    raise @bitcore.GitError::ProtocolError("missing repository path")
  }
  let root = if repo_path.has_suffix(".git") && !repo_path.has_suffix("/.git") {
    // Bare repository with .git suffix
    repo_path
  } else {
    normalize_repo_root(repo_path)
  }
  let fs = OsFs::new()
  let git_dir = if root.has_suffix(".git") && !root.has_suffix("/.git") {
    root
  } else {
    root + "/.git"
  }
  if is_sha256_repo(git_dir) {
    @stdio.stderr.write("bit: SHA256 repositories are not supported\n")
    @sys.exit(1)
  }
  // Send advertisement: always for advertise-only mode, and in
  // bidirectional mode (no --stateless-rpc)
  if advertise || not(stateless_rpc) {
    let haves = receive_collect_alternate_haves(fs, git_dir, root)
    let proto = @bitlib.get_protocol_version()
    let out = @bitlib.build_receive_pack_advertisement(
      fs,
      root,
      protocol_version=proto,
      extra_haves=haves,
    )
    @stdio.stdout.write(out)
  }
  // Process commands (unless advertise-only mode)
  if not(advertise) {
    let input = read_all_stdin()
    let req = @bitlib.parse_receive_pack_request(input)
    let result = @bitlib.apply_receive_pack(
      fs,
      fs,
      root,
      req,
      skip_connectivity_check~,
    )
    // Write connectivity check error to stderr
    match result.connectivity_error_oid {
      Some(oid) =>
        @stdio.stderr.write(
          str_to_bytes(
            "fatal: Failed to traverse parents of commit " + oid + "\n",
          ),
        )
      None => ()
    }
    let status = @bitlib.receive_build_status_response(result)
    @stdio.stdout.write(status)
  }
}

///|
/// Collect .have OIDs from alternate object stores.
async fn receive_collect_alternate_haves(
  fs : OsFs,
  git_dir : String,
  root : String,
) -> Array[@bitcore.ObjectId] {
  let haves : Array[@bitcore.ObjectId] = []
  let alternates_path = git_dir + "/objects/info/alternates"
  if not(fs.is_file(alternates_path)) {
    return haves
  }
  let data = fs.read_file(alternates_path) catch { _ => return haves }
  let text = @utf8.decode_lossy(data[:])
  let config_path = git_dir + "/config"
  let alt_ref_cmd = @bitlib.read_config_value(
    fs, config_path, "core", "alternateRefsCommand",
  )
  let alt_ref_prefixes = @bitlib.read_config_value(
    fs, config_path, "core", "alternateRefsPrefixes",
  )
  for line_view in text.split("\n") {
    let mut line = line_view.to_string()
    // Strip trailing CR and slashes
    while line.has_suffix("\r") || line.has_suffix("/") {
      line = String::unsafe_substring(line, start=0, end=line.length() - 1)
    }
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    // Resolve the alternate objects dir path
    let alt_objects_dir = if line.has_prefix("/") {
      line
    } else {
      git_dir + "/objects/" + line
    }
    // Strip /objects suffix to get the alternate git dir
    if not(alt_objects_dir.has_suffix("/objects")) {
      continue
    }
    let alt_git_dir = String::unsafe_substring(
      alt_objects_dir,
      start=0,
      end=alt_objects_dir.length() - 8,
    )
    match alt_ref_cmd {
      Some(cmd) => {
        // Execute alternateRefsCommand with alt_git_dir as argument
        let (code, stdout) = @process.collect_stdout(
          "sh",
          ["-c", cmd + " \"$@\"", "--", alt_git_dir],
          inherit_env=true,
          cwd=root,
        ) catch {
          _ => continue
        }
        if code != 0 {
          continue
        }
        let output_bytes = stdout.binary()
        let output = @utf8.decode_lossy(output_bytes[:])
        for oid_line in output.split("\n") {
          let oid_str = oid_line.to_string()
          if oid_str.length() >= 40 {
            let hex = String::unsafe_substring(oid_str, start=0, end=40)
            let oid = @bitcore.ObjectId::from_hex(hex) catch { _ => continue }
            haves.push(oid)
          }
        }
      }
      None => {
        // Read refs from alternate and optionally filter by prefix
        let refs = @bitlib.show_ref(fs, alt_git_dir) catch { _ => continue }
        match alt_ref_prefixes {
          Some(prefixes) => {
            let prefix_list : Array[String] = []
            for p in prefixes.split(" ") {
              let ps = p.to_string()
              if ps.length() > 0 {
                prefix_list.push(ps)
              }
            }
            for item in refs {
              let (refname, oid) = item
              for prefix in prefix_list {
                if refname == prefix || refname.has_prefix(prefix + "/") {
                  haves.push(oid)
                  break
                }
              }
            }
          }
          None =>
            for item in refs {
              haves.push(item.1)
            }
        }
      }
    }
  }
  haves
}

///|
/// Parse filter specification from command line
fn parse_filter_spec(spec : String) -> @protocol.FilterSpec {
  if spec == "blob:none" {
    @protocol.FilterSpec::BlobNone
  } else if spec.has_prefix("blob:limit=") {
    let limit_str = String::unsafe_substring(spec, start=11, end=spec.length())
    let limit = @strconv.parse_int64(limit_str) catch { _ => 0L }
    @protocol.FilterSpec::BlobLimit(limit)
  } else if spec.has_prefix("tree:") {
    let depth_str = String::unsafe_substring(spec, start=5, end=spec.length())
    let depth = @strconv.parse_int(depth_str) catch { _ => 0 }
    @protocol.FilterSpec::TreeDepth(depth)
  } else {
    @protocol.FilterSpec::NoFilter
  }
}

///|
