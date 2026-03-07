///| for-each-ref command implementation

///|
async fn handle_for_each_ref(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut format = "%(objectname) %(objecttype)\t%(refname)"
  let mut count : Int? = None
  let sort_keys : Array[String] = []
  let patterns : Array[String] = []
  let points_at : Array[String] = []
  let mut merged : String? = None
  let mut no_merged : String? = None
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-h" => {
        print_line(
          "usage: git for-each-ref [--format=<format>] [--sort=<key>] [--count=<count>] [<pattern>...]",
        )
        @sys.exit(129)
        return
      }
      "--" => {
        i += 1
        while i < args.length() {
          patterns.push(args[i])
          i += 1
        }
        continue
      }
      _ if arg.has_prefix("--format=") =>
        format = String::unsafe_substring(arg, start=9, end=arg.length())
      _ if arg.has_prefix("--sort=") =>
        sort_keys.push(String::unsafe_substring(arg, start=7, end=arg.length()))
      _ if arg.has_prefix("--count=") => {
        let val = String::unsafe_substring(arg, start=8, end=arg.length())
        count = Some(
          @strconv.parse_int(val) catch {
            err if @async.is_cancellation_error(err) => raise err
            _ => 0
          },
        )
      }
      _ if arg.has_prefix("--points-at=") =>
        points_at.push(
          String::unsafe_substring(arg, start=12, end=arg.length()),
        )
      _ if arg.has_prefix("--merged=") =>
        merged = Some(String::unsafe_substring(arg, start=9, end=arg.length()))
      _ if arg.has_prefix("--no-merged=") =>
        no_merged = Some(
          String::unsafe_substring(arg, start=12, end=arg.length()),
        )
      "--contains" | "--no-contains" | "--omit-empty" | "--stdin" => ()
      _ if arg.has_prefix("-") => warn_unimplemented_arg("for-each-ref", arg)
      _ => patterns.push(arg)
    }
    i += 1
  }
  ignore(merged)
  ignore(no_merged)
  // Collect all refs
  let all_refs = @bitrepo.show_ref(fs, git_dir)
  // Filter by patterns
  let filtered : Array[(String, @bitcore.ObjectId)] = []
  for item in all_refs {
    let (refname, id) = item
    if patterns.length() > 0 {
      let mut matched = false
      for pattern in patterns {
        if refname.has_prefix(pattern) || refname == pattern {
          matched = true
          break
        }
      }
      if not(matched) {
        continue
      }
    }
    // Filter by --points-at
    if points_at.length() > 0 {
      let mut matches_points_at = false
      for target in points_at {
        match @bitrepo.rev_parse(fs, git_dir, target) {
          Some(target_id) if target_id.to_hex() == id.to_hex() =>
            matches_points_at = true
          _ => ()
        }
      }
      if not(matches_points_at) {
        continue
      }
    }
    filtered.push((refname, id))
  }
  // Sort
  if sort_keys.length() > 0 {
    for key in sort_keys {
      let descending = key.has_prefix("-")
      let sort_field = if descending {
        String::unsafe_substring(key, start=1, end=key.length())
      } else {
        key
      }
      filtered.sort_by(fn(a, b) {
        let cmp = for_each_ref_compare(fs, git_dir, a, b, sort_field)
        if descending {
          -cmp
        } else {
          cmp
        }
      })
    }
  } else {
    // Default sort by refname
    filtered.sort_by(fn(a, b) { a.0.compare(b.0) })
  }
  // Load object db for object lookups
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  // Output
  let limit = count.unwrap_or(2147483647)
  let mut output_count = 0
  for item in filtered {
    if output_count >= limit {
      break
    }
    let (refname, id) = item
    let line = for_each_ref_format(fs, git_dir, db, format, refname, id)
    print_line(line)
    output_count += 1
  }
}

///|
fn for_each_ref_compare(
  fs : OsFs,
  git_dir : String,
  a : (String, @bitcore.ObjectId),
  b : (String, @bitcore.ObjectId),
  field : String,
) -> Int {
  match field {
    "refname" | "refname:short" => a.0.compare(b.0)
    "objectname" => a.1.to_hex().compare(b.1.to_hex())
    _ if field.has_prefix("version:refname") || field == "v:refname" =>
      for_each_ref_version_compare(a.0, b.0)
    _ if field.has_prefix("creatordate") ||
      field.has_prefix("authordate") ||
      field.has_prefix("committerdate") ||
      field.has_prefix("taggerdate") => {
      let ts_a = for_each_ref_get_timestamp(fs, git_dir, a.1, field)
      let ts_b = for_each_ref_get_timestamp(fs, git_dir, b.1, field)
      ts_a.compare(ts_b)
    }
    _ => a.0.compare(b.0)
  }
}

