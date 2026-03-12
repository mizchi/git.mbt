///|
async fn handle_update_index(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let root = get_work_root()
  let git_dir = resolve_git_dir(fs, root)
  let mut add = false
  let mut again = false
  let mut remove = false
  let mut force_remove = false
  let mut refresh = false
  let mut quiet = false
  let mut ignore_missing = false
  let mut allow_unmerged_refresh = false
  let mut ignore_submodules = false
  let mut stdin = false
  let mut nul_term = false
  let mut verbose = false
  let mut skip_worktree_mode : Bool? = None
  let mut assume_unchanged_mode : Bool? = None
  let mut current_chmod : String? = None
  let mut show_index_version = false
  let mut set_index_version : Int? = None
  let cacheinfo : Array[(String, String, String)] = []
  let chmod_updates : Array[(String, String)] = []
  let mut index_info = false
  let paths : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--add" => add = true
      "--again" => again = true
      "--remove" => remove = true
      "--force-remove" => force_remove = true
      "--replace" => ()
      "--refresh" => refresh = true
      "--really-refresh" => refresh = true
      "-q" => quiet = true
      "--ignore-missing" => ignore_missing = true
      "--unmerged" => allow_unmerged_refresh = true
      "--ignore-submodules" => ignore_submodules = true
      "--skip-worktree" => skip_worktree_mode = Some(true)
      "--no-skip-worktree" => skip_worktree_mode = Some(false)
      "--assume-unchanged" => assume_unchanged_mode = Some(true)
      "--no-assume-unchanged" => assume_unchanged_mode = Some(false)
      "--show-index-version" => show_index_version = true
      "--stdin" => stdin = true
      "--index-info" => {
        index_info = true
        stdin = true
      }
      "-z" => nul_term = true
      "-v" | "--verbose" => verbose = true
      "--chmod=+x" => current_chmod = Some("+x")
      "--chmod=-x" => current_chmod = Some("-x")
      "--cacheinfo" if i + 1 < args.length() && args[i + 1].contains(",") => {
        let val = args[i + 1]
        match val.find(",") {
          Some(idx1) => {
            let mode = val[:idx1].to_string()
            let rest = val[idx1 + 1:].to_string()
            match rest.find(",") {
              Some(idx2) => {
                let sha = rest[:idx2].to_string()
                let path = rest[idx2 + 1:].to_string()
                cacheinfo.push((mode, sha, path))
                i += 2
                continue
              }
              None => {
                update_index_usage()
                continue
              }
            }
          }
          None => {
            update_index_usage()
            continue
          }
        }
      }
      "--cacheinfo" if i + 3 < args.length() => {
        cacheinfo.push((args[i + 1], args[i + 2], args[i + 3]))
        i += 4
        continue
      }
      "--cacheinfo" => update_index_usage()
      "--index-version" if i + 1 < args.length() => {
        match parse_update_index_version(args[i + 1]) {
          Some(version) => set_index_version = Some(version)
          None => {
            eprint_line("fatal: bad --index-version value")
            @sys.exit(128)
          }
        }
        i += 2
        continue
      }
      "--index-version" => update_index_usage()
      _ if arg.has_prefix("--index-version=") =>
        match parse_update_index_version(arg[16:].to_string()) {
          Some(version) => set_index_version = Some(version)
          None => {
            eprint_line("fatal: bad --index-version value")
            @sys.exit(128)
          }
        }
      _ if arg.has_prefix("--cacheinfo=") => {
        let val = arg[12:].to_string()
        match val.find(",") {
          Some(idx1) => {
            let mode = val[:idx1].to_string()
            let rest = val[idx1 + 1:].to_string()
            match rest.find(",") {
              Some(idx2) => {
                let sha = rest[:idx2].to_string()
                let path = rest[idx2 + 1:].to_string()
                cacheinfo.push((mode, sha, path))
              }
              None => update_index_usage()
            }
          }
          None => update_index_usage()
        }
      }
      "--" => {
        for j in (i + 1)..<args.length() {
          match current_chmod {
            Some(mode) => chmod_updates.push((args[j], mode))
            None => paths.push(args[j])
          }
        }
        break
      }
      _ if not(arg.has_prefix("-")) =>
        match current_chmod {
          Some(mode) => chmod_updates.push((arg, mode))
          None => paths.push(arg)
        }
      _ if arg.has_prefix("-") => update_index_usage()
      _ => ()
    }
    i += 1
  }
  if show_index_version {
    print_line(update_index_read_header_version(fs, git_dir).to_string())
  }
  let direct_updates : Array[@bitlib.IndexEntry] = []
  let direct_stage_updates : Array[@bitlib.IndexStageEntry] = []
  let direct_remove_paths : Array[String] = []
  if stdin {
    let input = decode_bytes(read_all_stdin())
    let sep = if nul_term { "\u0000" } else { "\n" }
    for part_view in input.split(sep) {
      let part = trim_string(part_view.to_string())
      if part.length() == 0 {
        continue
      }
      if index_info {
        match parse_update_index_info_line(part) {
          Some((mode, id, path, stage)) => {
            let normalized_path = normalize_update_index_path(path)
            if mode == 0 {
              direct_remove_paths.push(normalized_path)
            } else if stage != 0 {
              direct_stage_updates.push(
                @bitlib.IndexStageEntry::new(
                  @bitlib.IndexEntry::new(normalized_path, id, mode, 0),
                  stage,
                ),
              )
            } else {
              direct_updates.push(
                @bitlib.IndexEntry::new(normalized_path, id, mode, 0),
              )
            }
          }
          None => {
            eprint_line("error: bad index-info line: " + part)
            raise @bitcore.GitError::InvalidObject("bad index-info line")
          }
        }
      } else {
        paths.push(part)
      }
    }
  }
  for info in cacheinfo {
    let (mode_str, sha, path) = info
    let normalized_path = normalize_update_index_path(path) catch { _ => path }
    match parse_octal_mode(mode_str) {
      Some(0) => if verbose { print_line("remove '" + normalized_path + "'") }
      Some(_) => if verbose { print_line("add '" + normalized_path + "'") }
      None => ()
    }
    match parse_update_index_cacheinfo(mode_str, sha, path) {
      Some((mode, id, normalized_path)) =>
        if mode == 0 {
          direct_remove_paths.push(normalized_path)
        } else {
          direct_updates.push(
            @bitlib.IndexEntry::new(normalized_path, id, mode, 0),
          )
        }
      None => {
        eprint_line(
          "error: bad cacheinfo: " + mode_str + " " + sha + " " + path,
        )
        raise @bitcore.GitError::InvalidObject("bad cacheinfo")
      }
    }
  }
  if direct_stage_updates.length() > 0 {
    let remove_set : Map[String, Bool] = {}
    let replace_set : Map[String, Bool] = {}
    let merged_stage_entries : Array[@bitlib.IndexStageEntry] = []
    for path in direct_remove_paths {
      remove_set[path] = true
    }
    for entry in direct_updates {
      replace_set[normalize_update_index_path(entry.path)] = true
    }
    for item in direct_stage_updates {
      replace_set[normalize_update_index_path(item.entry.path)] = true
    }
    let existing_entries = @bitlib.read_index_entries(fs, git_dir)
    for entry in existing_entries {
      let normalized_path = normalize_update_index_path(entry.path)
      if remove_set.contains(normalized_path) ||
        replace_set.contains(normalized_path) {
        continue
      }
      merged_stage_entries.push(@bitlib.IndexStageEntry::new(entry, 0))
    }
    for entry in direct_updates {
      merged_stage_entries.push(@bitlib.IndexStageEntry::new(entry, 0))
    }
    merged_stage_entries.append(direct_stage_updates)
    @bitlib.write_index_stage_entries(fs, git_dir, merged_stage_entries)
  } else if direct_updates.length() > 0 || direct_remove_paths.length() > 0 {
    apply_update_index_entries(fs, git_dir, direct_updates, direct_remove_paths)
  }
  if again {
    handle_update_index_again(fs, root, git_dir, paths, remove)
  } else if refresh {
    handle_update_index_refresh(
      fs, root, git_dir, paths, ignore_missing, allow_unmerged_refresh, ignore_submodules,
      quiet,
    )
  } else if paths.length() > 0 &&
    (
      add ||
      remove ||
      force_remove ||
      (skip_worktree_mode is None && assume_unchanged_mode is None)
    ) {
    handle_update_index_paths(
      fs, root, git_dir, paths, add, remove, force_remove, ignore_missing, quiet,
    )
  }
  if chmod_updates.length() > 0 {
    update_index_apply_chmod(fs, root, git_dir, chmod_updates, verbose)
  }
  match skip_worktree_mode {
    Some(enabled) => {
      let normalized : Array[String] = []
      for p in paths {
        let clean = normalize_update_index_path(p)
        if clean.length() > 0 {
          normalized.push(clean)
        }
      }
      if normalized.length() > 0 {
        update_skip_worktree_state(fs, git_dir, normalized, enabled)
      }
    }
    None => ()
  }
  match assume_unchanged_mode {
    Some(enabled) => {
      let normalized : Array[String] = []
      for p in paths {
        let clean = normalize_update_index_path(p)
        if clean.length() > 0 {
          normalized.push(clean)
        }
      }
      if normalized.length() > 0 {
        update_assume_unchanged_state(fs, git_dir, normalized, enabled)
      }
    }
    None => ()
  }
  match set_index_version {
    Some(version) => {
      let previous = update_index_read_header_version(fs, git_dir)
      update_index_write_header_version(fs, git_dir, version)
      if verbose {
        print_line("index-version: was \{previous}, set to \{version}")
      }
    }
    None => ()
  }
}

