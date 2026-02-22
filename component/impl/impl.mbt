///| WASM Component git operations implementation

///|
fn make_fs() -> WasmFs {
  WasmFs::new()
}

///|
fn[T] wrap_error(f : () -> T raise @bit.GitError) -> Result[T, String] {
  Ok(f()) catch {
    @bit.GitError::IoError(e) => Err(e)
    @bit.GitError::InvalidObject(e) => Err(e)
    @bit.GitError::HashMismatch(a, b) => Err("hash mismatch: \{a} vs \{b}")
    @bit.GitError::PackfileError(e) => Err("packfile error: \{e}")
    @bit.GitError::ProtocolError(e) => Err("protocol error: \{e}")
  }
}

///|
fn join_path(base : String, name : String) -> String {
  if base.length() == 0 {
    name
  } else if base == "/" {
    "/" + name
  } else {
    base + "/" + name
  }
}

///|
fn resolve_git_dir(fs : WasmFs, root : String) -> String {
  let git_path = join_path(root, ".git")
  if fs.is_dir(git_path) {
    git_path
  } else {
    git_path
  }
}

///|
fn is_tree_mode(mode : String) -> Bool {
  mode == "40000" || mode == "040000"
}

///|
fn parse_octal_mode(s : String) -> Int {
  let mut result = 0
  for c in s {
    if c < '0' || c > '7' {
      continue
    }
    result = result * 8 + (c.to_int() - '0'.to_int())
  }
  result
}

///|
fn collect_staged_changes_db(
  db : @bitlib.ObjectDb,
  fs : WasmFs,
  tree_id : @bit.ObjectId,
  prefix : String,
  index_map : Map[String, @bitlib.IndexEntry],
  staged_modified : Array[String],
  staged_deleted : Array[String],
) -> Unit raise @bit.GitError {
  let tree_obj = db.get(fs, tree_id)
  match tree_obj {
    None => raise @bit.GitError::InvalidObject("Missing tree object")
    Some(obj) => {
      if obj.obj_type != @bit.ObjectType::Tree {
        raise @bit.GitError::InvalidObject("Object is not a tree")
      }
      let entries = @bit.parse_tree(obj.data)
      for entry in entries {
        let path = if prefix.length() == 0 {
          entry.name
        } else {
          prefix + "/" + entry.name
        }
        if is_tree_mode(entry.mode) {
          collect_staged_changes_db(
            db,
            fs,
            entry.id,
            path,
            index_map,
            staged_modified,
            staged_deleted,
          )
        } else {
          let mode = parse_octal_mode(entry.mode)
          match index_map.get(path) {
            Some(index_entry) => {
              if index_entry.id != entry.id || index_entry.mode != mode {
                staged_modified.push(path)
              }
              index_map.remove(path)
            }
            None => staged_deleted.push(path)
          }
        }
      }
    }
  }
}

///|
fn collect_staged_changes_from_head(
  fs : WasmFs,
  git_dir : String,
  index_map : Map[String, @bitlib.IndexEntry],
  staged_modified : Array[String],
  staged_deleted : Array[String],
) -> Unit raise @bit.GitError {
  match @bitlib.resolve_head_commit(fs, git_dir) {
    None => ()
    Some(commit_id) => {
      let db = @bitlib.ObjectDb::load_lazy(fs, git_dir)
      match db.get(fs, commit_id) {
        None => ()
        Some(obj) => {
          if obj.obj_type != @bit.ObjectType::Commit {
            raise @bit.GitError::InvalidObject("Object is not a commit")
          }
          let info = @bit.parse_commit(obj.data)
          collect_staged_changes_db(
            db,
            fs,
            info.tree,
            "",
            index_map,
            staged_modified,
            staged_deleted,
          )
        }
      }
    }
  }
}

///|
fn porcelain_lines_from_status(s : StatusResult) -> Array[String] {
  let lines : Array[String] = []
  for p in s.staged_added {
    lines.push("A  " + p)
  }
  for p in s.staged_modified {
    lines.push("M  " + p)
  }
  for p in s.staged_deleted {
    lines.push("D  " + p)
  }
  for p in s.unstaged_modified {
    lines.push(" M " + p)
  }
  for p in s.unstaged_deleted {
    lines.push(" D " + p)
  }
  for p in s.untracked {
    lines.push("?? " + p)
  }
  lines
}

// === git-ops exports ===