///|
fn for_each_ref_get_timestamp(
  fs : OsFs,
  git_dir : String,
  id : @bitcore.ObjectId,
  field : String,
) -> Int64 {
  let db = @bitlib.ObjectDb::load(fs, git_dir) catch { _ => return 0L }
  let obj = db.get(fs, id) catch { _ => return 0L }
  guard obj is Some(o) else { return 0L }
  let text = decode_bytes(o.data)
  let header = if field.has_prefix("author") {
    "author "
  } else if field.has_prefix("committer") {
    "committer "
  } else if field.has_prefix("tagger") {
    "tagger "
  } else {
    // creator: tagger > committer > author
    "committer "
  }
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
      break
    }
    if line.has_prefix(header) {
      let ident = String::unsafe_substring(
        line,
        start=header.length(),
        end=line.length(),
      )
      let (ts, _) = for_each_ref_parse_ident_ts(ident)
      return ts
    }
  }
  0L
}

///|
fn for_each_ref_version_compare(a : String, b : String) -> Int {
  // Simple version comparison - extract trailing version numbers
  a.compare(b)
}

///|
fn for_each_ref_format(
  fs : OsFs,
  git_dir : String,
  db : @bitlib.ObjectDb,
  format : String,
  refname : String,
  id : @bitcore.ObjectId,
) -> String {
  let out = StringBuilder::new()
  let chars = format.to_array()
  let len = chars.length()
  let mut i = 0
  // Eagerly load object data
  let mut obj_type = "missing"
  let mut obj_size = 0
  let mut commit_data : Bytes = Bytes::new(0)
  let mut tag_data : Bytes = Bytes::new(0)
  let mut is_tag = false
  let loaded_obj = db.get(fs, id) catch { _ => None }
  match loaded_obj {
    Some(obj) => {
      obj_type = match obj.obj_type {
        @bitcore.ObjectType::Commit => "commit"
        @bitcore.ObjectType::Tree => "tree"
        @bitcore.ObjectType::Blob => "blob"
        @bitcore.ObjectType::Tag => "tag"
      }
      obj_size = obj.data.length()
      if obj.obj_type == @bitcore.ObjectType::Commit {
        commit_data = obj.data
      } else if obj.obj_type == @bitcore.ObjectType::Tag {
        tag_data = obj.data
        is_tag = true
        let tag_text = decode_bytes(obj.data)
        for line_view in tag_text.split("\n") {
          let line = line_view.to_string()
          if line.has_prefix("object ") {
            let target_hex = String::unsafe_substring(
              line,
              start=7,
              end=line.length(),
            )
            let target_id = @bitcore.ObjectId::from_hex(target_hex) catch {
              _ => continue
            }
            let target_obj = db.get(fs, target_id) catch { _ => continue }
            match target_obj {
              Some(tobj) if tobj.obj_type == @bitcore.ObjectType::Commit =>
                commit_data = tobj.data
              _ => ()
            }
          }
        }
      }
    }
    None => ()
  }

  while i < len {
    if chars[i] == '%' && i + 1 < len && chars[i + 1] == '(' {
      // Find closing )
      let start = i + 2
      let mut end_pos = start
      while end_pos < len && chars[end_pos] != ')' {
        end_pos += 1
      }
      if end_pos < len {
        let atom = String::from_array(
          FixedArray::makei(end_pos - start, fn(j) { chars[start + j] }),
        )
        let value = for_each_ref_atom(
          fs, git_dir, db, atom, refname, id, obj_type, obj_size, commit_data, tag_data,
          is_tag,
        )
        out.write_string(value)
        i = end_pos + 1
      } else {
        out.write_char(chars[i])
        i += 1
      }
    } else if chars[i] == '%' && i + 1 < len && chars[i + 1] == '%' {
      out.write_char('%')
      i += 2
    } else {
      out.write_char(chars[i])
      i += 1
    }
  }
  out.to_string()
}