///|
fn parse_update_index_info_line(
  line : String,
) -> (Int, @bitcore.ObjectId, String, Int)? {
  match line.find("\t") {
    None => None
    Some(tab_idx) => {
      let info = String::unsafe_substring(line, start=0, end=tab_idx)
      let path = String::unsafe_substring(
        line,
        start=tab_idx + 1,
        end=line.length(),
      )
      let normalized_path = normalize_update_index_path(path) catch {
        _ => return None
      }
      let fields = split_update_index_fields(info)
      if fields.length() == 0 {
        return None
      }
      match parse_octal_mode(fields[0]) {
        None => None
        Some(mode) =>
          if mode == 0 {
            if fields.length() < 2 {
              return None
            }
            Some((0, @bitcore.ObjectId::zero(), normalized_path, 0))
          } else {
            match fields.length() {
              2 => {
                let id = match parse_update_index_object_id(fields[1]) {
                  None => return None
                  Some(value) => value
                }
                Some((mode, id, normalized_path, 0))
              }
              3 =>
                if is_update_index_object_type(fields[1]) {
                  let id = match parse_update_index_object_id(fields[2]) {
                    None => return None
                    Some(value) => value
                  }
                  Some((mode, id, normalized_path, 0))
                } else {
                  match parse_update_index_stage(fields[2]) {
                    None => None
                    Some(stage) => {
                      let id = match parse_update_index_object_id(fields[1]) {
                        None => return None
                        Some(value) => value
                      }
                      Some((mode, id, normalized_path, stage))
                    }
                  }
                }
              4 =>
                if not(is_update_index_object_type(fields[1])) {
                  None
                } else {
                  match parse_update_index_stage(fields[3]) {
                    None => None
                    Some(stage) => {
                      let id = match parse_update_index_object_id(fields[2]) {
                        None => return None
                        Some(value) => value
                      }
                      Some((mode, id, normalized_path, stage))
                    }
                  }
                }
              _ => None
            }
          }
      }
    }
  }
}

