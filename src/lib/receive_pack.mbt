///| Receive-pack (server-side) implementation

///|
pub(all) struct RefUpdate {
  old_id : @bit.ObjectId
  new_id : @bit.ObjectId
  refname : String
}

///|
pub(all) struct ReceivePackRequest {
  updates : Array[RefUpdate]
  capabilities : Array[String]
  pack : Bytes
  push_options : Array[String]
  cert_push_options : Array[String]
  has_push_cert : Bool
}

///|
pub(all) struct ReceivePackResult {
  updated : Array[String]
  rejected : Array[(String, String)]
  unpack_error : String?
  connectivity_error_oid : String?
}

///|
/// Result from a proc-receive hook for a single ref.
pub(all) struct ReceivePackProcResult {
  refname : String
  old_id : String
  new_id : String
  status : String
  message : String
}

///|
/// Build receive-pack advertisement (info/refs payload).
pub fn build_receive_pack_advertisement(
  fs : &@bit.RepoFileSystem,
  root : String,
  agent? : String = "git/moonbit",
  protocol_version? : Int = 0,
  extra_haves? : Array[@bit.ObjectId] = [],
  git_dir_override? : String = "",
  advertise_push_options? : Bool = false,
  cert_nonce? : String = "",
) -> Bytes raise @bit.GitError {
  let git_dir = if git_dir_override.length() > 0 {
    git_dir_override
  } else {
    join_path(root, ".git")
  }
  let refs = show_ref(fs, git_dir)
  refs.sort_by((a, b) => String::compare(a.0, b.0))
  let caps = receive_default_caps(agent, advertise_push_options~, cert_nonce~)
  let out : Array[Byte] = []
  // Protocol v1: output version line before refs
  // (receive-pack has no v2, so v2 falls back to v0)
  if protocol_version == 1 {
    receive_push_bytes(out, @protocol.pktline_encode("version 1\n"))
  }
  if refs.length() == 0 {
    let zero = @bit.ObjectId::zero().to_hex()
    let line = "\{zero} capabilities^{}\u0000\{caps}\n"
    receive_push_bytes(out, @protocol.pktline_encode(line))
  } else {
    let (first_name, first_id) = refs[0]
    let first_line = "\{first_id.to_hex()} \{first_name}\u0000\{caps}\n"
    receive_push_bytes(out, @protocol.pktline_encode(first_line))
    for i in 1..<refs.length() {
      let (name, id) = refs[i]
      let line = "\{id.to_hex()} \{name}\n"
      receive_push_bytes(out, @protocol.pktline_encode(line))
    }
  }
  // Emit .have lines for alternate object stores
  for oid in extra_haves {
    let line = "\{oid.to_hex()} .have\n"
    receive_push_bytes(out, @protocol.pktline_encode(line))
  }
  receive_push_bytes(out, @protocol.pktline_flush())
  Bytes::from_array(FixedArray::makei(out.length(), i => out[i]))
}

///|
fn normalize_receive_refname(refname : String) -> String raise @bit.GitError {
  let normalized = normalize_repo_path(refname) catch {
    _ =>
      raise @bit.GitError::ProtocolError("Invalid receive-pack ref: " + refname)
  }
  if not(normalized.has_prefix("refs/")) {
    raise @bit.GitError::ProtocolError("Invalid receive-pack ref: " + refname)
  }
  normalized
}