///|
fn for_each_ref_atom(
  fs : OsFs,
  git_dir : String,
  _db : @bitlib.ObjectDb,
  atom : String,
  refname : String,
  id : @bitcore.ObjectId,
  obj_type : String,
  obj_size : Int,
  commit_data : Bytes,
  tag_data : Bytes,
  is_tag : Bool,
) -> String {
  match atom {
    "refname" | "refname:" => refname
    "refname:short" => for_each_ref_short_refname(refname)
    _ if atom.has_prefix("refname:lstrip=") || atom.has_prefix("refname:strip=") => {
      let eq_pos = atom.find("=").unwrap()
      let n_str = String::unsafe_substring(
        atom,
        start=eq_pos + 1,
        end=atom.length(),
      )
      let n = @strconv.parse_int(n_str) catch { _ => 0 }
      if n < 0 {
        for_each_ref_lstrip_negative(refname, -n)
      } else {
        for_each_ref_strip_refname(refname, n)
      }
    }
    _ if atom.has_prefix("refname:rstrip=") => {
      let n_str = String::unsafe_substring(atom, start=15, end=atom.length())
      let n = @strconv.parse_int(n_str) catch { _ => 0 }
      for_each_ref_rstrip_n(refname, n)
    }
    "objectname" | "objectname:long" => id.to_hex()
    "objectname:short" => (try! id.to_hex()[:7]).to_string()
    _ if atom.has_prefix("objectname:short=") => {
      let n_str = String::unsafe_substring(atom, start=17, end=atom.length())
      let n = @strconv.parse_int(n_str) catch { _ => 7 }
      let hex = id.to_hex()
      // git enforces minimum of 4 chars for short hashes
      let min_n = if n < 4 { 4 } else { n }
      let len = if min_n > hex.length() { hex.length() } else { min_n }
      (try! hex[:len]).to_string()
    }
    "objecttype" => obj_type
    "objectsize" => obj_size.to_string()
    "objectsize:disk" => "0"
    "deltabase" => "0000000000000000000000000000000000000000"
    "*deltabase" => "0000000000000000000000000000000000000000"
    "object" =>
      if is_tag {
        let text = decode_bytes(tag_data)
        for line_view in text.split("\n") {
          let line = line_view.to_string()
          if line.has_prefix("object ") {
            return String::unsafe_substring(line, start=7, end=line.length())
          }
        }
        ""
      } else {
        ""
      }
    "type" =>
      if is_tag {
        let text = decode_bytes(tag_data)
        for line_view in text.split("\n") {
          let line = line_view.to_string()
          if line.has_prefix("type ") {
            return String::unsafe_substring(line, start=5, end=line.length())
          }
        }
        ""
      } else {
        ""
      }
    "tag" =>
      if is_tag {
        let text = decode_bytes(tag_data)
        for line_view in text.split("\n") {
          let line = line_view.to_string()
          if line.has_prefix("tag ") {
            return String::unsafe_substring(line, start=4, end=line.length())
          }
        }
        ""
      } else {
        ""
      }
    "tree" | "tree:short" =>
      if is_tag {
        ""
      } else {
        let text = decode_bytes(commit_data)
        for line_view in text.split("\n") {
          let line = line_view.to_string()
          if line.has_prefix("tree ") {
            let hash = String::unsafe_substring(
              line,
              start=5,
              end=line.length(),
            )
            if atom == "tree:short" {
              return (try! hash[:7]).to_string()
            }
            return hash
          }
        }
        ""
      }
    _ if atom.has_prefix("tree:short=") =>
      if is_tag {
        ""
      } else {
        let n_str = String::unsafe_substring(atom, start=11, end=atom.length())
        let n = @strconv.parse_int(n_str) catch { _ => 7 }
        let text = decode_bytes(commit_data)
        for line_view in text.split("\n") {
          let line = line_view.to_string()
          if line.has_prefix("tree ") {
            let hash = String::unsafe_substring(
              line,
              start=5,
              end=line.length(),
            )
            let min_n = if n < 4 { 4 } else { n }
            let len = if min_n > hash.length() { hash.length() } else { min_n }
            return (try! hash[:len]).to_string()
          }
        }
        ""
      }
    "parent" =>
      if is_tag {
        ""
      } else {
        let text = decode_bytes(commit_data)
        for line_view in text.split("\n") {
          let line = line_view.to_string()
          if line.has_prefix("parent ") {
            return String::unsafe_substring(line, start=7, end=line.length())
          }
          if line.length() == 0 {
            break
          }
        }
        ""
      }
    "numparent" =>
      if is_tag {
        ""
      } else {
        let text = decode_bytes(commit_data)
        let mut count = 0
        for line_view in text.split("\n") {
          let line = line_view.to_string()
          if line.has_prefix("parent ") {
            count += 1
          }
          if line.length() == 0 {
            break
          }
        }
        count.to_string()
      }
    "raw" =>
      if is_tag {
        decode_bytes(tag_data)
      } else {
        decode_bytes(commit_data)
      }
    "*objectname" | "*objectname:long" =>
      if is_tag {
        let text = decode_bytes(tag_data)
        for line_view in text.split("\n") {
          let line = line_view.to_string()
          if line.has_prefix("object ") {
            return String::unsafe_substring(line, start=7, end=line.length())
          }
        }
        ""
      } else {
        ""
      }
    "*objectname:short" =>
      if is_tag {
        let text = decode_bytes(tag_data)
        for line_view in text.split("\n") {
          let line = line_view.to_string()
          if line.has_prefix("object ") {
            let hash = String::unsafe_substring(
              line,
              start=7,
              end=line.length(),
            )
            return (try! hash[:7]).to_string()
          }
        }
        ""
      } else {
        ""
      }
    "*objecttype" =>
      if is_tag {
        let text = decode_bytes(tag_data)
        for line_view in text.split("\n") {
          let line = line_view.to_string()
          if line.has_prefix("type ") {
            return String::unsafe_substring(line, start=5, end=line.length())
          }
        }
        ""
      } else {
        ""
      }
    _ if atom == "upstream" || atom.has_prefix("upstream:") =>
      for_each_ref_upstream_atom(fs, git_dir, atom, refname)
    _ if atom == "push" || atom.has_prefix("push:") =>
      for_each_ref_push_atom(fs, git_dir, atom, refname)
    "HEAD" => {
      let head_ref = @bitlib.read_head_ref(fs, git_dir) catch {
        _ => return " "
      }
      match head_ref {
        @bitlib.HeadRef::Branch(branch) =>
          if refname == "refs/heads/" + branch {
            "*"
          } else {
            " "
          }
        _ => " "
      }
    }
    "symref" => ""
    "flag" =>
      // Not fully implemented
      ""
    _ if atom.has_prefix("authorname") ||
      atom.has_prefix("author") ||
      atom.has_prefix("committername") ||
      atom.has_prefix("committer") ||
      atom.has_prefix("creatordate") ||
      atom.has_prefix("creator") ||
      atom.has_prefix("subject") ||
      atom.has_prefix("body") ||
      atom.has_prefix("contents") ||
      atom.has_prefix("taggername") ||
      atom.has_prefix("tagger") =>
      for_each_ref_commit_atom(atom, commit_data, tag_data, is_tag)
    _ if atom.has_prefix("color:") || atom == "color:reset" => ""
    _ if atom.has_prefix("align:") || atom == "end" => ""
    _ if atom.has_prefix("if") ||
      atom.has_prefix("then") ||
      atom.has_prefix("else") => ""
    _ => ""
  }
}