///|
fn parse_update_index_cacheinfo(
  mode_str : String,
  sha : String,
  path : String,
) -> (Int, @bitcore.ObjectId, String)? {
  match parse_octal_mode(mode_str) {
    None => None
    Some(mode) => {
      let normalized_path = normalize_update_index_path(path) catch {
        _ => return None
      }
      if mode == 0 {
        None
      } else {
        let id = @bitcore.ObjectId::from_hex(sha) catch { _ => return None }
        if id == @bitcore.ObjectId::zero() {
          None
        } else {
          Some((mode, id, normalized_path))
        }
      }
    }
  }
}

///|
fn parse_update_index_stage(value : String) -> Int? {
  let parsed = @strconv.parse_int(value) catch { _ => return None }
  if parsed >= 0 && parsed <= 3 {
    Some(parsed)
  } else {
    None
  }
}

///|
fn parse_update_index_object_id(hex : String) -> @bitcore.ObjectId? {
  let id = @bitcore.ObjectId::from_hex(hex) catch { _ => return None }
  if id == @bitcore.ObjectId::zero() {
    None
  } else {
    Some(id)
  }
}

///|
fn is_update_index_object_type(value : String) -> Bool {
  value == "blob" || value == "tree" || value == "commit" || value == "tag"
}

///|
fn parse_octal_mode(s : String) -> Int? {
  let mut mode = 0
  if s.length() == 0 {
    return None
  }
  for c in s {
    if c < '0' || c > '7' {
      return None
    }
    mode = mode * 8 + (c.to_int() - '0'.to_int())
  }
  Some(mode)
}

///|
fn split_update_index_fields(s : String) -> Array[String] {
  let out : Array[String] = []
  for item in s.split(" ") {
    let part = trim_string(item.to_string())
    if part.length() > 0 {
      out.push(part)
    }
  }
  out
}

///|
fn apply_update_index_entries(
  fs : OsFs,
  git_dir : String,
  updates : Array[@bitlib.IndexEntry],
  removals : Array[String],
) -> Unit raise Error {
  let existing = @bitlib.read_index_entries(fs, git_dir)
  let update_map : Map[String, @bitlib.IndexEntry] = {}
  for entry in updates {
    update_map[normalize_update_index_path(entry.path)] = entry
  }
  let removal_set : Map[String, Bool] = {}
  for p in removals {
    removal_set[normalize_update_index_path(p)] = true
  }
  let out : Array[@bitlib.IndexEntry] = []
  for entry in existing {
    let path = normalize_update_index_path(entry.path)
    if removal_set.contains(path) {
      continue
    }
    match update_map.get(path) {
      Some(next) => {
        out.push(next)
        update_map.remove(path)
      }
      None => out.push(entry)
    }
  }
  for item in update_map.to_array() {
    let (_, entry) = item
    out.push(entry)
  }
  @bitlib.write_index_entries(fs, git_dir, dedupe_index_entries_by_path(out))
}

///|
fn dedupe_index_entries_by_path(
  entries : Array[@bitlib.IndexEntry],
) -> Array[@bitlib.IndexEntry] raise @bitcore.GitError {
  let by_path : Map[String, @bitlib.IndexEntry] = {}
  for entry in entries {
    by_path[normalize_update_index_path(entry.path)] = entry
  }
  let sorted : Array[(String, @bitlib.IndexEntry)] = by_path.to_array()
  sorted.sort_by((a, b) => String::compare(a.0, b.0))
  let out : Array[@bitlib.IndexEntry] = []
  for item in sorted {
    let (_, entry) = item
    out.push(entry)
  }
  out
}