///|
pub fn git_init(root : String, default_branch : String) -> Result[Unit, String] {
  let fs = make_fs()
  wrap_error(() => @bitlib.init_repo(fs, root, default_branch~))
}

///|
pub fn add(root : String, paths : Array[String]) -> Result[Unit, String] {
  let fs = make_fs()
  wrap_error(() => @bitlib.add_paths(fs, fs, root, paths))
}

///|
pub fn status(root : String) -> Result[StatusResult, String] {
  let fs = make_fs()
  wrap_error(() => {
    let git_dir = resolve_git_dir(fs, root)
    let entries = @bitlib.read_index_entries(fs, git_dir)
    let index_map : Map[String, @bitlib.IndexEntry] = {}
    for entry in entries {
      index_map[entry.path] = entry
    }
    let files = @ignore.list_working_files(fs, root)
    files.sort()
    let visited : Map[String, Bool] = {}
    let untracked : Array[String] = []
    let unstaged_modified : Array[String] = []
    for rel_path in files {
      visited[rel_path] = true
      match index_map.get(rel_path) {
        Some(index_entry) => {
          let abs_path = join_path(root, rel_path)
          let content = (fs as &@bit.RepoFileSystem).read_file(abs_path) catch {
            _ => continue
          }
          let worktree_id = @bit.hash_blob(content)
          if worktree_id != index_entry.id {
            unstaged_modified.push(rel_path)
          }
        }
        None => untracked.push(rel_path)
      }
    }
    let unstaged_deleted : Array[String] = []
    for entry in entries {
      if visited.get(entry.path) is Some(_) {
        continue
      }
      let abs_path = join_path(root, entry.path)
      if not(fs.is_file(abs_path)) {
        unstaged_deleted.push(entry.path)
      }
    }
    let staged_index_map : Map[String, @bitlib.IndexEntry] = {}
    for entry in entries {
      staged_index_map[entry.path] = entry
    }
    let staged_modified : Array[String] = []
    let staged_deleted : Array[String] = []
    collect_staged_changes_from_head(
      fs, git_dir, staged_index_map, staged_modified, staged_deleted,
    )
    let staged_added : Array[String] = []
    for item in staged_index_map.to_array() {
      let (path, _) = item
      staged_added.push(path)
    }
    staged_added.sort()
    staged_modified.sort()
    staged_deleted.sort()
    unstaged_modified.sort()
    unstaged_deleted.sort()
    untracked.sort()
    StatusResult::{
      staged_added,
      staged_modified,
      staged_deleted,
      unstaged_modified,
      unstaged_deleted,
      untracked,
    }
  })
}

///|
pub fn status_porcelain(root : String) -> Result[Array[String], String] {
  match status(root) {
    Ok(s) => Ok(porcelain_lines_from_status(s))
    Err(e) => Err(e)
  }
}

///|
pub fn commit(
  root : String,
  message : String,
  author : String,
  timestamp : Int64,
) -> Result[String, String] {
  let fs = make_fs()
  wrap_error(() => {
    let id = @bitlib.commit(fs, fs, root, message, author, timestamp)
    id.to_hex()
  })
}

///|
pub fn log(root : String, max_count : Int) -> Result[Array[LogEntry], String] {
  let fs = make_fs()
  wrap_error(() => {
    let git_dir = resolve_git_dir(fs, root)
    let entries = @bitlib.log_head(fs, git_dir, max_count~)
    let result : Array[LogEntry] = []
    for e in entries {
      result.push(LogEntry::{
        id: e.id.to_hex(),
        author: e.author,
        message: e.message,
        timestamp: e.timestamp,
      })
    }
    result
  })
}

///|
pub fn checkout(root : String, target : String) -> Result[Unit, String] {
  let fs = make_fs()
  wrap_error(() => {
    let _ = @bitlib.checkout(fs, fs, root, target)
  })
}

///|
pub fn checkout_b(root : String, branch_name : String) -> Result[Unit, String] {
  let fs = make_fs()
  wrap_error(() => {
    @bitlib.create_branch(fs, fs, root, branch_name)
    let _ = @bitlib.checkout(fs, fs, root, branch_name)
  })
}

///|
pub fn branch_list(root : String) -> Result[Array[BranchInfo], String] {
  let fs = make_fs()
  wrap_error(() => {
    let git_dir = resolve_git_dir(fs, root)
    let (_, branches) = @bitlib.list_branches(fs, git_dir)
    let result : Array[BranchInfo] = []
    for b in branches {
      result.push(BranchInfo::{
        name: b.name,
        commit_id: b.id.to_hex(),
        is_current: b.current,
      })
    }
    result
  })
}