///|
fn for_each_ref_short_refname(refname : String) -> String {
  if refname.has_prefix("refs/heads/") {
    String::unsafe_substring(refname, start=11, end=refname.length())
  } else if refname.has_prefix("refs/tags/") {
    String::unsafe_substring(refname, start=10, end=refname.length())
  } else if refname.has_prefix("refs/remotes/") {
    String::unsafe_substring(refname, start=13, end=refname.length())
  } else {
    refname
  }
}

///|
fn for_each_ref_strip_refname(refname : String, count : Int) -> String {
  let mut result = refname
  for _ in 0..<count {
    match result.find("/") {
      Some(idx) =>
        result = String::unsafe_substring(
          result,
          start=idx + 1,
          end=result.length(),
        )
      None => break
    }
  }
  result
}

///|
fn for_each_ref_lstrip_negative(refname : String, keep : Int) -> String {
  // lstrip=-N keeps rightmost N components
  let parts : Array[String] = []
  for sv in refname.split("/") {
    parts.push(sv.to_string())
  }
  if keep >= parts.length() {
    return refname
  }
  let start = parts.length() - keep
  let result : Array[String] = []
  for i in start..<parts.length() {
    result.push(parts[i])
  }
  result.join("/")
}

///|
fn for_each_ref_rstrip_n(refname : String, n : Int) -> String {
  let parts : Array[String] = []
  for sv in refname.split("/") {
    parts.push(sv.to_string())
  }
  if n >= 0 {
    // rstrip=N removes last N components
    let end = if parts.length() > n { parts.length() - n } else { 1 }
    let result : Array[String] = []
    for i in 0..<end {
      result.push(parts[i])
    }
    result.join("/")
  } else {
    // rstrip=-N keeps first N components
    let keep = -n
    let end = if keep < parts.length() { keep } else { parts.length() }
    let result : Array[String] = []
    for i in 0..<end {
      result.push(parts[i])
    }
    result.join("/")
  }
}