///|
fn normalize_update_index_path(path : String) -> String raise @bitcore.GitError {
  if path.has_prefix("/") {
    raise @bitcore.GitError::InvalidObject("path must be relative")
  }
  @bitlib.normalize_repo_path(path)
}

///|
fn update_skip_worktree_state(
  fs : OsFs,
  git_dir : String,
  paths : Array[String],
  enabled : Bool,
) -> Unit raise Error {
  let state_path = git_dir + "/bit-skip-worktree"
  let state : Map[String, Bool] = {}
  if fs.is_file(state_path) {
    let text = decode_bytes(fs.read_file(state_path))
    for line_view in text.split("\n") {
      let line = trim_string(line_view.to_string())
      if line.length() > 0 {
        state[line] = true
      }
    }
  }
  for p in paths {
    if enabled {
      state[p] = true
    } else {
      state.remove(p)
    }
  }
  let out : Array[String] = []
  for item in state.to_array() {
    let (path, marked) = item
    if marked {
      out.push(path)
    }
  }
  out.sort_by((a, b) => String::compare(a, b))
  if out.length() == 0 {
    fs.remove_file(state_path) catch {
      _ => ()
    }
  } else {
    fs.write_string(state_path, out.join("\n") + "\n")
  }
  let entries = @bitlib.read_index_entries(fs, git_dir)
  let skip_worktree_paths : Map[String, Bool] = {}
  for path in out {
    skip_worktree_paths[path] = true
  }
  let assume_unchanged_paths = @bitlib.read_assume_unchanged_paths(fs, git_dir)
  @bitlib.write_index_entries_with_flags(
    fs, git_dir, entries, skip_worktree_paths, assume_unchanged_paths,
  )
}

///|
fn update_assume_unchanged_state(
  fs : OsFs,
  git_dir : String,
  paths : Array[String],
  enabled : Bool,
) -> Unit raise Error {
  let entries = @bitlib.read_index_entries(fs, git_dir)
  let skip_worktree_paths = @bitlib.read_skip_worktree_paths(fs, git_dir)
  let assume_unchanged_paths = @bitlib.read_assume_unchanged_paths(fs, git_dir)
  for path in paths {
    if enabled {
      assume_unchanged_paths[path] = true
    } else {
      assume_unchanged_paths.remove(path)
    }
  }
  @bitlib.write_index_entries_with_flags(
    fs, git_dir, entries, skip_worktree_paths, assume_unchanged_paths,
  )
}

///|
async fn update_index_usage() -> Unit {
  eprint_line("usage: git update-index [<options>] [--] [<file>...]")
  @sys.exit(129)
}

///|
fn parse_update_index_version(value : String) -> Int? {
  let parsed = @strconv.parse_int(value) catch { _ => return None }
  if parsed == 2 || parsed == 3 || parsed == 4 {
    Some(parsed)
  } else {
    None
  }
}

///|
fn update_index_read_header_version(fs : OsFs, git_dir : String) -> Int {
  let index_path = git_dir + "/index"
  if not(fs.is_file(index_path)) {
    return 2
  }
  let data = fs.read_file(index_path) catch { _ => return 2 }
  if data.length() < 12 {
    return 2
  }
  if not(
      data[0] == b'D' && data[1] == b'I' && data[2] == b'R' && data[3] == b'C',
    ) {
    return 2
  }
  (data[4].to_int() << 24) |
  (data[5].to_int() << 16) |
  (data[6].to_int() << 8) |
  data[7].to_int()
}

///|
fn update_index_write_header_version(
  fs : OsFs,
  git_dir : String,
  version : Int,
) -> Unit raise Error {
  let index_path = git_dir + "/index"
  if not(fs.is_file(index_path)) {
    @bitlib.write_index_entries(fs, git_dir, [])
  }
  let data = fs.read_file(index_path)
  if data.length() < 32 {
    raise @bitcore.GitError::InvalidObject("Index entry truncated")
  }
  let arr : Array[Byte] = []
  for b in data {
    arr.push(b)
  }
  arr[4] = ((version >> 24) & 0xFF).to_byte()
  arr[5] = ((version >> 16) & 0xFF).to_byte()
  arr[6] = ((version >> 8) & 0xFF).to_byte()
  arr[7] = (version & 0xFF).to_byte()
  let checksum_start = arr.length() - 20
  let content = Bytes::from_array(
    FixedArray::makei(checksum_start, fn(i) { arr[i] }),
  )
  let checksum = @bitcore.sha1(content)
  for i in 0..<20 {
    arr[checksum_start + i] = checksum.bytes[i]
  }
  fs.write_file(
    index_path,
    Bytes::from_array(FixedArray::makei(arr.length(), fn(i) { arr[i] })),
  )
}