///|
pub fn branch_create(root : String, name : String) -> Result[Unit, String] {
  let fs = make_fs()
  wrap_error(() => @bitlib.create_branch(fs, fs, root, name))
}

///|
pub fn branch_delete(root : String, name : String) -> Result[Unit, String] {
  let fs = make_fs()
  wrap_error(() => @bitlib.delete_branch(fs, fs, root, name))
}

///|
pub fn rm(
  root : String,
  paths : Array[String],
  cached : Bool,
) -> Result[Unit, String] {
  let fs = make_fs()
  wrap_error(() => @bitlib.rm_paths(fs, fs, root, paths, cached~))
}

///|
pub fn mv(
  root : String,
  source : String,
  dest : String,
) -> Result[Unit, String] {
  let fs = make_fs()
  wrap_error(() => @bitlib.mv_path(fs, fs, root, source, dest))
}

// === git-network-ops exports ===

///|
fn discover_refs_sync(
  url : String,
  prefer_v2 : Bool,
  http : WasmHttpClient,
) -> (
  Array[(@bit.ObjectId, String)],
  Array[String],
  @protocol.ProtocolVersion,
  Map[String, String],
) raise @bit.GitError {
  let spec = @protocol.parse_remote(url)
  if spec.kind != @protocol.RemoteKind::Http {
    raise @bit.GitError::ProtocolError("HTTP transport required")
  }
  let base = match spec.base_url {
    Some(b) => b
    None => url
  }
  let info_url = "\{base}/info/refs?service=git-upload-pack"
  let headers : Map[String, String] = {
    "User-Agent": "git/moonbit",
    "Accept": "application/x-git-upload-pack-advertisement",
  }
  if prefer_v2 {
    headers["Git-Protocol"] = "version=2"
  }
  let (response, adv) = http.get(info_url, headers)
  if response.code != 200 {
    raise @bit.GitError::ProtocolError(
      "Failed to fetch info/refs: HTTP \{response.code}",
    )
  }
  let version = @protocol.detect_protocol_version(adv)
  if version == @protocol.ProtocolVersion::V2 {
    let caps = @protocol.parse_v2_advertised_caps(adv)
    let req = @protocol.build_ls_refs_request("git/moonbit", [
      "refs/heads/", "refs/tags/", "HEAD",
    ])
    let resp = upload_pack_request_sync(url, req, true, http)
    let parsed = @protocol.parse_ls_refs_response(resp)
    return (parsed.refs, caps, version, parsed.symrefs)
  }
  let refs = @protocol.parse_refs(adv)
  let caps = @protocol.extract_capabilities(adv)
  let symrefs = net_parse_symrefs_from_capabilities(caps)
  (refs, caps, @protocol.ProtocolVersion::V0, symrefs)
}

///|
fn upload_pack_request_sync(
  url : String,
  body : Bytes,
  prefer_v2 : Bool,
  http : WasmHttpClient,
) -> Bytes raise @bit.GitError {
  let spec = @protocol.parse_remote(url)
  if spec.kind != @protocol.RemoteKind::Http {
    raise @bit.GitError::ProtocolError("HTTP transport required")
  }
  let base = match spec.base_url {
    Some(b) => b
    None => url
  }
  let post_url = "\{base}/git-upload-pack"
  let headers : Map[String, String] = {
    "User-Agent": "git/moonbit",
    "Content-Type": "application/x-git-upload-pack-request",
    "Accept": "application/x-git-upload-pack-result",
  }
  if prefer_v2 {
    headers["Git-Protocol"] = "version=2"
  }
  let (response, data) = http.post(post_url, body, headers)
  if response.code != 200 {
    raise @bit.GitError::ProtocolError(
      "Failed to upload-pack: HTTP \{response.code}",
    )
  }
  data
}

