///| Ref resolution helpers (rev-parse/show-ref)

///|
pub fn rev_parse(
  fs : &@types.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> @object.ObjectId? raise @object.GitError {
  if spec.has_prefix(":/") && spec.length() > 2 {
    let needle = substring_revparse(spec, 2, spec.length())
    return resolve_commit_message_search_all_refs(fs, git_dir, needle)
  }
  match parse_commit_message_search_spec(spec) {
    Some((base_spec, needle)) =>
      return resolve_commit_message_search(fs, git_dir, base_spec, needle)
    None => ()
  }
  match spec.find(":") {
    Some(idx) =>
      if idx > 0 && idx + 1 <= spec.length() {
        let rev_part = substring_revparse(spec, 0, idx)
        let path_part = substring_revparse(spec, idx + 1, spec.length())
        let base = rev_parse(fs, git_dir, rev_part)
        guard base is Some(base_id) else { return None }
        return resolve_path_in_commit(fs, git_dir, base_id, path_part)
      }
    None => ()
  }
  match parse_peel_commit_spec(spec) {
    Some(base_spec) => {
      let base = rev_parse(fs, git_dir, base_spec)
      guard base is Some(base_id) else { return None }
      return peel_object_to_commit(fs, git_dir, base_id)
    }
    None => ()
  }
  match parse_peel_tree_spec(spec) {
    Some(base_spec) => {
      let base = rev_parse(fs, git_dir, base_spec)
      guard base is Some(base_id) else { return None }
      return peel_object_to_tree(fs, git_dir, base_id)
    }
    None => ()
  }
  // Parse suffix (^, ^^, ~n, ^n)
  let (base_spec, suffix) = parse_rev_suffix(spec)
  // Resolve base reference
  let base_id = match resolve_base_ref(fs, git_dir, base_spec) {
    Some(id) => id
    None => return None
  }
  match suffix {
    None => Some(base_id)
    Some(parsed_suffix) => apply_rev_suffix(fs, git_dir, base_id, parsed_suffix)
  }
}

///|
fn parse_commit_message_search_spec(spec : String) -> (String, String)? {
  let marker = "^{/"
  match spec.find(marker) {
    Some(idx) if idx > 0 &&
      spec.has_suffix("}") &&
      idx + marker.length() < spec.length() - 1 =>
      Some(
        (
          substring_revparse(spec, 0, idx),
          substring_revparse(spec, idx + marker.length(), spec.length() - 1),
        ),
      )
    _ => None
  }
}

///|
fn resolve_commit_message_search(
  fs : &@types.RepoFileSystem,
  git_dir : String,
  base_spec : String,
  needle : String,
) -> @object.ObjectId? raise @object.GitError {
  if needle.length() == 0 {
    return None
  }
  let base = rev_parse(fs, git_dir, base_spec)
  guard base is Some(base_id) else { return None }
  // !-prefix means negation: find commit whose message does NOT contain the pattern
  if needle.has_prefix("!-") {
    let actual_needle = substring_revparse(needle, 2, needle.length())
    return find_reachable_commit_by_message_from_many(
      fs,
      git_dir,
      [base_id],
      actual_needle,
      negate=true,
    )
  }
  find_reachable_commit_by_message_from_many(fs, git_dir, [base_id], needle)
}

///|
fn resolve_commit_message_search_all_refs(
  fs : &@types.RepoFileSystem,
  git_dir : String,
  needle : String,
) -> @object.ObjectId? raise @object.GitError {
  if needle.length() == 0 {
    return None
  }
  let starts : Array[@object.ObjectId] = []
  let seen_start : Map[String, Bool] = {}
  let refs = show_ref(fs, git_dir)
  for item in refs {
    let (_, id) = item
    let hex = id.to_hex()
    if not(seen_start.contains(hex)) {
      seen_start[hex] = true
      starts.push(id)
    }
  }
  match @bitlib.resolve_head_commit(fs, git_dir) {
    Some(id) => {
      let hex = id.to_hex()
      if not(seen_start.contains(hex)) {
        seen_start[hex] = true
        starts.push(id)
      }
    }
    None => ()
  }
  if starts.length() == 0 {
    return None
  }
  // !-prefix means negation: find commit whose message does NOT contain the pattern
  if needle.has_prefix("!-") {
    let actual_needle = substring_revparse(needle, 2, needle.length())
    return find_reachable_commit_by_message_from_many(
      fs,
      git_dir,
      starts,
      actual_needle,
      negate=true,
    )
  }
  find_reachable_commit_by_message_from_many(fs, git_dir, starts, needle)
}

///|
fn find_reachable_commit_by_message_from_many(
  fs : &@types.RepoFileSystem,
  git_dir : String,
  starts : Array[@object.ObjectId],
  needle : String,
  negate? : Bool = false,
) -> @object.ObjectId? raise @object.GitError {
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let queue : Array[@object.ObjectId] = []
  for start in starts {
    queue.push(start)
  }
  let seen : Map[String, Bool] = {}
  let mut best_id : @object.ObjectId? = None
  let mut best_time = -1L
  while queue.length() > 0 {
    let current = queue.unsafe_pop()
    let hex = current.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    match db.get(fs, current) {
      Some(obj) =>
        if obj.obj_type == @object.ObjectType::Commit {
          let contains = commit_message_contains(obj.data, needle)
          let matches = if negate { not(contains) } else { contains }
          if matches {
            let ts = parse_commit_committer_timestamp(obj.data)
            if best_id is None || ts > best_time {
              best_id = Some(current)
              best_time = ts
            }
          }
          let info = @repo.parse_commit(obj.data)
          for parent in info.parents {
            if not(seen.contains(parent.to_hex())) {
              queue.push(parent)
            }
          }
        }
      None => ()
    }
  }
  best_id
}

///|
fn commit_message_contains(data : Bytes, needle : String) -> Bool {
  let text = @utf8.decode_lossy(data[:])
  match text.find("\n\n") {
    Some(idx) =>
      substring_revparse(text, idx + 2, text.length()).find(needle) is Some(_)
    None => false
  }
}

///|
fn parse_commit_committer_timestamp(data : Bytes) -> Int64 {
  let text = @utf8.decode_lossy(data[:])
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
      break
    }
    if line.has_prefix("committer ") {
      let rest = substring_revparse(line, 10, line.length())
      return parse_identity_timestamp(rest)
    }
  }
  0L
}