///|
async fn update_index_apply_chmod(
  fs : OsFs,
  root : String,
  git_dir : String,
  ops : Array[(String, String)],
  verbose : Bool,
) -> Unit raise Error {
  let stage_paths : Array[String] = []
  let seen : Map[String, Bool] = {}
  for op in ops {
    let (raw_path, _) = op
    let normalized = normalize_update_index_path(raw_path)
    if not(seen.contains(normalized)) {
      stage_paths.push(normalized)
      seen[normalized] = true
    }
  }
  if stage_paths.length() > 0 {
    let existing_entries = @bitlib.read_index_entries(fs, git_dir)
    let stage_set : Map[String, Bool] = {}
    for path in stage_paths {
      stage_set[path] = true
    }
    let filtered_entries : Array[@bitlib.IndexEntry] = []
    for entry in existing_entries {
      if not(stage_set.contains(normalize_update_index_path(entry.path))) {
        filtered_entries.push(entry)
      }
    }
    @bitlib.write_index_entries(fs, git_dir, filtered_entries)
    @bitlib.add_paths_async(fs, fs, root, stage_paths)
  }
  let entries = @bitlib.read_index_entries(fs, git_dir)
  let mode_by_path : Map[String, String] = {}
  for op in ops {
    let (raw_path, mode) = op
    mode_by_path[normalize_update_index_path(raw_path)] = mode
  }
  let updated : Array[@bitlib.IndexEntry] = []
  for entry in entries {
    match mode_by_path.get(entry.path) {
      Some(mode) =>
        if update_index_is_regular_file_mode(entry.mode) {
          let target_mode = if mode == "+x" { 0o100755 } else { 0o100644 }
          updated.push(
            @bitlib.IndexEntry::new(
              entry.path,
              entry.id,
              target_mode,
              entry.size,
              mtime_sec=entry.mtime_sec,
              mtime_nsec=entry.mtime_nsec,
              intent_to_add=entry.intent_to_add,
              dev=entry.dev,
              ino=entry.ino,
              uid=entry.uid,
              gid=entry.gid,
            ),
          )
        } else {
          updated.push(entry)
        }
      None => updated.push(entry)
    }
  }
  @bitlib.write_index_entries(fs, git_dir, updated)
  if verbose {
    for op in ops {
      let (raw_path, mode) = op
      let path = normalize_update_index_path(raw_path)
      print_line("add '" + path + "'")
      print_line("chmod " + mode + " '" + path + "'")
    }
  }
}

///|
fn update_index_is_regular_file_mode(mode : Int) -> Bool {
  mode == 0o100644 || mode == 0o100755
}

///|
fn update_index_is_gitlink_mode(mode : Int) -> Bool {
  mode == 0o160000
}

///|
fn update_index_entries_equal(
  left : Array[@bitlib.IndexEntry],
  right : Array[@bitlib.IndexEntry],
) -> Bool {
  if left.length() != right.length() {
    return false
  }
  for i in 0..<left.length() {
    let a = left[i]
    let b = right[i]
    if a.path != b.path ||
      a.id != b.id ||
      a.mode != b.mode ||
      a.size != b.size ||
      a.mtime_sec != b.mtime_sec ||
      a.mtime_nsec != b.mtime_nsec ||
      a.intent_to_add != b.intent_to_add ||
      a.dev != b.dev ||
      a.ino != b.ino ||
      a.uid != b.uid ||
      a.gid != b.gid {
      return false
    }
  }
  true
}

///|
fn update_index_read_index_mtime(git_dir : String) -> (Int, Int)? {
  match @bitio.lstat_entry_meta(git_dir + "/index") {
    Some(meta) =>
      match (meta.mtime_sec, meta.mtime_nsec) {
        (Some(sec), Some(nsec)) => Some((sec, nsec))
        _ => None
      }
    None => None
  }
}

///|
fn update_index_entry_is_racy(
  entry : @bitlib.IndexEntry,
  index_mtime : (Int, Int)?,
) -> Bool {
  match index_mtime {
    Some((sec, nsec)) =>
      (entry.mtime_sec != 0 || entry.mtime_nsec != 0) &&
      entry.mtime_sec == sec &&
      entry.mtime_nsec == nsec
    None => false
  }
}

///|
fn update_index_entry_stat_matches(
  entry : @bitlib.IndexEntry,
  meta : @bitio.WorktreeEntryMeta,
) -> Bool {
  match (meta.size, meta.mtime_sec, meta.mtime_nsec) {
    (Some(sz), Some(ms), Some(mn)) =>
      sz == entry.size &&
      (entry.mtime_sec != 0 || entry.mtime_nsec != 0) &&
      ms == entry.mtime_sec &&
      mn == entry.mtime_nsec &&
      meta.mode == entry.mode
    _ => false
  }
}

///|
async fn update_index_worktree_matches_entry(
  fs : OsFs,
  root : String,
  git_dir : String,
  path : String,
  entry : @bitlib.IndexEntry,
  meta : @bitio.WorktreeEntryMeta,
) -> Bool raise Error {
  let abs_path = update_index_join_root(root, path)
  match meta.kind {
    @bitio.WorktreeKindMeta::Regular => {
      let content = fs.read_file(abs_path)
      let attrs = @bitlib.resolve_eol_attrs(fs, root, path)
      let autocrlf = @bitlib.read_autocrlf_setting(fs, git_dir)
      let normalized = @bitlib.clean_for_storage(content, attrs, autocrlf)
      @bitcore.hash_blob(normalized) == entry.id
    }
    @bitio.WorktreeKindMeta::Symlink =>
      match @bitio.read_symlink_target_path(abs_path) {
        Some(target) => @bitcore.hash_blob(@utf8.encode(target)) == entry.id
        None => false
      }
  }
}