///|
fn fetch_pack_sync(
  url : String,
  wants : Array[@bit.ObjectId],
  prefer_v2 : Bool,
  depth : Int,
  http : WasmHttpClient,
) -> Bytes raise @bit.GitError {
  let (refs, caps, version, _symrefs) = discover_refs_sync(
    url, prefer_v2, http,
  )
  let actual_wants = if wants.length() == 0 {
    let ids : Array[@bit.ObjectId] = []
    for item in refs {
      let (id, _) = item
      ids.push(id)
    }
    ids
  } else {
    wants
  }
  if version == @protocol.ProtocolVersion::V2 {
    let req = @protocol.build_fetch_request_v2(
      "git/moonbit", actual_wants, depth,
    )
    let resp = upload_pack_request_sync(url, req, true, http)
    return @protocol.extract_pack_from_v2_response(resp)
  }
  let req = @protocol.build_fetch_request_v0("git/moonbit", actual_wants, caps)
  let resp = upload_pack_request_sync(url, req, false, http)
  @protocol.extract_pack_from_v0_response(resp)
}

///|
fn net_parse_symrefs_from_capabilities(
  caps : Array[String],
) -> Map[String, String] {
  let symrefs : Map[String, String] = {}
  for cap in caps {
    if cap.has_prefix("symref=") {
      let raw = String::unsafe_substring(cap, start=7, end=cap.length())
      match raw.find(":") {
        None => ()
        Some(idx) => {
          let source = String::unsafe_substring(raw, start=0, end=idx)
          let target = String::unsafe_substring(
            raw, start=idx + 1, end=raw.length(),
          )
          symrefs[source] = target
        }
      }
      continue
    }
    if cap.has_prefix("symref-target:") {
      let target = String::unsafe_substring(cap, start=14, end=cap.length())
      symrefs["HEAD"] = target
      continue
    }
  }
  symrefs
}

///|
fn net_remote_refname(refname : String) -> String raise @bit.GitError {
  let normalized = @bitlib.normalize_repo_path(refname)
  if normalized == "HEAD" || normalized.has_prefix("refs/") {
    if normalized.has_prefix("refs/heads/") {
      let name = String::unsafe_substring(
        normalized, start=11, end=normalized.length(),
      )
      "refs/remotes/origin/" + name
    } else if normalized == "HEAD" {
      "refs/remotes/origin/HEAD"
    } else {
      "refs/remotes/origin/" + normalized
    }
  } else {
    raise @bit.GitError::InvalidObject("invalid refname: " + refname)
  }
}

///|
fn net_parent_dir(path : String) -> String {
  match path.rev_find("/") {
    None => "/"
    Some(0) => "/"
    Some(i) => String::unsafe_substring(path, start=0, end=i)
  }
}

///|
fn net_find_ref(
  refs : Array[(@bit.ObjectId, String)],
  name : String,
) -> @bit.ObjectId {
  for item in refs {
    let (id, refname) = item
    if refname == name {
      return id
    }
  }
  @bit.ObjectId::zero()
}

///|
pub fn clone(
  url : String,
  dest : String,
  branch : String,
  depth : Int,
) -> Result[Unit, String] {
  let fs = make_fs()
  let http = WasmHttpClient::new()
  wrap_error(fn() raise @bit.GitError {
    let prefer_v2 = true
    // 1. Init repo
    fs.mkdir_p(dest)
    @bitlib.init_repo(fs, dest)
    // 2. Write remote config
    let git_dir = join_path(dest, ".git")
    let config_path = join_path(git_dir, "config")
    let config_content = "[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n[remote \"origin\"]\n\turl = \{url}\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"
    fs.write_string(config_path, config_content)
    // 3. Discover refs
    let (refs, _caps, _version, symrefs) = discover_refs_sync(
      url, prefer_v2, http,
    )
    let default_ref = if branch.length() > 0 {
      // User specified branch
      let target_ref = "refs/heads/" + branch
      let mut found : (String, @bit.ObjectId)? = None
      for item in refs {
        let (id, refname) = item
        if refname == target_ref {
          found = Some((refname, id))
          break
        }
      }
      found
    } else {
      @protocol.select_default_ref(refs, symrefs)
    }
    match default_ref {
      None => raise @bit.GitError::ProtocolError("No default branch found")
      Some((refname, commit_id)) => {
        // 4. Fetch packfile
        let pack = fetch_pack_sync(url, [commit_id], prefer_v2, depth, http)
        let objects = @pack.parse_packfile(pack)
        @pack.write_packfile_with_index(fs, git_dir, pack, objects)
        // 5. Set HEAD
        let branch_name = if refname.has_prefix("refs/heads/") {
          String::unsafe_substring(refname, start=11, end=refname.length())
        } else {
          "main"
        }
        let head_path = join_path(git_dir, "HEAD")
        fs.write_string(head_path, "ref: refs/heads/\{branch_name}\n")
        // 6. Create local branch ref
        let branch_ref_path = join_path(git_dir, "refs/heads/" + branch_name)
        let branch_dir = net_parent_dir(branch_ref_path)
        fs.mkdir_p(branch_dir)
        fs.write_string(branch_ref_path, commit_id.to_hex() + "\n")
        // 7. Create remote tracking ref
        let remote_ref = net_remote_refname(refname)
        let remote_path = join_path(git_dir, remote_ref)
        let remote_dir = net_parent_dir(remote_path)
        fs.mkdir_p(remote_dir)
        fs.write_string(remote_path, commit_id.to_hex() + "\n")
        // 8. Checkout working tree
        @bitlib.fast_forward_to(fs, fs, dest, commit_id)
      }
    }
  })
}