///|
fn parse_identity_timestamp(identity : String) -> Int64 {
  let last_space = identity.rev_find(" ")
  guard last_space is Some(tz_idx) else { return 0L }
  let before_tz = substring_revparse(identity, 0, tz_idx)
  let second_last = before_tz.rev_find(" ")
  guard second_last is Some(ts_idx) else { return 0L }
  let ts = substring_revparse(before_tz, ts_idx + 1, before_tz.length())
  parse_revparse_int64(ts)
}

///|
fn parse_revparse_int64(s : String) -> Int64 {
  let mut value = 0L
  for c in s {
    if c < '0' || c > '9' {
      return value
    }
    let digit = c.to_int() - '0'.to_int()
    value = value * 10L + digit.to_int64()
  }
  value
}

///|
fn parse_peel_commit_spec(spec : String) -> String? {
  let suffix = "^{commit}"
  if spec.has_suffix(suffix) && spec.length() > suffix.length() {
    return Some(substring_revparse(spec, 0, spec.length() - suffix.length()))
  }
  None
}

///|
fn parse_peel_tree_spec(spec : String) -> String? {
  let suffix = "^{tree}"
  if spec.has_suffix(suffix) && spec.length() > suffix.length() {
    return Some(substring_revparse(spec, 0, spec.length() - suffix.length()))
  }
  None
}

///|
fn peel_object_to_commit(
  fs : &@types.RepoFileSystem,
  git_dir : String,
  id : @object.ObjectId,
) -> @object.ObjectId? raise @object.GitError {
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let mut current = id
  for _ in 0..<8 {
    let obj = db.get(fs, current)
    guard obj is Some(o) else { return None }
    match o.obj_type {
      @object.ObjectType::Commit => return Some(current)
      @object.ObjectType::Tag =>
        match parse_tag_object_target(o.data) {
          Some(next) => current = next
          None => return None
        }
      _ => return None
    }
  }
  None
}