///|
pub fn parse_receive_pack_request(
  data : Bytes,
) -> ReceivePackRequest raise @bit.GitError {
  let updates : Array[RefUpdate] = []
  let capabilities : Array[String] = []
  let cert_push_options : Array[String] = []
  let mut has_push_cert = false
  let mut i = 0
  let mut first = true
  let mut in_cert = false
  let cert_lines : Array[String] = []
  while i + 4 <= data.length() {
    let len = receive_parse_pkt_len(data, i)
    if len == 0 {
      i += 4
      break
    }
    if len < 4 || i + len > data.length() {
      raise @bit.GitError::ProtocolError("Invalid pkt-line length")
    }
    let line = receive_bytes_to_string_range(data, i + 4, i + len)
    let mut line = receive_trim_line(line)
    if in_cert {
      if line == "push-cert-end" {
        in_cert = false
        // Parse certificate content for ref updates and push-options
        receive_parse_cert_content(cert_lines, updates, cert_push_options)
      } else {
        cert_lines.push(line)
      }
      i += len
      continue
    }
    // Check for push-cert start
    let is_push_cert = line == "push-cert" || line.has_prefix("push-cert\u0000")
    if is_push_cert {
      has_push_cert = true
      in_cert = true
      // Extract capabilities from push-cert line (after NUL)
      if first {
        first = false
        match line.find("\u0000") {
          None => ()
          Some(idx) => {
            let caps_str = String::unsafe_substring(
              line,
              start=idx + 1,
              end=line.length(),
            )
            let caps = receive_split_by_space(caps_str)
            for c in caps {
              if c.length() > 0 {
                capabilities.push(c)
              }
            }
          }
        }
      }
      i += len
      continue
    }
    // Normal ref update command
    if first {
      first = false
      match line.find("\u0000") {
        None => ()
        Some(idx) => {
          let caps_str = String::unsafe_substring(
            line,
            start=idx + 1,
            end=line.length(),
          )
          line = String::unsafe_substring(line, start=0, end=idx)
          let caps = receive_split_by_space(caps_str)
          for c in caps {
            if c.length() > 0 {
              capabilities.push(c)
            }
          }
        }
      }
    }
    let parts = receive_split_by_space(line)
    if parts.length() < 3 {
      raise @bit.GitError::ProtocolError("Invalid receive-pack command")
    }
    let old_id = @bit.ObjectId::from_hex(parts[0])
    let new_id = @bit.ObjectId::from_hex(parts[1])
    let refname = normalize_receive_refname(parts[2])
    updates.push({ old_id, new_id, refname })
    i += len
  }
  // Phase 2: Read push-options after flush (if push-options capability is negotiated)
  let push_options : Array[String] = []
  let mut has_push_options_cap = false
  for cap in capabilities {
    if cap == "push-options" {
      has_push_options_cap = true
      break
    }
  }
  if has_push_options_cap && i + 4 <= data.length() {
    while i + 4 <= data.length() {
      let len = receive_parse_pkt_len(data, i)
      if len == 0 {
        i += 4
        break
      }
      if len < 4 || i + len > data.length() {
        break
      }
      let line = receive_bytes_to_string_range(data, i + 4, i + len)
      let line = receive_trim_line(line)
      push_options.push(line)
      i += len
    }
  }
  // Phase 3: Remaining data is pack
  let pack = receive_bytes_slice(data, i, data.length())
  {
    updates,
    capabilities,
    pack,
    push_options,
    cert_push_options,
    has_push_cert,
  }
}

///|
/// Parse push certificate content to extract ref updates and push-options.
fn receive_parse_cert_content(
  cert_lines : Array[String],
  updates : Array[RefUpdate],
  cert_push_options : Array[String],
) -> Unit {
  let mut in_body = false
  let mut in_sig = false
  for cert_line in cert_lines {
    if in_sig {
      continue
    }
    if not(in_body) {
      if cert_line.length() == 0 {
        in_body = true
        continue
      }
      if cert_line.has_prefix("push-option ") {
        let opt = String::unsafe_substring(
          cert_line,
          start=12,
          end=cert_line.length(),
        )
        cert_push_options.push(opt)
      }
      continue
    }
    // In body: ref updates and GPG signature
    if cert_line.has_prefix("-----BEGIN ") {
      in_sig = true
      continue
    }
    // Parse ref update line: <old> <new> <refname>
    let parts = receive_split_by_space(cert_line)
    if parts.length() >= 3 && parts[0].length() == 40 {
      let old_id = @bit.ObjectId::from_hex(parts[0]) catch { _ => continue }
      let new_id = @bit.ObjectId::from_hex(parts[1]) catch { _ => continue }
      let refname = normalize_receive_refname(parts[2]) catch { _ => continue }
      updates.push({ old_id, new_id, refname })
    }
  }
}