///|
fn update_index_preserve_existing_symlink_modes(
  before : Array[@bitlib.IndexEntry],
  after : Array[@bitlib.IndexEntry],
) -> Array[@bitlib.IndexEntry] {
  let previous_modes : Map[String, Int] = {}
  for entry in before {
    previous_modes[normalize_update_index_path(entry.path) catch {
      _ => entry.path
    }] = entry.mode
  }
  let preserved : Array[@bitlib.IndexEntry] = []
  for entry in after {
    let normalized_path = normalize_update_index_path(entry.path) catch {
      _ => entry.path
    }
    match previous_modes.get(normalized_path) {
      Some(mode) if mode == 0o120000 && entry.mode != 0o120000 =>
        preserved.push(
          @bitlib.IndexEntry::new(
            entry.path,
            entry.id,
            mode,
            entry.size,
            mtime_sec=entry.mtime_sec,
            mtime_nsec=entry.mtime_nsec,
            intent_to_add=entry.intent_to_add,
            dev=entry.dev,
            ino=entry.ino,
            uid=entry.uid,
            gid=entry.gid,
          ),
        )
      _ => preserved.push(entry)
    }
  }
  preserved
}

///|
fn update_index_read_gitlink_entry(
  fs : OsFs,
  root : String,
  path : String,
) -> @bitlib.IndexEntry? raise Error {
  let sub_path = update_index_join_root(root, path)
  let sub_git = sub_path + "/.git"
  let sub_git_dir = if fs.is_file(sub_git) {
    @bitlib.resolve_gitdir(fs, sub_git)
  } else if fs.is_dir(sub_git) {
    sub_git
  } else {
    return None
  }
  match @bitlib.resolve_head_commit(fs, sub_git_dir) {
    Some(id) => Some(@bitlib.IndexEntry::new(path, id, 0o160000, 0))
    None => None
  }
}

///|
fn update_index_gitlink_is_modified(
  fs : OsFs,
  root : String,
  path : String,
  expected_id : @bitcore.ObjectId,
) -> Bool raise Error {
  let sub_path = update_index_join_root(root, path)
  let sub_git = sub_path + "/.git"
  let sub_git_dir = if fs.is_file(sub_git) {
    @bitlib.resolve_gitdir(fs, sub_git)
  } else if fs.is_dir(sub_git) {
    sub_git
  } else {
    return true
  }
  match @bitlib.resolve_head_commit(fs, sub_git_dir) {
    Some(id) => id != expected_id
    None => true
  }
}

///|
fn update_index_join_root(root : String, path : String) -> String {
  if path.has_prefix("/") {
    path
  } else {
    root + "/" + path
  }
}

///|
fn update_index_write_entries_preserving_flags(
  fs : OsFs,
  git_dir : String,
  entries : Array[@bitlib.IndexEntry],
) -> Unit raise Error {
  let skip_worktree_paths = @bitlib.read_skip_worktree_paths(fs, git_dir)
  let assume_unchanged_paths = @bitlib.read_assume_unchanged_paths(fs, git_dir)
  @bitlib.write_index_entries_with_flags(
    fs, git_dir, entries, skip_worktree_paths, assume_unchanged_paths,
  )
}

///|
async fn update_index_stage_paths(
  fs : OsFs,
  root : String,
  git_dir : String,
  add_paths : Array[String],
) -> Unit raise Error {
  if add_paths.length() == 0 {
    return
  }
  let existing_entries = @bitlib.read_index_entries(fs, git_dir)
  let gitlink_updates : Array[@bitlib.IndexEntry] = []
  let regular_paths : Array[String] = []
  for path in add_paths {
    match update_index_read_gitlink_entry(fs, root, path) {
      Some(entry) => gitlink_updates.push(entry)
      None => regular_paths.push(path)
    }
  }
  let add_set : Map[String, Bool] = {}
  for p in add_paths {
    add_set[normalize_update_index_path(p)] = true
  }
  let filtered_entries : Array[@bitlib.IndexEntry] = []
  for e in existing_entries {
    if not(add_set.contains(normalize_update_index_path(e.path))) {
      filtered_entries.push(e)
    }
  }
  update_index_write_entries_preserving_flags(fs, git_dir, filtered_entries)
  if regular_paths.length() > 0 {
    @bitlib.add_paths_async(fs, fs, root, regular_paths)
  }
  let staged_entries = update_index_preserve_existing_symlink_modes(
    existing_entries,
    dedupe_index_entries_by_path(@bitlib.read_index_entries(fs, git_dir)),
  )
  let merged_entries : Array[@bitlib.IndexEntry] = []
  let gitlink_paths : Map[String, @bitlib.IndexEntry] = {}
  for entry in gitlink_updates {
    gitlink_paths[normalize_update_index_path(entry.path)] = entry
  }
  for entry in staged_entries {
    let normalized_path = normalize_update_index_path(entry.path)
    match gitlink_paths.get(normalized_path) {
      Some(gitlink_entry) => {
        merged_entries.push(gitlink_entry)
        gitlink_paths.remove(normalized_path)
      }
      None => merged_entries.push(entry)
    }
  }
  for item in gitlink_paths.to_array() {
    let (_, entry) = item
    merged_entries.push(entry)
  }
  let normalized_entries = dedupe_index_entries_by_path(merged_entries)
  update_index_write_entries_preserving_flags(fs, git_dir, normalized_entries)
}