///|
fn peel_object_to_tree(
  fs : &@types.RepoFileSystem,
  git_dir : String,
  id : @object.ObjectId,
) -> @object.ObjectId? raise @object.GitError {
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let mut current = id
  for _ in 0..<8 {
    let obj = db.get(fs, current)
    guard obj is Some(o) else { return None }
    match o.obj_type {
      @object.ObjectType::Tree => return Some(current)
      @object.ObjectType::Commit => return Some(@repo.parse_commit(o.data).tree)
      @object.ObjectType::Tag =>
        match parse_tag_object_target(o.data) {
          Some(next) => current = next
          None => return None
        }
      _ => return None
    }
  }
  None
}

///|
fn parse_tag_object_target(data : Bytes) -> @object.ObjectId? {
  let text = @utf8.decode_lossy(data[:])
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 {
      break
    }
    if line.has_prefix("object ") {
      let hex = substring_revparse(line, 7, line.length())
      let id = @object.ObjectId::from_hex(hex) catch { _ => return None }
      return Some(id)
    }
  }
  None
}

///|
/// Parse revision suffix like ^, ^^, ~n
fn parse_rev_suffix(spec : String) -> (String, String?) {
  let chars = spec.to_array()
  let len = chars.length()
  if len == 0 {
    return (spec, None)
  }
  // Find where suffix starts - must start with ^ or ~
  let mut suffix_start = -1
  for i = 0; i < len; i = i + 1 {
    let c = chars[i]
    if c == '^' || c == '~' {
      suffix_start = i
      break
    }
  }
  if suffix_start < 0 {
    return (spec, None)
  }
  // Validate suffix - only ^, ~, and digits after the first ^ or ~
  for i = suffix_start; i < len; i = i + 1 {
    let c = chars[i]
    if not(c == '^' || c == '~' || (c >= '0' && c <= '9')) {
      // Invalid suffix character - no suffix
      return (spec, None)
    }
  }
  let base = substring_revparse(spec, 0, suffix_start)
  let suffix = substring_revparse(spec, suffix_start, len)
  (base, Some(suffix))
}

///|
/// Apply revision suffix operators.
fn apply_rev_suffix(
  fs : &@types.RepoFileSystem,
  git_dir : String,
  start : @object.ObjectId,
  suffix : String,
) -> @object.ObjectId? raise @object.GitError {
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let chars = suffix.to_array()
  let mut current = start
  let mut i = 0
  while i < chars.length() {
    let op = chars[i]
    if op == '^' {
      i += 1
      let mut parent_index = 0
      let mut has_digits = false
      while i < chars.length() && chars[i] >= '0' && chars[i] <= '9' {
        has_digits = true
        parent_index = parent_index * 10 + (chars[i].to_int() - '0'.to_int())
        i += 1
      }
      if has_digits {
        // `^0` peels to the commit (dereference tags).
        if parent_index == 0 {
          current = peel_to_commit_id(db, fs, current)
          continue
        }
      } else {
        parent_index = 1
      }
      let next = commit_nth_parent(db, fs, current, parent_index)
      guard next is Some(parent_id) else { return None }
      current = parent_id
      continue
    }
    if op == '~' {
      i += 1
      let mut steps = 0
      let mut has_digits = false
      while i < chars.length() && chars[i] >= '0' && chars[i] <= '9' {
        has_digits = true
        steps = steps * 10 + (chars[i].to_int() - '0'.to_int())
        i += 1
      }
      if not(has_digits) {
        steps = 1
      }
      for _ in 0..<steps {
        let next = commit_nth_parent(db, fs, current, 1)
        guard next is Some(parent_id) else { return None }
        current = parent_id
      }
      continue
    }
    return None
  }
  Some(current)
}

///|
/// Peel tags to reach the underlying commit ID.
fn peel_to_commit_id(
  db : @bitlib.ObjectDb,
  fs : &@types.RepoFileSystem,
  id : @object.ObjectId,
) -> @object.ObjectId raise @object.GitError {
  let mut current = id
  for _ in 0..<8 {
    let obj = db.get(fs, current)
    guard obj is Some(o) else { break }
    match o.obj_type {
      @object.ObjectType::Commit => return current
      @object.ObjectType::Tag =>
        match parse_tag_object_target(o.data) {
          Some(next) => current = next
          None => break
        }
      _ => break
    }
  }
  current
}