///|
pub fn apply_receive_pack(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  req : ReceivePackRequest,
  skip_connectivity_check? : Bool = false,
  git_dir_override? : String = "",
) -> ReceivePackResult raise @bit.GitError {
  let git_dir = if git_dir_override.length() > 0 {
    git_dir_override
  } else {
    join_path(root, ".git")
  }
  // Check push-option inconsistency (cert vs protocol push-options)
  if req.has_push_cert && req.push_options.length() > 0 {
    let mut inconsistent = false
    if req.cert_push_options.length() != req.push_options.length() {
      inconsistent = true
    } else {
      for i in 0..<req.cert_push_options.length() {
        if req.cert_push_options[i] != req.push_options[i] {
          inconsistent = true
          break
        }
      }
    }
    if inconsistent {
      let rejected : Array[(String, String)] = []
      for upd in req.updates {
        rejected.push((upd.refname, "inconsistent push options"))
      }
      return {
        updated: [],
        rejected,
        unpack_error: None,
        connectivity_error_oid: None,
      }
    }
  }
  let mut pack_objects : Array[@bit.PackObject] = []
  if req.pack.length() > 0 {
    pack_objects = @pack.parse_packfile(req.pack)
  }
  // Connectivity check BEFORE writing pack to disk
  if not(skip_connectivity_check) && pack_objects.length() > 0 {
    let fail_oid = receive_connectivity_check(rfs, git_dir, pack_objects)
    if fail_oid is Some(oid) {
      return {
        updated: [],
        rejected: [],
        unpack_error: Some("missing necessary objects"),
        connectivity_error_oid: Some(oid),
      }
    }
  }
  // Write pack after connectivity check passes
  if req.pack.length() > 0 && pack_objects.length() > 0 {
    @pack.write_packfile_with_index(fs, git_dir, req.pack, pack_objects)
  }
  let db = ObjectDb::load(rfs, git_dir)
  let updated : Array[String] = []
  let rejected : Array[(String, String)] = []
  for upd in req.updates {
    let refname = normalize_receive_refname(upd.refname) catch {
      _ => {
        rejected.push((upd.refname, "invalid refname"))
        continue
      }
    }
    let current = resolve_ref(rfs, git_dir, refname)
    let current_id = match current {
      None => @bit.ObjectId::zero()
      Some(id) => id
    }
    if current_id != upd.old_id {
      rejected.push((refname, "old id mismatch"))
      continue
    }
    if refname.has_prefix("refs/heads/") {
      if current_id != @bit.ObjectId::zero() &&
        upd.new_id != @bit.ObjectId::zero() {
        let ff = receive_is_ancestor_commit(db, rfs, current_id, upd.new_id) catch {
          _ => false
        }
        if not(ff) {
          rejected.push((refname, "non-fast-forward"))
          continue
        }
      }
    }
    if upd.new_id == @bit.ObjectId::zero() {
      if not(receive_delete_ref(fs, rfs, git_dir, refname)) {
        rejected.push((refname, "ref not found"))
        continue
      }
    } else {
      let ref_path = join_path(git_dir, refname)
      let dir = parent_dir(ref_path)
      fs.mkdir_p(dir)
      fs.write_string(ref_path, upd.new_id.to_hex() + "\n")
    }
    updated.push(refname)
  }
  { updated, rejected, unpack_error: None, connectivity_error_oid: None }
}

///|
pub fn receive_pack(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  data : Bytes,
  skip_connectivity_check? : Bool = false,
  git_dir_override? : String = "",
) -> Bytes raise @bit.GitError {
  let req = parse_receive_pack_request(data)
  let result = apply_receive_pack(
    fs,
    rfs,
    root,
    req,
    skip_connectivity_check~,
    git_dir_override~,
  )
  receive_build_status_response(result)
}

///|
pub fn receive_build_status_response(result : ReceivePackResult) -> Bytes {
  receive_build_status_response_with_proc(result, [])
}

