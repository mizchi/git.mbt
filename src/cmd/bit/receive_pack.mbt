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
  } else if fs.is_file(root + "/HEAD") && not(fs.is_dir(root + "/.git")) {
    // Bare repository without .git suffix
    root
  } else {
    root + "/.git"
  }
  if is_sha256_repo(git_dir) {
    @stdio.stderr.write("bit: SHA256 repositories are not supported\n")
    @sys.exit(1)
  }
  // Read push-related config
  let config_path = git_dir + "/config"
  let advertise_push_options = match
    @bitlib.read_config_bool(fs, config_path, "receive", "advertisepushoptions") {
    Some(v) => v
    None => false
  }
  let cert_nonce_seed = @bitlib.read_config_value(
    fs, config_path, "receive", "certnonceseed",
  )
  let cert_nonce = match cert_nonce_seed {
    Some(seed) => receive_generate_nonce(seed)
    None => ""
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
      git_dir_override=git_dir,
      advertise_push_options~,
      cert_nonce~,
    )
    @stdio.stdout.write(out)
  }
  // Process commands (unless advertise-only mode)
  if not(advertise) {
    let input = read_all_stdin()
    let req = @bitlib.parse_receive_pack_request(input)
    // Determine client capabilities
    let has_report_status_v2 = receive_has_capability(
      req.capabilities,
      "report-status-v2",
    )
    // Read receive.procReceiveRefs config
    let proc_receive_refs_patterns = @bitlib.read_config_values(
      fs, config_path, "receive", "procreceiverefs",
    )
    // Split updates into regular and proc-receive sets
    let (regular_updates, proc_updates) = receive_split_updates_by_proc_receive(
      req.updates,
      proc_receive_refs_patterns,
    )
    // Run pre-receive hook
    let pre_receive_ok = receive_run_hook(
      fs,
      git_dir,
      root,
      "pre-receive",
      req.updates,
      req.push_options,
    )
    if not(pre_receive_ok) {
      // pre-receive rejected: report all refs as rejected
      let result : @bitlib.ReceivePackResult = {
        updated: [],
        rejected: req.updates.map(fn(u) {
          (u.refname, "pre-receive hook declined")
        }),
        unpack_error: None,
        connectivity_error_oid: None,
      }
      let status = receive_build_status_with_version(
        result,
        [],
        has_report_status_v2,
      )
      @stdio.stdout.write(status)
      return ()
    }
    // Run proc-receive hook for matching refs
    let proc_results : Array[@bitlib.ReceivePackProcResult] = if proc_updates.length() >
      0 {
      let hook_path = git_dir + "/hooks/proc-receive"
      if fs.is_file(hook_path) {
        receive_run_proc_receive_hook(
          fs,
          git_dir,
          root,
          proc_updates,
          req.push_options,
        )
      } else {
        // No proc-receive hook: reject all proc-receive refs
        proc_updates.map(fn(u) {
          (
            {
              refname: u.refname,
              original_refname: u.refname,
              old_id: u.old_id.to_hex(),
              new_id: u.new_id.to_hex(),
              status: "ng",
              message: "proc-receive hook not configured",
              fall_through: false,
            } : @bitlib.ReceivePackProcResult)
        })
      }
    } else {
      []
    }
    // Handle fall-through: move fall-through refs back to regular updates
    let remaining_proc : Array[@bitlib.ReceivePackProcResult] = []
    let all_regular_updates : Array[@bitlib.RefUpdate] = []
    for u in regular_updates {
      all_regular_updates.push(u)
    }
    for pr in proc_results {
      if pr.fall_through && pr.status == "ok" {
        for u in proc_updates {
          if u.refname == pr.original_refname {
            all_regular_updates.push(u)
            break
          }
        }
      } else {
        remaining_proc.push(pr)
      }
    }
    let proc_results = remaining_proc
    // Apply regular ref updates (including fall-through refs)
    let regular_req : @bitlib.ReceivePackRequest = {
      updates: all_regular_updates,
      capabilities: req.capabilities,
      pack: req.pack,
      push_options: req.push_options,
      cert_push_options: req.cert_push_options,
      has_push_cert: req.has_push_cert,
    }
    let result = @bitlib.apply_receive_pack(
      fs,
      fs,
      root,
      regular_req,
      skip_connectivity_check~,
      git_dir_override=git_dir,
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
    // Send status response BEFORE post-receive hook (matches git behavior)
    let status = receive_build_status_with_version(
      result,
      proc_results,
      has_report_status_v2,
      original_updates=req.updates,
    )
    @stdio.stdout.write(status)
    // Run post-receive hook (only for successful updates)
    // Use rewritten refname/OID from proc-receive for proc refs
    let all_updated : Array[@bitlib.RefUpdate] = []
    for upd in req.updates {
      if result.updated.contains(upd.refname) {
        // Regular update or fall-through: use original ref data
        all_updated.push(upd)
      } else {
        // Check proc-receive results for rewritten refs
        for pr in proc_results {
          if pr.original_refname == upd.refname && pr.status == "ok" {
            all_updated.push({
              old_id: @bitcore.ObjectId::from_hex(pr.old_id) catch {
                _ => upd.old_id
              },
              new_id: @bitcore.ObjectId::from_hex(pr.new_id) catch {
                _ => upd.new_id
              },
              refname: pr.refname,
            })
          }
        }
      }
    }
    if all_updated.length() > 0 {
      let _ = receive_run_hook(
        fs,
        git_dir,
        root,
        "post-receive",
        all_updated,
        req.push_options,
      )
    }
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
/// Generate a push certificate nonce from seed and current timestamp.
/// Format: <timestamp>-<sha1_hex(seed + ":" + timestamp)>
fn receive_generate_nonce(seed : String) -> String {
  let ts = get_current_timestamp()
  let ts_str = ts.to_string()
  let state = @bitcore.Sha1State::new()
  state.update_string(ts_str)
  state.update_string(":")
  state.update_string(seed)
  let oid = state.finish()
  let hex = oid.to_hex()
  ts_str + "-" + hex
}

///|
/// Check if a capability is present in the capabilities list.
fn receive_has_capability(capabilities : Array[String], cap : String) -> Bool {
  for c in capabilities {
    if c == cap {
      return true
    }
  }
  false
}

///|
/// Split ref updates into regular and proc-receive sets based on
/// receive.procReceiveRefs config patterns.
fn receive_split_updates_by_proc_receive(
  updates : Array[@bitlib.RefUpdate],
  patterns : Array[String],
) -> (Array[@bitlib.RefUpdate], Array[@bitlib.RefUpdate]) {
  if patterns.length() == 0 {
    return (updates, [])
  }
  let regular : Array[@bitlib.RefUpdate] = []
  let proc : Array[@bitlib.RefUpdate] = []
  for upd in updates {
    if receive_ref_matches_proc_patterns(upd.refname, patterns) {
      proc.push(upd)
    } else {
      regular.push(upd)
    }
  }
  (regular, proc)
}

///|
/// Check if a refname matches any of the proc-receive patterns.
/// Patterns support prefix match with : separator and ! negation.
fn receive_ref_matches_proc_patterns(
  refname : String,
  patterns : Array[String],
) -> Bool {
  for pattern in patterns {
    let (negated, pat) = if pattern.has_prefix("!") {
      (true, String::unsafe_substring(pattern, start=1, end=pattern.length()))
    } else {
      (false, pattern)
    }
    let (is_prefix, prefix) = if pat.has_prefix(":") {
      (true, String::unsafe_substring(pat, start=1, end=pat.length()))
    } else {
      (false, pat)
    }
    let matched = if is_prefix {
      refname.has_prefix(prefix)
    } else {
      refname == prefix
    }
    if matched {
      return not(negated)
    }
  }
  false
}

///|
/// Run a receive-pack hook (pre-receive or post-receive).
/// Returns true if hook succeeded or doesn't exist, false if it rejected.
async fn receive_run_hook(
  fs : OsFs,
  git_dir : String,
  root : String,
  hook_name : String,
  updates : Array[@bitlib.RefUpdate],
  push_options : Array[String],
) -> Bool {
  let hook_path = git_dir + "/hooks/" + hook_name
  if not(fs.is_file(hook_path)) {
    return true
  }
  // Build stdin data: "<old-oid> <new-oid> <refname>\n" for each update
  let stdin_buf = StringBuilder::new()
  for upd in updates {
    stdin_buf.write_string(upd.old_id.to_hex())
    stdin_buf.write_char(' ')
    stdin_buf.write_string(upd.new_id.to_hex())
    stdin_buf.write_char(' ')
    stdin_buf.write_string(upd.refname)
    stdin_buf.write_char('\n')
  }
  let stdin_data = stdin_buf.to_string()
  let (stdin_input, stdin_writer) = @process.write_to_process() catch {
    _ => return true
  }
  stdin_writer.write(stdin_data) catch {
    _ => ()
  }
  stdin_writer.close()
  let env : Map[String, String] = { "GIT_DIR": git_dir }
  if push_options.length() > 0 {
    env["GIT_PUSH_OPTION_COUNT"] = push_options.length().to_string()
    for i, opt in push_options {
      env["GIT_PUSH_OPTION_\{i}"] = opt
    }
  }
  let code = @process.run(
    hook_path,
    [],
    extra_env=env,
    inherit_env=true,
    stdin=stdin_input,
    cwd=root,
  ) catch {
    _ => return true
  }
  code == 0
}

///|
/// Run the proc-receive hook and parse its output.
async fn receive_run_proc_receive_hook(
  fs : OsFs,
  git_dir : String,
  root : String,
  updates : Array[@bitlib.RefUpdate],
  push_options : Array[String],
) -> Array[@bitlib.ReceivePackProcResult] {
  let hook_path = git_dir + "/hooks/proc-receive"
  if not(fs.is_file(hook_path)) {
    return updates.map(fn(u) {
      (
        {
          refname: u.refname,
          original_refname: u.refname,
          old_id: u.old_id.to_hex(),
          new_id: u.new_id.to_hex(),
          status: "ng",
          message: "proc-receive hook not found",
          fall_through: false,
        } : @bitlib.ReceivePackProcResult)
    })
  }
  // Build proc-receive protocol input:
  // 1. version negotiation: "version=1\n" + flush
  // 2. ref commands: "<old> <new> <refname>\n" per ref + flush
  let input_buf : Array[Byte] = []
  let version_pkt = @protocol.pktline_encode("version=1\n")
  for b in version_pkt {
    input_buf.push(b)
  }
  let flush = @protocol.pktline_flush()
  for b in flush {
    input_buf.push(b)
  }
  for upd in updates {
    let line = upd.old_id.to_hex() +
      " " +
      upd.new_id.to_hex() +
      " " +
      upd.refname +
      "\n"
    let pkt = @protocol.pktline_encode(line)
    for b in pkt {
      input_buf.push(b)
    }
  }
  for b in flush {
    input_buf.push(b)
  }
  let input_bytes = Bytes::from_array(
    FixedArray::makei(input_buf.length(), fn(i) { input_buf[i] }),
  )
  let (stdin_input, stdin_writer) = @process.write_to_process() catch {
    _ =>
      return updates.map(fn(u) {
        (
          {
            refname: u.refname,
            original_refname: u.refname,
            old_id: u.old_id.to_hex(),
            new_id: u.new_id.to_hex(),
            status: "ng",
            message: "pipe creation failed",
            fall_through: false,
          } : @bitlib.ReceivePackProcResult)
      })
  }
  stdin_writer.write(input_bytes) catch {
    _ => ()
  }
  stdin_writer.close()
  let env : Map[String, String] = { "GIT_DIR": git_dir }
  if push_options.length() > 0 {
    env["GIT_PUSH_OPTION_COUNT"] = push_options.length().to_string()
    for i, opt in push_options {
      env["GIT_PUSH_OPTION_\{i}"] = opt
    }
  }
  let (code, stdout_data) = @process.collect_stdout(
    hook_path,
    [],
    extra_env=env,
    inherit_env=true,
    stdin=stdin_input,
    stderr=@stdio.stderr,
    cwd=root,
  ) catch {
    _ =>
      return updates.map(fn(u) {
        (
          {
            refname: u.refname,
            original_refname: u.refname,
            old_id: u.old_id.to_hex(),
            new_id: u.new_id.to_hex(),
            status: "ng",
            message: "hook execution failed",
            fall_through: false,
          } : @bitlib.ReceivePackProcResult)
      })
  }
  if code != 0 {
    return updates.map(fn(u) {
      (
        {
          refname: u.refname,
          original_refname: u.refname,
          old_id: u.old_id.to_hex(),
          new_id: u.new_id.to_hex(),
          status: "ng",
          message: "hook exited with non-zero status",
          fall_through: false,
        } : @bitlib.ReceivePackProcResult)
    })
  }
  let output_bytes = stdout_data.binary()
  receive_parse_proc_receive_output(output_bytes, updates)
}

///|
/// Parse proc-receive hook output (packet-line protocol).
fn receive_parse_proc_receive_output(
  data : Bytes,
  updates : Array[@bitlib.RefUpdate],
) -> Array[@bitlib.ReceivePackProcResult] {
  let results : Array[@bitlib.ReceivePackProcResult] = []
  if data.length() == 0 {
    return updates.map(fn(u) {
      (
        {
          refname: u.refname,
          original_refname: u.refname,
          old_id: u.old_id.to_hex(),
          new_id: u.new_id.to_hex(),
          status: "ng",
          message: "empty hook output",
          fall_through: false,
        } : @bitlib.ReceivePackProcResult)
    })
  }
  let lines = @protocol.pktline_decode(data) catch {
    _ =>
      return updates.map(fn(u) {
        (
          {
            refname: u.refname,
            original_refname: u.refname,
            old_id: u.old_id.to_hex(),
            new_id: u.new_id.to_hex(),
            status: "ng",
            message: "failed to parse hook output",
            fall_through: false,
          } : @bitlib.ReceivePackProcResult)
      })
  }
  let mut skip_version = true
  let mut current_ref : String = ""
  let mut current_original_ref : String = ""
  let mut current_status : String = ""
  let mut current_msg : String = ""
  let mut current_old : String = ""
  let mut current_new : String = ""
  let mut current_fall_through : Bool = false
  for item in lines {
    let (line_bytes, is_flush) = item
    if is_flush {
      if skip_version {
        skip_version = false
        continue
      }
      if current_ref.length() > 0 {
        results.push({
          refname: current_ref,
          original_refname: current_original_ref,
          old_id: current_old,
          new_id: current_new,
          status: current_status,
          message: current_msg,
          fall_through: current_fall_through,
        })
        current_ref = ""
      }
      continue
    }
    if line_bytes.length() == 0 {
      continue
    }
    let line = receive_proc_bytes_to_string(line_bytes)
    let line = if line.has_suffix("\n") {
      String::unsafe_substring(line, start=0, end=line.length() - 1)
    } else {
      line
    }
    if skip_version {
      continue
    }
    // Handle option directives
    if line.has_prefix("option ") {
      if current_ref.length() > 0 {
        let opt_content = String::unsafe_substring(
          line,
          start=7,
          end=line.length(),
        )
        if opt_content.has_prefix("refname ") {
          current_ref = String::unsafe_substring(
            opt_content,
            start=8,
            end=opt_content.length(),
          )
        } else if opt_content.has_prefix("old-oid ") {
          current_old = String::unsafe_substring(
            opt_content,
            start=8,
            end=opt_content.length(),
          )
        } else if opt_content.has_prefix("new-oid ") {
          current_new = String::unsafe_substring(
            opt_content,
            start=8,
            end=opt_content.length(),
          )
        } else if opt_content == "fall-through" {
          current_fall_through = true
        }
        // option forced-update is silently ignored (not needed for status)
      }
      continue
    }
    // Commit previous result
    if current_ref.length() > 0 {
      results.push({
        refname: current_ref,
        original_refname: current_original_ref,
        old_id: current_old,
        new_id: current_new,
        status: current_status,
        message: current_msg,
        fall_through: current_fall_through,
      })
      current_ref = ""
      current_original_ref = ""
      current_old = ""
      current_new = ""
      current_msg = ""
      current_fall_through = false
    }
    if line.has_prefix("ok ") {
      let refname = String::unsafe_substring(line, start=3, end=line.length())
      current_ref = refname
      current_original_ref = refname
      current_status = "ok"
      current_msg = ""
      for u in updates {
        if u.refname == refname {
          current_old = u.old_id.to_hex()
          current_new = u.new_id.to_hex()
          break
        }
      }
    } else if line.has_prefix("ng ") {
      let rest = String::unsafe_substring(line, start=3, end=line.length())
      match rest.find(" ") {
        Some(idx) => {
          current_ref = String::unsafe_substring(rest, start=0, end=idx)
          current_msg = String::unsafe_substring(
            rest,
            start=idx + 1,
            end=rest.length(),
          )
        }
        None => {
          current_ref = rest
          current_msg = "failed"
        }
      }
      current_original_ref = current_ref
      current_status = "ng"
      for u in updates {
        if u.refname == current_ref {
          current_old = u.old_id.to_hex()
          current_new = u.new_id.to_hex()
          break
        }
      }
    }
  }
  if current_ref.length() > 0 {
    results.push({
      refname: current_ref,
      original_refname: current_original_ref,
      old_id: current_old,
      new_id: current_new,
      status: current_status,
      message: current_msg,
      fall_through: current_fall_through,
    })
  }
  results
}

///|
fn receive_proc_bytes_to_string(data : Bytes) -> String {
  let buf = StringBuilder::new()
  for b in data {
    buf.write_char(b.to_int().unsafe_to_char())
  }
  buf.to_string()
}

///|
/// Build status response considering v1/v2 format and proc-receive results.
fn receive_build_status_with_version(
  result : @bitlib.ReceivePackResult,
  proc_results : Array[@bitlib.ReceivePackProcResult],
  _use_v2 : Bool,
  original_updates? : Array[@bitlib.RefUpdate] = [],
) -> Bytes {
  @bitlib.receive_build_status_response_with_proc(
    result,
    proc_results,
    original_updates~,
  )
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