///|
fn commit_nth_parent(
  db : @bitlib.ObjectDb,
  fs : &@types.RepoFileSystem,
  commit_id : @object.ObjectId,
  nth_parent : Int,
) -> @object.ObjectId? raise @object.GitError {
  if nth_parent <= 0 {
    return Some(commit_id)
  }
  // Peel tags to reach commit
  let peeled = peel_to_commit_id(db, fs, commit_id)
  let obj = db.get(fs, peeled)
  guard obj is Some(o) else { return None }
  if o.obj_type != @object.ObjectType::Commit {
    return None
  }
  let info = @repo.parse_commit(o.data)
  if nth_parent > info.parents.length() {
    return None
  }
  Some(info.parents[nth_parent - 1])
}

///|
fn substring_revparse(s : String, start : Int, end : Int) -> String {
  let chars = s.to_array()
  let result = StringBuilder::new()
  for i = start; i < end && i < chars.length(); i = i + 1 {
    result.write_char(chars[i])
  }
  result.to_string()
}

///|
fn resolve_abbrev_ref_id(
  fs : &@types.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> @object.ObjectId? raise @object.GitError {
  if spec.length() < 4 ||
    spec.length() >= 40 ||
    not(@bithash.is_hex_string(spec)) {
    return None
  }
  let needle = @bithash.lower_hex_string(spec)
  let refs = show_ref(fs, git_dir)
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let queue : Array[@object.ObjectId] = []
  let seen : Map[String, Bool] = {}
  for item in refs {
    let (_, id) = item
    queue.push(id)
  }
  match @bitlib.resolve_head_commit(fs, git_dir) {
    Some(id) => queue.push(id)
    None => ()
  }
  let mut matched : @object.ObjectId? = None
  while queue.length() > 0 {
    let id = match queue.pop() {
      Some(oid) => oid
      None => break
    }
    let hex = id.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    if hex.has_prefix(needle) {
      match matched {
        None => matched = Some(id)
        Some(prev) => if prev != id { return None }
      }
    }
    match db.get(fs, id) {
      Some(obj) =>
        if obj.obj_type == @object.ObjectType::Commit {
          let info = @repo.parse_commit(obj.data)
          for parent in info.parents {
            queue.push(parent)
          }
        }
      None => ()
    }
  }
  matched
}

///|
/// Resolve base reference (without suffix)
fn resolve_base_ref(
  fs : &@types.RepoFileSystem,
  git_dir : String,
  spec : String,
) -> @object.ObjectId? raise @object.GitError {
  if spec == "HEAD" || spec == "" || spec == "@" {
    return @bitlib.resolve_head_commit(fs, git_dir)
  }
  if @bitlib.resolve_ref(fs, git_dir, spec) is Some(id) {
    return Some(id)
  }
  if spec.has_prefix("refs/") {
    return @bitlib.resolve_ref(fs, git_dir, spec)
  }
  if spec.has_prefix("heads/") ||
    spec.has_prefix("tags/") ||
    spec.has_prefix("remotes/") {
    return @bitlib.resolve_ref(fs, git_dir, "refs/" + spec)
  }
  if spec.length() == 40 && @bithash.is_hex_string(spec) {
    match @object.ObjectId::from_hex(spec) {
      id => return Some(id)
    }
  }
  if resolve_abbrev_ref_id(fs, git_dir, spec) is Some(id) {
    return Some(id)
  }
  if @bitlib.resolve_ref(fs, git_dir, "refs/heads/" + spec) is Some(id) {
    return Some(id)
  }
  if @bitlib.resolve_ref(fs, git_dir, "refs/remotes/" + spec) is Some(id) {
    return Some(id)
  }
  if @bitlib.resolve_ref(fs, git_dir, "refs/tags/" + spec) is Some(id) {
    return Some(id)
  }
  None
}

///|
/// Resolve path within a commit/tree
fn resolve_path_in_commit(
  fs : &@types.RepoFileSystem,
  git_dir : String,
  base_id : @object.ObjectId,
  path : String,
) -> @object.ObjectId? raise @object.GitError {
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let obj = db.get(fs, base_id)
  match obj {
    None => return None
    Some(o) => {
      let tree_id = match o.obj_type {
        @object.ObjectType::Commit => @repo.parse_commit(o.data).tree
        @object.ObjectType::Tree => base_id
        _ => return None
      }
      // Empty path means "return the tree itself" (e.g., HEAD:)
      if path.length() == 0 {
        return Some(tree_id)
      }
      let entry = @bitlib.find_tree_entry(db, fs, tree_id, path)
      match entry {
        Some(e) => Some(e.id)
        None => None
      }
    }
  }
}

///|
/// List all refs (loose + packed).
pub fn show_ref(
  fs : &@types.RepoFileSystem,
  git_dir : String,
) -> Array[(String, @object.ObjectId)] raise @object.GitError {
  let out : Map[String, @object.ObjectId] = {}
  let refs_dir = @repo.join_path(git_dir, "refs")
  if fs.is_dir(refs_dir) {
    ref_collect_loose(fs, git_dir, refs_dir, "refs", out)
  }
  let packed = @repo.join_path(git_dir, "packed-refs")
  if fs.is_file(packed) {
    ref_collect_packed(fs, packed, out)
  }
  let result : Array[(String, @object.ObjectId)] = []
  for item in out.to_array() {
    let (name, id) = item
    result.push((name, id))
  }
  result.sort_by(fn(a, b) {
    let la = a.0.to_array()
    let lb = b.0.to_array()
    let min_len = if la.length() < lb.length() {
      la.length()
    } else {
      lb.length()
    }
    for i in 0..<min_len {
      let ca = la[i].to_int()
      let cb = lb[i].to_int()
      if ca != cb {
        return ca - cb
      }
    }
    la.length() - lb.length()
  })
  result
}

///|
/// Format like `git show-ref` output.
pub fn show_ref_text(
  fs : &@types.RepoFileSystem,
  git_dir : String,
) -> Array[String] raise @object.GitError {
  let refs = show_ref(fs, git_dir)
  let lines : Array[String] = []
  for item in refs {
    let (name, id) = item
    lines.push("\{id.to_hex()} \{name}")
  }
  lines
}

///|
fn ref_collect_loose(
  fs : &@types.RepoFileSystem,
  git_dir : String,
  dir : String,
  prefix : String,
  out : Map[String, @object.ObjectId],
) -> Unit raise @object.GitError {
  let entries = fs.readdir(dir)
  for name in entries {
    let path = @repo.join_path(dir, name)
    let rel = if prefix == "" { name } else { prefix + "/" + name }
    if fs.is_dir(path) {
      ref_collect_loose(fs, git_dir, path, rel, out)
    } else if fs.is_file(path) {
      let line = ref_read_line(fs, path)
      if line.has_prefix("ref: ") {
        let target = String::unsafe_substring(line, start=5, end=line.length())
        let resolved = @bitlib.resolve_ref(fs, git_dir, target) catch {
          _ => None
        }
        match resolved {
          Some(id) => out[rel] = id
          None => ()
        }
      } else {
        out[rel] = @object.ObjectId::from_hex(line)
      }
    }
  }
}

///|
fn ref_collect_packed(
  fs : &@types.RepoFileSystem,
  packed_path : String,
  out : Map[String, @object.ObjectId],
) -> Unit raise @object.GitError {
  let text = @utf8.decode_lossy(fs.read_file(packed_path)[:])
  for line_view in text.split("\n") {
    let line = ref_trim_line(line_view.to_string())
    if line.length() == 0 {
      continue
    }
    if line.has_prefix("#") || line.has_prefix("^") {
      continue
    }
    let space = line.find(" ")
    match space {
      None => continue
      Some(idx) => {
        if idx + 1 >= line.length() {
          continue
        }
        let id_hex = String::unsafe_substring(line, start=0, end=idx)
        let name = String::unsafe_substring(
          line,
          start=idx + 1,
          end=line.length(),
        )
        if not(out.contains(name)) {
          out[name] = @object.ObjectId::from_hex(id_hex)
        }
      }
    }
  }
}

///|
fn ref_read_line(
  fs : &@types.RepoFileSystem,
  path : String,
) -> String raise @object.GitError {
  let text = @utf8.decode_lossy(fs.read_file(path)[:])
  for line_view in text.split("\n") {
    let line = ref_trim_line(line_view.to_string())
    if line.length() > 0 {
      return line
    }
  }
  raise @object.GitError::InvalidObject("Empty ref: \{path}")
}

///|
fn ref_trim_line(line : String) -> String {
  let mut s = line
  if s.has_suffix("\r") {
    s = String::unsafe_substring(s, start=0, end=s.length() - 1)
  }
  s
}