///|
fn update_index_remove_paths(
  fs : OsFs,
  git_dir : String,
  remove_paths : Array[String],
) -> Unit raise Error {
  if remove_paths.length() == 0 {
    return
  }
  let entries = @bitlib.read_index_entries(fs, git_dir)
  let remove_set : Map[String, Bool] = {}
  for p in remove_paths {
    remove_set[normalize_update_index_path(p)] = true
  }
  let filtered : Array[@bitlib.IndexEntry] = []
  for e in entries {
    if not(remove_set.contains(normalize_update_index_path(e.path))) {
      filtered.push(e)
    }
  }
  update_index_write_entries_preserving_flags(fs, git_dir, filtered)
}

///|
async fn handle_update_index_paths(
  fs : OsFs,
  root : String,
  git_dir : String,
  raw_paths : Array[String],
  add_requested : Bool,
  remove_requested : Bool,
  force_remove : Bool,
  ignore_missing : Bool,
  quiet : Bool,
) -> Unit raise Error {
  let existing_entries = @bitlib.read_index_entries(fs, git_dir)
  let tracked : Map[String, Bool] = {}
  for entry in existing_entries {
    tracked[normalize_update_index_path(entry.path)] = true
  }
  let add_paths : Array[String] = []
  let remove_paths : Array[String] = []
  let errors : Array[String] = []
  for path in raw_paths {
    let normalized_path = normalize_update_index_path(path)
    let full_path = update_index_join_root(root, normalized_path)
    let exists = fs.is_file(full_path) ||
      update_index_read_gitlink_entry(fs, root, normalized_path) is Some(_)
    let tracked_path = tracked.contains(normalized_path)
    if force_remove || (remove_requested && (tracked_path || not(exists))) {
      remove_paths.push(normalized_path)
    } else if exists {
      if add_requested || tracked_path {
        add_paths.push(normalized_path)
      } else {
        errors.push(normalized_path)
      }
    } else if ignore_missing {
      ()
    } else {
      errors.push(normalized_path)
    }
  }
  if errors.length() > 0 {
    if not(quiet) {
      for path in errors {
        eprint_line("error: " + path + ": does not exist")
      }
    }
    @sys.exit(1)
  }
  update_index_stage_paths(fs, root, git_dir, add_paths)
  update_index_remove_paths(fs, git_dir, remove_paths)
}