///|
fn for_each_ref_upstream_atom(
  fs : OsFs,
  git_dir : String,
  atom : String,
  refname : String,
) -> String {
  // Only local branches have upstream
  guard refname.has_prefix("refs/heads/") else { return "" }
  let branch = String::unsafe_substring(refname, start=11, end=refname.length())
  let (_, branches) = @bitlib.read_repo_config(fs, git_dir)
  guard branches.get(branch) is Some(cfg) else { return "" }
  guard cfg.remote is Some(remote) else { return "" }
  guard cfg.merges.length() > 0 else { return "" }
  let merge = cfg.merges[0]
  // Convert merge ref (refs/heads/X) to remote tracking ref (refs/remotes/origin/X)
  let upstream_ref = if merge.has_prefix("refs/heads/") {
    let branch_part = String::unsafe_substring(
      merge,
      start=11,
      end=merge.length(),
    )
    "refs/remotes/" + remote + "/" + branch_part
  } else {
    merge
  }
  match atom {
    "upstream" => upstream_ref
    "upstream:short" => for_each_ref_short_refname(upstream_ref)
    "upstream:remotename" => remote
    "upstream:remoteref" =>
      if merge.has_prefix("refs/heads/") {
        merge
      } else {
        upstream_ref
      }
    "upstream:track" | "upstream:trackshort" | "upstream:track,nobracket" =>
      // Simplified: would need to compute ahead/behind
      ""
    _ if atom.has_prefix("upstream:lstrip=") ||
      atom.has_prefix("upstream:strip=") => {
      let eq_pos = atom.find("=").unwrap()
      let n_str = String::unsafe_substring(
        atom,
        start=eq_pos + 1,
        end=atom.length(),
      )
      let n = @strconv.parse_int(n_str) catch { _ => 0 }
      if n < 0 {
        for_each_ref_lstrip_negative(upstream_ref, -n)
      } else {
        for_each_ref_strip_refname(upstream_ref, n)
      }
    }
    _ if atom.has_prefix("upstream:rstrip=") => {
      let n_str = String::unsafe_substring(atom, start=16, end=atom.length())
      let n = @strconv.parse_int(n_str) catch { _ => 0 }
      for_each_ref_rstrip_n(upstream_ref, n)
    }
    _ => upstream_ref
  }
}