///|
pub fn fetch(root : String, remote_url : String) -> Result[Unit, String] {
  let fs = make_fs()
  let http = WasmHttpClient::new()
  wrap_error(fn() raise @bit.GitError {
    let prefer_v2 = true
    let git_dir = resolve_git_dir(fs, root)
    // 1. Discover refs
    let (refs, _caps, _version, symrefs) = discover_refs_sync(
      remote_url, prefer_v2, http,
    )
    let default_ref = @protocol.select_default_ref(refs, symrefs)
    match default_ref {
      None => raise @bit.GitError::ProtocolError("No refs found on remote")
      Some((refname, commit_id)) => {
        // 2. Fetch packfile
        let pack = fetch_pack_sync(
          remote_url, [commit_id], prefer_v2, 0, http,
        )
        let objects = @pack.parse_packfile(pack)
        @pack.write_packfile_with_index(fs, git_dir, pack, objects)
        // 3. Update remote tracking ref
        let remote_ref = net_remote_refname(refname)
        let remote_path = join_path(git_dir, remote_ref)
        let dir = net_parent_dir(remote_path)
        fs.mkdir_p(dir)
        fs.write_string(remote_path, commit_id.to_hex() + "\n")
        // 4. Fast-forward checkout
        let head = @bitlib.resolve_head_commit(fs, git_dir)
        match head {
          None => @bitlib.fast_forward_to(fs, fs, root, commit_id)
          Some(_) => @bitlib.fast_forward_to(fs, fs, root, commit_id)
        }
      }
    }
  })
}

///|
pub fn push(
  root : String,
  remote_url : String,
  refspec : String,
) -> Result[String, String] {
  let fs = make_fs()
  let http = WasmHttpClient::new()
  wrap_error(fn() raise @bit.GitError {
    let git_dir = resolve_git_dir(fs, root)
    let head = @bitlib.resolve_head_commit(fs, git_dir)
    match head {
      None => raise @bit.GitError::InvalidObject("HEAD not found")
      Some(head_id) => {
        let db = @bitlib.ObjectDb::load_lazy(fs, git_dir)
        let objects = @bitlib.collect_reachable_objects(db, fs, head_id)
        let pack = @pack.create_packfile(objects)
        // Determine refname
        let refname = if refspec.length() > 0 { refspec } else { "refs/heads/main" }
        // Discover receive-pack refs
        let remote = @protocol.Remote::new(remote_url)
        let info_url = remote.info_refs_url()
        let headers : Map[String, String] = {
          "User-Agent": "git/moonbit",
          "Accept": "application/x-git-receive-pack-advertisement",
        }
        let (response, data) = http.get(info_url, headers)
        if response.code != 200 {
          raise @bit.GitError::ProtocolError(
            "Failed to discover refs: HTTP \{response.code}",
          )
        }
        let refs = @protocol.parse_refs(data)
        let old_id = net_find_ref(refs, refname)
        // Build and send push request
        let req = @protocol.PushRequest::new(old_id, head_id, refname, pack)
        let body = @protocol.build_receive_pack_body(req)
        let push_url = remote.receive_pack_url()
        let push_headers : Map[String, String] = {
          "User-Agent": "git/moonbit",
          "Content-Type": "application/x-git-receive-pack-request",
          "Accept": "application/x-git-receive-pack-result",
        }
        let (push_response, push_data) = http.post(
          push_url, body, push_headers,
        )
        if push_response.code != 200 {
          raise @bit.GitError::ProtocolError(
            "Failed to push: HTTP \{push_response.code}",
          )
        }
        match @protocol.parse_receive_pack_response(push_data) {
          Ok(msg) => msg
          Err(e) => raise e
        }
      }
    }
  })
}