///|
/// Build receive-pack status response including proc-receive results.
/// When use_v2 is true, uses report-status-v2 format.
pub fn receive_build_status_response_with_proc(
  result : ReceivePackResult,
  proc_results : Array[ReceivePackProcResult],
) -> Bytes {
  let out : Array[Byte] = []
  let unpack_line = match result.unpack_error {
    Some(msg) => "unpack \{msg}\n"
    None => "unpack ok\n"
  }
  receive_push_bytes(out, @protocol.pktline_encode(unpack_line))
  for refname in result.updated {
    receive_push_bytes(out, @protocol.pktline_encode("ok \{refname}\n"))
  }
  for item in result.rejected {
    let (refname, msg) = item
    receive_push_bytes(out, @protocol.pktline_encode("ng \{refname} \{msg}\n"))
  }
  // Include proc-receive results
  for pr in proc_results {
    if pr.status == "ok" {
      receive_push_bytes(out, @protocol.pktline_encode("ok \{pr.refname}\n"))
    } else {
      let msg = if pr.message.length() > 0 { pr.message } else { "failed" }
      receive_push_bytes(
        out,
        @protocol.pktline_encode("ng \{pr.refname} \{msg}\n"),
      )
    }
  }
  receive_push_bytes(out, @protocol.pktline_flush())
  Bytes::from_array(FixedArray::makei(out.length(), i => out[i]))
}

///|
fn receive_is_ancestor_commit(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  ancestor : @bit.ObjectId,
  commit_id : @bit.ObjectId,
) -> Bool raise @bit.GitError {
  if ancestor == commit_id {
    return true
  }
  let stack : Array[@bit.ObjectId] = [commit_id]
  let seen : Map[String, Bool] = {}
  while stack.length() > 0 {
    let id = match stack.pop() {
      None => raise @bit.GitError::InvalidObject("Empty stack")
      Some(v) => v
    }
    let hex = id.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    if id == ancestor {
      return true
    }
    let parents = receive_commit_parents(db, fs, id)
    for p in parents {
      stack.push(p)
    }
  }
  false
}

///|
fn receive_commit_parents(
  db : ObjectDb,
  fs : &@bit.RepoFileSystem,
  commit_id : @bit.ObjectId,
) -> Array[@bit.ObjectId] raise @bit.GitError {
  let obj = db.get(fs, commit_id)
  match obj {
    None => raise @bit.GitError::InvalidObject("Missing commit object")
    Some(o) => {
      if o.obj_type != @bit.ObjectType::Commit {
        raise @bit.GitError::InvalidObject("Object is not a commit")
      }
      let info = @bit.parse_commit(o.data)
      info.parents
    }
  }
}

///|
fn receive_delete_ref(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  refname : String,
) -> Bool raise @bit.GitError {
  let normalized = normalize_receive_refname(refname) catch {
    _ => return false
  }
  let ref_path = join_path(git_dir, normalized)
  if rfs.is_file(ref_path) {
    fs.remove_file(ref_path)
    return true
  }
  let packed = join_path(git_dir, "packed-refs")
  if not(rfs.is_file(packed)) {
    return false
  }
  let data = rfs.read_file(packed)
  let text = @utf8.decode_lossy(data[:])
  let out : Array[String] = []
  let mut removed = false
  let mut skip_peeled = false
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
      continue
    }
    if skip_peeled {
      if line.has_prefix("^") {
        skip_peeled = false
        continue
      }
      skip_peeled = false
    }
    if line.has_prefix("#") || line.has_prefix("^") {
      out.push(line)
      continue
    }
    match line.find(" ") {
      None => out.push(line)
      Some(idx) => {
        let name = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if name == normalized {
          removed = true
          skip_peeled = true
        } else {
          out.push(line)
        }
      }
    }
  }
  if removed {
    let buf = StringBuilder::new()
    for l in out {
      buf.write_string(l)
      buf.write_char('\n')
    }
    fs.write_string(packed, buf.to_string())
  }
  removed
}

///|
fn receive_parse_pkt_len(data : Bytes, start : Int) -> Int raise @bit.GitError {
  if start + 4 > data.length() {
    raise @bit.GitError::ProtocolError("Invalid pkt-line length")
  }
  let mut v = 0
  for i in 0..<4 {
    let c = data[start + i].to_int().unsafe_to_char()
    let digit = @bithash.hex_char_to_int(c) catch {
      _ => raise @bit.GitError::ProtocolError("Invalid pkt-line length")
    }
    v = v * 16 + digit
  }
  v
}