///|
fn for_each_ref_push_atom(
  fs : OsFs,
  git_dir : String,
  atom : String,
  refname : String,
) -> String {
  // push is like upstream but for push remote
  guard refname.has_prefix("refs/heads/") else { return "" }
  let branch = String::unsafe_substring(refname, start=11, end=refname.length())
  let (remotes, branches) = @bitlib.read_repo_config(fs, git_dir)
  // git push remote priority:
  // 1. branch.<name>.pushRemote
  // 2. remote.pushdefault
  // 3. branch.<name>.remote
  let branch_push_remote = for_each_ref_read_branch_pushremote(
    fs, git_dir, branch,
  )
  let remote = match branch_push_remote {
    Some(r) => r
    None => {
      let pushdefault = for_each_ref_read_pushdefault(fs, git_dir)
      match pushdefault {
        Some(r) => r
        None =>
          match branches.get(branch) {
            Some(cfg) =>
              match cfg.remote {
                Some(r) => r
                None => "origin"
              }
            None => "origin"
          }
      }
    }
  }
  // Check if remote exists
  guard remotes.get(remote) is Some(_) else { return "" }
  let push_ref = "refs/remotes/" + remote + "/" + branch
  match atom {
    "push" => push_ref
    "push:short" => for_each_ref_short_refname(push_ref)
    "push:remotename" => remote
    "push:remoteref" => "refs/heads/" + branch
    "push:track" | "push:trackshort" | "push:track,nobracket" => ""
    _ if atom.has_prefix("push:lstrip=") || atom.has_prefix("push:strip=") => {
      let eq_pos = atom.find("=").unwrap()
      let n_str = String::unsafe_substring(
        atom,
        start=eq_pos + 1,
        end=atom.length(),
      )
      let n = @strconv.parse_int(n_str) catch { _ => 0 }
      if n < 0 {
        for_each_ref_lstrip_negative(push_ref, -n)
      } else {
        for_each_ref_strip_refname(push_ref, n)
      }
    }
    _ if atom.has_prefix("push:rstrip=") => {
      let n_str = String::unsafe_substring(atom, start=12, end=atom.length())
      let n = @strconv.parse_int(n_str) catch { _ => 0 }
      for_each_ref_rstrip_n(push_ref, n)
    }
    _ => push_ref
  }
}

///|
fn for_each_ref_read_pushdefault(fs : OsFs, git_dir : String) -> String? {
  let content = @bitlib.read_config_content(fs, git_dir)
  let blocks = @bitlib.parse_config_blocks(content)
  for block in blocks {
    // Look for [remote] section (no subsection name)
    if block.section != Some("remote") || block.name is Some(_) {
      continue
    }
    for line in block.lines {
      match @bitlib.parse_config_kv(line) {
        Some((key, value)) if key == "pushdefault" => return Some(value)
        _ => ()
      }
    }
  }
  None
}

///|
fn for_each_ref_read_branch_pushremote(
  fs : OsFs,
  git_dir : String,
  branch_name : String,
) -> String? {
  let content = @bitlib.read_config_content(fs, git_dir)
  let blocks = @bitlib.parse_config_blocks(content)
  for block in blocks {
    if block.section != Some("branch") || block.name != Some(branch_name) {
      continue
    }
    for line in block.lines {
      match @bitlib.parse_config_kv(line) {
        Some((key, value)) if key == "pushremote" => return Some(value)
        _ => ()
      }
    }
  }
  None
}