///|
async fn handle_update_index_refresh(
  fs : OsFs,
  root : String,
  git_dir : String,
  raw_paths : Array[String],
  ignore_missing : Bool,
  allow_unmerged : Bool,
  ignore_submodules : Bool,
  quiet : Bool,
) -> Unit raise Error {
  let stage_entries = @bitlib.read_index_stage_entries(fs, git_dir)
  let entries = @bitlib.read_index_entries(fs, git_dir)
  let index_mtime = update_index_read_index_mtime(git_dir)
  let requested : Map[String, Bool] = {}
  for path in raw_paths {
    requested[normalize_update_index_path(path)] = true
  }
  let status = @bitlib.status(fs, root)
  let modified : Map[String, Bool] = {}
  let deleted : Map[String, Bool] = {}
  for path in status.unstaged_modified {
    modified[path] = true
  }
  for path in status.unstaged_deleted {
    deleted[path] = true
  }
  let unmerged_paths = @bitlib.read_unmerged_paths(fs, git_dir)
  if not(allow_unmerged) {
    let selected_unmerged_paths : Map[String, Bool] = {}
    for item in stage_entries {
      let normalized_path = normalize_update_index_path(item.entry.path)
      if item.stage != 0 &&
        (requested.length() == 0 || requested.contains(normalized_path)) {
        selected_unmerged_paths[normalized_path] = true
      }
    }
    if selected_unmerged_paths.length() > 0 {
      if not(quiet) {
        for item in selected_unmerged_paths.to_array() {
          let (path, _) = item
          print_line(path)
        }
      }
      @sys.exit(1)
    }
  }
  let refreshed : Array[@bitlib.IndexEntry] = []
  let preserved_unmerged_stage_entries : Array[@bitlib.IndexStageEntry] = []
  for item in stage_entries {
    let normalized_path = normalize_update_index_path(item.entry.path)
    if item.stage != 0 &&
      (requested.length() == 0 || requested.contains(normalized_path)) {
      preserved_unmerged_stage_entries.push(item)
    }
  }
  let mut has_error = false
  let mut force_write = false
  for entry in entries {
    let normalized_path = normalize_update_index_path(entry.path)
    if requested.length() > 0 && not(requested.contains(normalized_path)) {
      refreshed.push(entry)
      continue
    }
    if unmerged_paths.contains(normalized_path) {
      continue
    }
    if update_index_is_gitlink_mode(entry.mode) {
      refreshed.push(entry)
      if ignore_submodules {
        continue
      }
      if update_index_gitlink_is_modified(fs, root, normalized_path, entry.id) {
        has_error = true
        if not(quiet) {
          print_line(normalized_path)
        }
      }
      continue
    }
    if deleted.contains(normalized_path) {
      refreshed.push(entry)
      if not(ignore_missing) {
        has_error = true
        if not(quiet) {
          print_line(normalized_path)
        }
      }
      continue
    }
    if modified.contains(normalized_path) {
      refreshed.push(entry)
      has_error = true
      if not(quiet) {
        print_line(normalized_path)
      }
      continue
    }
    let abs_path = update_index_join_root(root, normalized_path)
    match @bitio.worktree_entry_meta(fs, abs_path) {
      Some(meta) => {
        if update_index_entry_stat_matches(entry, meta) &&
          update_index_entry_is_racy(entry, index_mtime) {
          if update_index_worktree_matches_entry(
              fs, root, git_dir, normalized_path, entry, meta,
            ) {
            refreshed.push(entry)
            force_write = true
          } else {
            refreshed.push(entry)
            has_error = true
            if not(quiet) {
              print_line(normalized_path)
            }
          }
          continue
        }
        let (mtime_sec, mtime_nsec) = meta.mtime()
        refreshed.push(
          @bitlib.IndexEntry::new(
            entry.path,
            entry.id,
            entry.mode,
            meta.size.unwrap_or(entry.size),
            mtime_sec~,
            mtime_nsec~,
            intent_to_add=entry.intent_to_add,
            dev=meta.dev.unwrap_or(entry.dev),
            ino=meta.ino.unwrap_or(entry.ino),
            uid=meta.uid.unwrap_or(entry.uid),
            gid=meta.gid.unwrap_or(entry.gid),
          ),
        )
      }
      None => {
        refreshed.push(entry)
        if not(ignore_missing) {
          has_error = true
          if not(quiet) {
            print_line(normalized_path)
          }
        }
      }
    }
  }
  if preserved_unmerged_stage_entries.length() > 0 {
    let merged_stage_entries : Array[@bitlib.IndexStageEntry] = []
    for entry in refreshed {
      merged_stage_entries.push(@bitlib.IndexStageEntry::new(entry, 0))
    }
    merged_stage_entries.append(preserved_unmerged_stage_entries)
    @bitlib.write_index_stage_entries(fs, git_dir, merged_stage_entries)
  } else if force_write || not(update_index_entries_equal(entries, refreshed)) {
    update_index_write_entries_preserving_flags(fs, git_dir, refreshed)
  }
  if has_error {
    @sys.exit(1)
  }
}

///|
async fn handle_update_index_again(
  fs : OsFs,
  root : String,
  git_dir : String,
  raw_paths : Array[String],
  remove_missing : Bool,
) -> Unit raise Error {
  let effective_raw_paths : Array[String] = []
  if raw_paths.length() == 0 {
    let cwd_rel = add_repo_relative_cwd(root)
    if cwd_rel.length() > 0 {
      effective_raw_paths.push(".")
    }
  } else {
    effective_raw_paths.append(raw_paths)
  }
  let requested_paths = add_collect_update_requested_paths(
    fs, root, effective_raw_paths,
  )
  let status = @bitlib.status(fs, root)
  let requested : Map[String, Bool] = {}
  for path in requested_paths {
    requested[path] = true
  }
  let modified_paths : Array[String] = []
  let deleted_paths : Array[String] = []
  for path in status.unstaged_modified {
    if requested.contains(path) {
      modified_paths.push(path)
    }
  }
  for path in status.unstaged_deleted {
    if requested.contains(path) {
      deleted_paths.push(path)
    }
  }
  if deleted_paths.length() > 0 && not(remove_missing) {
    @sys.exit(1)
  }
  if modified_paths.length() > 0 {
    let existing_entries = @bitlib.read_index_entries(fs, git_dir)
    let add_set : Map[String, Bool] = {}
    for path in modified_paths {
      add_set[path] = true
    }
    let filtered_entries : Array[@bitlib.IndexEntry] = []
    for entry in existing_entries {
      if not(add_set.contains(normalize_update_index_path(entry.path))) {
        filtered_entries.push(entry)
      }
    }
    @bitlib.write_index_entries(fs, git_dir, filtered_entries)
    @bitlib.add_paths_async(fs, fs, root, modified_paths)
  }
  if deleted_paths.length() > 0 {
    let entries = @bitlib.read_index_entries(fs, git_dir)
    let deleted_set : Map[String, Bool] = {}
    for path in deleted_paths {
      deleted_set[path] = true
    }
    let filtered : Array[@bitlib.IndexEntry] = []
    for entry in entries {
      if not(deleted_set.contains(normalize_update_index_path(entry.path))) {
        filtered.push(entry)
      }
    }
    @bitlib.write_index_entries(fs, git_dir, filtered)
  }
}

///|