///|
fn receive_bytes_to_string_range(
  data : Bytes,
  start : Int,
  end : Int,
) -> String {
  let buf = StringBuilder::new()
  let mut i = start
  while i < end {
    buf.write_char(data[i].to_int().unsafe_to_char())
    i += 1
  }
  buf.to_string()
}

///|
fn receive_bytes_slice(data : Bytes, start : Int, end : Int) -> Bytes {
  let len = end - start
  if len <= 0 {
    return Bytes::from_array([])
  }
  let fixed = FixedArray::makei(len, i => data[start + i])
  Bytes::from_array(fixed)
}

///|
fn receive_trim_line(line : String) -> String {
  if line.has_suffix("\n") {
    String::unsafe_substring(line, start=0, end=line.length() - 1)
  } else {
    line
  }
}

///|
fn receive_split_by_space(s : String) -> Array[String] {
  let out : Array[String] = []
  let mut buf : Array[Char] = []
  for c in s {
    if c == ' ' {
      out.push(receive_chars_to_string(buf))
      buf = []
    } else {
      buf.push(c)
    }
  }
  out.push(receive_chars_to_string(buf))
  out
}

///|
fn receive_chars_to_string(chars : Array[Char]) -> String {
  let buf = StringBuilder::new()
  for c in chars {
    buf.write_char(c)
  }
  buf.to_string()
}

///|
fn receive_push_bytes(out : Array[Byte], data : Bytes) -> Unit {
  for b in data {
    out.push(b)
  }
}

///|
fn receive_default_caps(
  agent : String,
  advertise_push_options? : Bool = false,
  cert_nonce? : String = "",
) -> String {
  let caps : Array[String] = [
    "report-status",
    "report-status-v2",
    "delete-refs",
    "side-band-64k",
    "ofs-delta",
    "object-format=sha1",
    "agent=\{agent}",
  ]
  if advertise_push_options {
    caps.push("push-options")
  }
  if cert_nonce.length() > 0 {
    caps.push("push-cert=\{cert_nonce}")
  }
  caps.join(" ")
}

///|
/// Check connectivity of pack objects against existing repository.
/// Returns Some(commit_hex) on failure, None on success.
fn receive_connectivity_check(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  pack_objects : Array[@bit.PackObject],
) -> String? raise @bit.GitError {
  let pack_ids : Map[String, Bool] = {}
  for obj in pack_objects {
    pack_ids[obj.id.to_hex()] = true
  }
  // Load existing repo object database
  let db = if rfs.is_dir(git_dir) {
    Some(ObjectDb::load(rfs, git_dir))
  } else {
    None
  }
  let repo_cache : Map[String, Bool] = {}
  for obj in pack_objects {
    if obj.obj_type == @bit.ObjectType::Commit {
      let info = @bit.parse_commit(obj.data)
      // Check parents exist
      for parent in info.parents {
        let p_hex = parent.to_hex()
        if not(pack_ids.contains(p_hex)) {
          if not(receive_object_exists(rfs, db, repo_cache, parent)) {
            return Some(obj.id.to_hex())
          }
        }
      }
      // Check tree exists
      let t_hex = info.tree.to_hex()
      if not(pack_ids.contains(t_hex)) {
        if not(receive_object_exists(rfs, db, repo_cache, info.tree)) {
          return Some(obj.id.to_hex())
        }
      }
    }
  }
  None
}

///|
fn receive_object_exists(
  rfs : &@bit.RepoFileSystem,
  db : ObjectDb?,
  cache : Map[String, Bool],
  id : @bit.ObjectId,
) -> Bool raise @bit.GitError {
  let hex = id.to_hex()
  if cache.contains(hex) {
    return cache[hex]
  }
  let exists = match db {
    None => false
    Some(objdb) =>
      match objdb.get(rfs, id) {
        Some(_) => true
        None => false
      }
  }
  cache[hex] = exists
  exists
}