///|
fn for_each_ref_commit_atom(
  atom : String,
  commit_data : Bytes,
  tag_data : Bytes,
  is_tag : Bool,
) -> String {
  let text = if is_tag {
    decode_bytes(tag_data)
  } else {
    decode_bytes(commit_data)
  }
  if text.length() == 0 {
    return ""
  }
  // Parse commit/tag fields
  let mut author = ""
  let mut committer = ""
  let mut tagger = ""
  let mut subject = ""
  let mut body = ""
  let mut in_body = false
  let mut past_headers = false
  let body_lines : Array[String] = []
  for line_view in text.split("\n") {
    let raw_line = line_view.to_string()
    // Strip trailing \r for header/subject parsing (CRLF support)
    let line = if raw_line.has_suffix("\r") {
      String::unsafe_substring(raw_line, start=0, end=raw_line.length() - 1)
    } else {
      raw_line
    }
    if not(past_headers) {
      if line.length() == 0 {
        past_headers = true
        continue
      }
      if line.has_prefix("author ") {
        author = String::unsafe_substring(line, start=7, end=line.length())
      } else if line.has_prefix("committer ") {
        committer = String::unsafe_substring(line, start=10, end=line.length())
      } else if line.has_prefix("tagger ") {
        tagger = String::unsafe_substring(line, start=7, end=line.length())
      }
    } else if not(in_body) {
      subject = line
      in_body = true
    } else {
      // Body lines preserve original \r for CRLF fidelity
      body_lines.push(raw_line)
    }
  }
  body = body_lines.join("\n")
  // Determine which ident to use for creator* atoms
  let creator = if tagger.length() > 0 {
    tagger
  } else if committer.length() > 0 {
    committer
  } else {
    author
  }
  match atom {
    "author" => author
    "committer" => committer
    "tagger" => tagger
    "creator" => creator
    "authorname" => for_each_ref_ident_name(author)
    "authoremail" => for_each_ref_ident_email(author)
    "authoremail:trim" => for_each_ref_ident_email_trim(author)
    "authoremail:localpart"
    | "authoremail:trim,localpart"
    | "authoremail:localpart,trim" => for_each_ref_ident_email_localpart(author)
    "authordate" => for_each_ref_ident_date(author)
    "authordate:short" => for_each_ref_ident_date_short(author)
    "authordate:iso8601" | "authordate:iso" =>
      for_each_ref_ident_date_iso(author)
    "authordate:unix" => for_each_ref_ident_date_unix(author)
    "authordate:rfc2822" | "authordate:rfc" =>
      for_each_ref_ident_date_rfc(author)
    "authordate:relative" => for_each_ref_ident_date(author) // simplified
    _ if atom.has_prefix("authordate:format:") => {
      let fmt = String::unsafe_substring(atom, start=18, end=atom.length())
      for_each_ref_ident_date_strftime(author, fmt)
    }
    "committername" => for_each_ref_ident_name(committer)
    "committeremail" => for_each_ref_ident_email(committer)
    "committeremail:trim" => for_each_ref_ident_email_trim(committer)
    "committeremail:localpart"
    | "committeremail:trim,localpart"
    | "committeremail:localpart,trim" =>
      for_each_ref_ident_email_localpart(committer)
    "committerdate" => for_each_ref_ident_date(committer)
    "committerdate:short" => for_each_ref_ident_date_short(committer)
    "committerdate:iso8601" | "committerdate:iso" =>
      for_each_ref_ident_date_iso(committer)
    "committerdate:unix" => for_each_ref_ident_date_unix(committer)
    "committerdate:rfc2822" | "committerdate:rfc" =>
      for_each_ref_ident_date_rfc(committer)
    "committerdate:relative" => for_each_ref_ident_date(committer) // simplified
    _ if atom.has_prefix("committerdate:format:") => {
      let fmt = String::unsafe_substring(atom, start=21, end=atom.length())
      for_each_ref_ident_date_strftime(committer, fmt)
    }
    "taggername" => for_each_ref_ident_name(tagger)
    "taggeremail" => for_each_ref_ident_email(tagger)
    "taggeremail:trim" => for_each_ref_ident_email_trim(tagger)
    "taggeremail:localpart"
    | "taggeremail:trim,localpart"
    | "taggeremail:localpart,trim" => for_each_ref_ident_email_localpart(tagger)
    "taggerdate" => for_each_ref_ident_date(tagger)
    "taggerdate:short" => for_each_ref_ident_date_short(tagger)
    "taggerdate:iso8601" | "taggerdate:iso" =>
      for_each_ref_ident_date_iso(tagger)
    "taggerdate:unix" => for_each_ref_ident_date_unix(tagger)
    "taggerdate:rfc2822" | "taggerdate:rfc" =>
      for_each_ref_ident_date_rfc(tagger)
    "taggerdate:relative" => for_each_ref_ident_date(tagger) // simplified
    _ if atom.has_prefix("taggerdate:format:") => {
      let fmt = String::unsafe_substring(atom, start=18, end=atom.length())
      for_each_ref_ident_date_strftime(tagger, fmt)
    }
    "creatordate" => for_each_ref_ident_date(creator)
    "creatordate:short" => for_each_ref_ident_date_short(creator)
    "creatordate:iso8601" | "creatordate:iso" =>
      for_each_ref_ident_date_iso(creator)
    "creatordate:unix" => for_each_ref_ident_date_unix(creator)
    "creatordate:rfc2822" | "creatordate:rfc" =>
      for_each_ref_ident_date_rfc(creator)
    "creatordate:relative" => for_each_ref_ident_date(creator) // simplified
    _ if atom.has_prefix("creatordate:format:") => {
      let fmt = String::unsafe_substring(atom, start=19, end=atom.length())
      for_each_ref_ident_date_strftime(creator, fmt)
    }
    "subject" => subject
    "subject:sanitize" => {
      let sb = StringBuilder::new()
      for c in subject {
        if c == ' ' {
          sb.write_char('-')
        } else {
          sb.write_char(c)
        }
      }
      sb.to_string()
    }
    "body" => body
    "contents" =>
      if body.length() > 0 {
        subject + "\n" + body + "\n"
      } else {
        subject + "\n"
      }
    "contents:body" => if body.length() > 0 { body + "\n" } else { "" }
    "contents:subject" => subject
    "contents:signature" => ""
    "contents:size" => {
      let full = if body.length() > 0 {
        subject + "\n" + body + "\n"
      } else {
        subject + "\n"
      }
      full.to_array().length().to_string()
    }
    // Signature atoms — bit does not verify GPG signatures,
    // so return "N" (no signature) for grade and empty for others
    "signature" => ""
    "signature:grade" => "N"
    "signature:key" => ""
    "signature:signer" => ""
    "signature:fingerprint" => ""
    "signature:primarykeyfingerprint" => ""
    "signature:trustlevel" => ""
    _ => ""
  }
}

///|
fn for_each_ref_ident_name(ident : String) -> String {
  // "Name <email> timestamp tz" -> "Name"
  match ident.find(" <") {
    Some(idx) => String::unsafe_substring(ident, start=0, end=idx)
    None => ident
  }
}

///|
fn for_each_ref_ident_email(ident : String) -> String {
  // "Name <email> timestamp tz" -> "<email>"
  match ident.find("<") {
    Some(start) =>
      match ident.find(">") {
        Some(end_pos) =>
          String::unsafe_substring(ident, start~, end=end_pos + 1)
        None => ""
      }
    None => ""
  }
}

///|
fn for_each_ref_ident_email_trim(ident : String) -> String {
  // "Name <email> timestamp tz" -> "email"
  match ident.find("<") {
    Some(start) =>
      match ident.find(">") {
        Some(end_pos) =>
          String::unsafe_substring(ident, start=start + 1, end=end_pos)
        None => ""
      }
    None => ""
  }
}

///|
fn for_each_ref_ident_email_localpart(ident : String) -> String {
  // "Name <email@domain> timestamp tz" -> "email"
  let email = for_each_ref_ident_email_trim(ident)
  match email.find("@") {
    Some(idx) => String::unsafe_substring(email, start=0, end=idx)
    None => email
  }
}

///|
fn for_each_ref_ident_date(ident : String) -> String {
  // Extract timestamp and tz, format as default date
  let (ts, tz) = for_each_ref_parse_ident_ts(ident)
  if ts == 0L {
    return ""
  }
  format_timestamp_default(ts, tz)
}

///|
fn for_each_ref_ident_date_short(ident : String) -> String {
  let (ts, tz) = for_each_ref_parse_ident_ts(ident)
  if ts == 0L {
    return ""
  }
  format_timestamp_short(ts, tz)
}

///|
fn for_each_ref_ident_date_iso(ident : String) -> String {
  let (ts, tz) = for_each_ref_parse_ident_ts(ident)
  if ts == 0L {
    return ""
  }
  format_timestamp_iso(ts, tz)
}

///|
fn for_each_ref_ident_date_unix(ident : String) -> String {
  let (ts, _tz) = for_each_ref_parse_ident_ts(ident)
  if ts == 0L {
    return ""
  }
  ts.to_string()
}

///|
fn for_each_ref_ident_date_rfc(ident : String) -> String {
  let (ts, tz) = for_each_ref_parse_ident_ts(ident)
  if ts == 0L {
    return ""
  }
  format_timestamp_rfc2822(ts, tz)
}

///|
fn for_each_ref_ident_date_strftime(ident : String, _fmt : String) -> String {
  // Simplified strftime - handle common patterns
  let (ts, tz) = for_each_ref_parse_ident_ts(ident)
  if ts == 0L {
    return ""
  }
  // For now, use ISO format as default strftime output
  format_timestamp_iso(ts, tz)
}

///|
fn for_each_ref_parse_ident_ts(ident : String) -> (Int64, String) {
  // "Name <email> timestamp tz"
  match ident.find("> ") {
    Some(idx) => {
      let rest = String::unsafe_substring(
        ident,
        start=idx + 2,
        end=ident.length(),
      )
      match rest.find(" ") {
        Some(sp) => {
          let ts_str = String::unsafe_substring(rest, start=0, end=sp)
          let tz = String::unsafe_substring(
            rest,
            start=sp + 1,
            end=rest.length(),
          )
          let ts = @strconv.parse_int64(ts_str) catch { _ => 0L }
          (ts, tz)
        }
        None => {
          let ts = @strconv.parse_int64(rest) catch { _ => 0L }
          (ts, "+0000")
        }
      }
    }
    None => (0L, "+0000")
  }
}

///|
