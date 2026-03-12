///| Pack handlers: rev-list, verify-pack, unpack-objects, bundle

///|
async fn delegate_rev_list_to_real_git(
  args : Array[String],
  cwd : String,
) -> Unit {
  let argv : Array[String] = ["rev-list"]
  for arg in args {
    argv.push(arg)
  }
  let code = @process.run(
    resolve_real_git_for_dispatch(),
    argv,
    inherit_env=true,
    cwd~,
    stdin=@stdio.stdin,
    stdout=@stdio.stdout,
    stderr=@stdio.stderr,
  )
  @sys.exit(code)
}

///|
fn rev_list_requires_real_git(args : Array[String]) -> Bool {
  for arg in args {
    if arg == "--cherry-pick" || arg == "--cherry-mark" || arg == "--cherry" {
      return true
    }
  }
  false
}

///|
fn rev_list_config_get(
  git_dir : String,
  dotted_key : String,
  section : String,
  key : String,
) -> String? {
  match get_config_override(dotted_key) {
    Some(value) => {
      let trimmed = trim_string(value)
      if trimmed.length() > 0 {
        Some(trimmed)
      } else {
        None
      }
    }
    None => bit_config_get(git_dir, section, key)
  }
}

///|
fn rev_list_resolve_output_encoding(git_dir : String) -> String {
  match
    rev_list_config_get(
      git_dir, "i18n.logOutputEncoding", "i18n", "logOutputEncoding",
    ) {
    Some(value) => value
    None =>
      rev_list_config_get(
        git_dir, "i18n.commitEncoding", "i18n", "commitEncoding",
      ).unwrap_or("UTF-8")
  }
}

///|
async fn rev_list_write_text(
  text : String,
  output_encoding : String,
) -> Unit raise Error {
  let encoded = reset_convert_encoding(
    @utf8.encode(text),
    "UTF-8",
    output_encoding,
  )
  @stdio.stdout.write(encoded)
}

///|
async fn handle_rev_list(args : Array[String]) -> Unit raise Error {
  let cwd = @env.current_dir().unwrap_or(".")
  if rev_list_requires_real_git(args) {
    delegate_rev_list_to_real_git(args, cwd)
    return
  }
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut max_count : Int? = None
  let mut skip_count = 0
  let mut count_only = false
  let mut objects = false
  let mut indexed_objects = false
  let mut indexed_objects_negated = false
  let mut quiet = false
  let mut reverse = false
  let mut first_parent = false
  let mut all = false
  let mut stdin = false
  let mut test_bitmap = false
  let mut use_bitmap = false
  let mut no_object_names = false
  let mut format : String? = None
  let mut pretty_color_cli_mode : String? = None
  let refs : Array[String] = []
  let excludes : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "-n" | "--max-count" if i + 1 < args.length() => {
        max_count = Some(rev_list_parse_int_or_die(args[i + 1]))
        i += 2
        continue
      }
      "--count" => count_only = true
      "--objects" | "--objects-edge" => objects = true
      "--indexed-objects" => indexed_objects = true
      "--quiet" | "-q" => quiet = true
      "--reverse" => reverse = true
      "--ancestry-path" => () // Ignored for now
      "--first-parent" => first_parent = true
      "--all" => all = true
      "--stdin" => stdin = true
      "--test-bitmap" => test_bitmap = true
      "--use-bitmap-index" => use_bitmap = true
      "--no-use-bitmap-index" => ()
      "--no-object-names" => no_object_names = true
      "--object-names" => no_object_names = false
      "--color" | "--color=always" => pretty_color_cli_mode = Some("always")
      "--color=auto" => pretty_color_cli_mode = Some("auto")
      "--no-color" | "--color=never" => pretty_color_cli_mode = Some("never")
      _ if arg.has_prefix("--format=") =>
        format = Some(String::unsafe_substring(arg, start=9, end=arg.length()))
      "--skip" if i + 1 < args.length() => {
        skip_count = rev_list_parse_int_or_die(args[i + 1])
        i += 2
        continue
      }
      "--skip" => {
        eprint_line("fatal: option '--skip' requires a value")
        @sys.exit(128)
      }
      "--not" => {
        // Next refs are excludes until another --not
        i += 1
        while i < args.length() {
          let next = args[i]
          if next == "--not" {
            break
          }
          if next == "--indexed-objects" {
            indexed_objects = true
            indexed_objects_negated = true
            i += 1
            continue
          }
          if not(next.has_prefix("-")) {
            excludes.push(next)
          }
          i += 1
        }
        continue
      }
      _ if arg.has_prefix("--max-count=") => {
        let val = String::unsafe_substring(arg, start=12, end=arg.length())
        max_count = Some(rev_list_parse_int_or_die(val))
      }
      _ if arg.has_prefix("--skip=") => {
        let val = String::unsafe_substring(arg, start=7, end=arg.length())
        skip_count = rev_list_parse_int_or_die(val)
      }
      _ if arg.has_prefix("-n") && arg.length() > 2 => {
        let val = String::unsafe_substring(arg, start=2, end=arg.length())
        max_count = Some(rev_list_parse_int_or_die(val))
      }
      _ if rev_list_is_short_max_count_arg(arg) => {
        let val = String::unsafe_substring(arg, start=1, end=arg.length())
        max_count = Some(rev_list_parse_int_or_die(val))
      }
      _ if rev_list_is_long_numeric_option(arg) => {
        eprint_line("fatal: unrecognized argument: " + arg)
        @sys.exit(128)
      }
      _ if arg.has_prefix("^") =>
        excludes.push(String::unsafe_substring(arg, start=1, end=arg.length()))
      _ if not(arg.has_prefix("-")) => refs.push(arg)
      _ if arg.has_prefix("-") => warn_unimplemented_arg("rev-list", arg)
      _ => ()
    }
    i += 1
  }
  // Read from stdin if requested
  if stdin {
    let input = decode_bytes(read_all_stdin())
    for line_view in input.split("\n") {
      let line = trim_string(line_view.to_string())
      if line.length() > 0 && not(line.has_prefix("#")) {
        if line.has_prefix("^") {
          excludes.push(
            String::unsafe_substring(line, start=1, end=line.length()),
          )
        } else {
          refs.push(line)
        }
      }
    }
  }
  // If --all, add all refs
  if all {
    let all_refs = @bitrepo.show_ref(fs, git_dir)
    for item in all_refs {
      let (name, _) = item
      refs.push(name)
    }
  }
  // If no refs specified, default to HEAD
  if refs.length() == 0 && not(indexed_objects) {
    refs.push("HEAD")
  }
  // Handle --test-bitmap
  if test_bitmap {
    rev_list_test_bitmap(fs, git_dir)
    return
  }
  // Resolve starting commits
  let start_ids : Array[@bitcore.ObjectId] = []
  for spec in refs {
    match @bitrepo.rev_parse(fs, git_dir, spec) {
      Some(id) => start_ids.push(id)
      None => ()
    }
  }
  // Resolve exclude commits
  let exclude_ids : Map[String, Bool] = {}
  for spec in excludes {
    match @bitrepo.rev_parse(fs, git_dir, spec) {
      Some(id) =>
        // Walk the exclude commit and all its ancestors
        walk_commits_to_map(fs, git_dir, id, exclude_ids)
      None => ()
    }
  }
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  let visited : Map[String, Bool] = {}
  let result : Array[@bitcore.ObjectId] = []
  let limit = rev_list_collection_limit(skip_count, max_count)
  // BFS/DFS traversal
  let queue : Array[@bitcore.ObjectId] = []
  for id in start_ids {
    queue.push(id)
  }
  while queue.length() > 0 && result.length() < limit {
    let id = queue.unsafe_pop()
    let hex = id.to_hex()
    if visited.contains(hex) || exclude_ids.contains(hex) {
      continue
    }
    visited[hex] = true
    result.push(id)
    // Get commit and add parents
    match db.get(fs, id) {
      Some(obj) if obj.obj_type == @bitcore.ObjectType::Commit => {
        let info = @bitcore.parse_commit(obj.data)
        if first_parent && info.parents.length() > 0 {
          if not(visited.contains(info.parents[0].to_hex())) {
            queue.push(info.parents[0])
          }
        } else {
          for parent in info.parents {
            if not(visited.contains(parent.to_hex())) {
              queue.push(parent)
            }
          }
        }
      }
      _ => ()
    }
  }
  // Apply reverse if requested
  if reverse {
    result.rev_in_place()
  }
  let result_window = rev_list_window(result.length(), skip_count, max_count)
  let sliced_result : Array[@bitcore.ObjectId] = []
  let mut result_idx = result_window.0
  while result_idx < result_window.1 {
    sliced_result.push(result[result_idx])
    result_idx += 1
  }
  let object_ids : Array[(@bitcore.ObjectId, String)] = []
  let indexed_path_ids : Map[String, String] = {}
  if objects {
    let object_seen : Map[String, Bool] = {}
    let indexed_visible_objects = if indexed_objects {
      let index_entries = @bitlib.read_index_entries(fs, git_dir) catch {
        _ => []
      }
      let result = rev_list_collect_index_objects(
        db, fs, git_dir, index_entries,
      )
      for item in result.1.to_array() {
        indexed_path_ids[item.0] = item.1
      }
      result.0
    } else {
      []
    }
    for id in sliced_result {
      object_ids.push((id, ""))
      match db.get(fs, id) {
        Some(obj) if obj.obj_type == @bitcore.ObjectType::Commit => {
          let info = @bitcore.parse_commit(obj.data)
          if indexed_objects_negated {
            collect_tree_objects_excluding_index(
              db,
              fs,
              info.tree,
              object_ids,
              object_seen,
              indexed_path_ids,
            )
          } else {
            collect_tree_objects(db, fs, info.tree, object_ids, object_seen)
          }
        }
        _ => ()
      }
    }
    if indexed_objects && not(indexed_objects_negated) {
      for item in indexed_visible_objects {
        let hex = item.0.to_hex()
        if not(object_seen.contains(hex)) {
          object_seen[hex] = true
          object_ids.push(item)
        }
      }
    }
  }
  // Output
  if count_only {
    print_line(sliced_result.length().to_string())
    return
  }
  if quiet {
    return
  }
  // Output commits
  match format {
    Some(raw_fmt) => {
      // Parse tformat:/format: prefix
      let (fmt, use_newline_sep) = if raw_fmt.has_prefix("tformat:") {
        (String::unsafe_substring(raw_fmt, start=8, end=raw_fmt.length()), true)
      } else if raw_fmt.has_prefix("format:") {
        (
          String::unsafe_substring(raw_fmt, start=7, end=raw_fmt.length()),
          false,
        )
      } else {
        (raw_fmt, true)
      }
      let pretty_color_enabled = if fmt.contains("%C") {
        log_resolve_pretty_color_enabled(
          git_dir,
          pretty_color_cli_mode,
          log_stdout_is_tty(),
        )
      } else {
        false
      }
      let ref_names : Map[String, Array[String]] = {}
      let output_encoding = rev_list_resolve_output_encoding(git_dir)
      for idx, id in sliced_result {
        // Print commit header line
        rev_list_write_text("commit " + id.to_hex() + "\n", output_encoding)
        // Read commit data and format
        match db.get(fs, id) {
          Some(obj) if obj.obj_type == @bitcore.ObjectType::Commit => {
            let info = @bitcore.parse_commit(obj.data)
            let fdata = parse_commit_format_data(
              id,
              obj.data,
              info.tree,
              info.parents,
              ref_names,
              pretty_color_enabled~,
            )
            let formatted = format_commit_string(fmt, fdata)
            rev_list_write_text(formatted, output_encoding)
            if use_newline_sep {
              rev_list_write_text("\n", output_encoding)
            } else if idx < sliced_result.length() - 1 {
              rev_list_write_text("\n", output_encoding)
            }
          }
          _ => ()
        }
      }
    }
    None =>
      for id in sliced_result {
        print_line(id.to_hex())
      }
  }
  // Output objects (trees, blobs) if --objects
  if objects {
    let commit_set : Map[String, Bool] = {}
    for r in sliced_result {
      commit_set[r.to_hex()] = true
    }
    for item in object_ids {
      let (id, path) = item
      let hex = id.to_hex()
      if not(commit_set.contains(hex)) {
        if no_object_names || use_bitmap || path.length() == 0 {
          print_line(hex)
        } else {
          print_line(hex + " " + path)
        }
      }
    }
  }
}

///|
fn rev_list_is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn rev_list_is_short_max_count_arg(arg : String) -> Bool {
  arg.length() > 1 &&
  arg.get_char(0).unwrap() == '-' &&
  not(arg.has_prefix("--")) &&
  rev_list_is_digit(arg.get_char(1).unwrap())
}

///|
fn rev_list_is_long_numeric_option(arg : String) -> Bool {
  arg.length() > 2 &&
  arg.has_prefix("--") &&
  rev_list_is_digit(arg.get_char(2).unwrap())
}

///|
async fn rev_list_parse_int_or_die(value : String) -> Int raise Error {
  @strconv.parse_int(value) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => {
      eprint_line("fatal: not an integer: " + value)
      @sys.exit(128)
      0
    }
  }
}

///|
fn rev_list_normalize_skip(skip_count : Int) -> Int {
  if skip_count < 0 {
    0
  } else {
    skip_count
  }
}

///|
fn rev_list_normalize_max_count(max_count : Int?) -> Int? {
  match max_count {
    Some(count) if count >= 0 => Some(count)
    _ => None
  }
}

///|
fn rev_list_collection_limit(skip_count : Int, max_count : Int?) -> Int {
  let normalized_skip = rev_list_normalize_skip(skip_count)
  match rev_list_normalize_max_count(max_count) {
    Some(count) => normalized_skip + count
    None => 2147483647
  }
}

///|
fn rev_list_window(
  length : Int,
  skip_count : Int,
  max_count : Int?,
) -> (Int, Int) {
  let normalized_skip = rev_list_normalize_skip(skip_count)
  let start = if normalized_skip > length { length } else { normalized_skip }
  match rev_list_normalize_max_count(max_count) {
    Some(count) => {
      let end = start + count
      (start, if end > length { length } else { end })
    }
    None => (start, length)
  }
}

///|
fn walk_commits_to_map(
  fs : OsFs,
  git_dir : String,
  start : @bitcore.ObjectId,
  out : Map[String, Bool],
) -> Unit {
  let db = @bitlib.ObjectDb::load(fs, git_dir) catch { _ => return () }
  let queue : Array[@bitcore.ObjectId] = [start]
  while queue.length() > 0 {
    let id = queue.unsafe_pop()
    let hex = id.to_hex()
    if out.contains(hex) {
      continue
    }
    out[hex] = true
    let obj = db.get(fs, id) catch { _ => continue }
    match obj {
      Some(o) if o.obj_type == @bitcore.ObjectType::Commit => {
        let info = @bitcore.parse_commit(o.data) catch { _ => continue }
        for parent in info.parents {
          if not(out.contains(parent.to_hex())) {
            queue.push(parent)
          }
        }
      }
      _ => ()
    }
  }
}

///|
fn collect_tree_objects(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  tree_id : @bitcore.ObjectId,
  out : Array[(@bitcore.ObjectId, String)],
  visited : Map[String, Bool],
  parent_path? : String = "",
) -> Unit {
  let hex = tree_id.to_hex()
  if visited.contains(hex) {
    return ()
  }
  visited[hex] = true
  out.push((tree_id, parent_path))
  let obj = db.get(fs, tree_id) catch { _ => return () }
  match obj {
    Some(o) if o.obj_type == @bitcore.ObjectType::Tree => {
      let entries = @bitcore.parse_tree(o.data) catch { _ => return () }
      for entry in entries {
        let entry_hex = entry.id.to_hex()
        if not(visited.contains(entry_hex)) {
          let entry_path = if parent_path.length() == 0 {
            entry.name
          } else {
            parent_path + "/" + entry.name
          }
          if entry.mode.has_prefix("40") {
            // Directory - recurse
            collect_tree_objects(
              db,
              fs,
              entry.id,
              out,
              visited,
              parent_path=entry_path,
            )
          } else {
            // File or other
            visited[entry_hex] = true
            out.push((entry.id, entry_path))
          }
        }
      }
    }
    _ => ()
  }
}

///|
fn collect_tree_objects_excluding_index(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  tree_id : @bitcore.ObjectId,
  out : Array[(@bitcore.ObjectId, String)],
  visited : Map[String, Bool],
  indexed_path_ids : Map[String, String],
  parent_path? : String = "",
) -> Unit {
  let hex = tree_id.to_hex()
  if visited.contains(hex) {
    return ()
  }
  match indexed_path_ids.get(parent_path) {
    Some(index_hex) if index_hex == hex => return ()
    _ => ()
  }
  if parent_path.length() > 0 {
    visited[hex] = true
    out.push((tree_id, parent_path))
  }
  let obj = db.get(fs, tree_id) catch { _ => return () }
  match obj {
    Some(o) if o.obj_type == @bitcore.ObjectType::Tree => {
      let entries = @bitcore.parse_tree(o.data) catch { _ => return () }
      for entry in entries {
        let entry_path = if parent_path.length() == 0 {
          entry.name
        } else {
          parent_path + "/" + entry.name
        }
        let entry_hex = entry.id.to_hex()
        if entry.mode.has_prefix("40") {
          collect_tree_objects_excluding_index(
            db,
            fs,
            entry.id,
            out,
            visited,
            indexed_path_ids,
            parent_path=entry_path,
          )
        } else {
          match indexed_path_ids.get(entry_path) {
            Some(index_hex) if index_hex == entry_hex => continue
            _ => ()
          }
          if not(visited.contains(entry_hex)) {
            visited[entry_hex] = true
            out.push((entry.id, entry_path))
          }
        }
      }
    }
    _ => ()
  }
}

///|
fn rev_list_collect_index_objects(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  git_dir : String,
  entries : Array[@bitlib.IndexEntry],
) -> (Array[(@bitcore.ObjectId, String)], Map[String, String]) raise Error {
  let visible : Array[(@bitcore.ObjectId, String)] = []
  let unique_ids : Map[String, Bool] = {}
  let path_ids : Map[String, String] = {}
  let index_by_path : Map[String, @bitlib.IndexEntry] = {}
  for entry in entries {
    let hex = entry.id.to_hex()
    if rev_list_is_zero_object_id_hex(hex) {
      continue
    }
    index_by_path[entry.path] = entry
    path_ids[entry.path] = hex
    if not(unique_ids.contains(hex)) {
      unique_ids[hex] = true
      visible.push((entry.id, entry.path))
    }
  }
  let head_id = @bitrepo.rev_parse(fs, git_dir, "HEAD") catch { _ => None }
  match head_id {
    Some(id) => {
      let obj = db.get(fs, id)
      match obj {
        Some(commit_obj) if commit_obj.obj_type == @bitcore.ObjectType::Commit => {
          let info = @bitcore.parse_commit(commit_obj.data)
          let matched_paths : Map[String, Bool] = {}
          ignore(
            rev_list_collect_matching_index_trees(
              db,
              fs,
              info.tree,
              index_by_path,
              matched_paths,
              visible,
              unique_ids,
              path_ids,
            ),
          )
        }
        _ => ()
      }
    }
    None => ()
  }
  (visible, path_ids)
}

///|
fn rev_list_collect_matching_index_trees(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  tree_id : @bitcore.ObjectId,
  index_by_path : Map[String, @bitlib.IndexEntry],
  matched_paths : Map[String, Bool],
  visible : Array[(@bitcore.ObjectId, String)],
  unique_ids : Map[String, Bool],
  path_ids : Map[String, String],
  parent_path? : String = "",
) -> Bool raise Error {
  let obj = db.get(fs, tree_id)
  match obj {
    Some(o) if o.obj_type == @bitcore.ObjectType::Tree => {
      let entries = @bitcore.parse_tree(o.data) catch { _ => return false }
      for entry in entries {
        let entry_path = if parent_path.length() == 0 {
          entry.name
        } else {
          parent_path + "/" + entry.name
        }
        if entry.mode.has_prefix("40") {
          if not(
              rev_list_collect_matching_index_trees(
                db,
                fs,
                entry.id,
                index_by_path,
                matched_paths,
                visible,
                unique_ids,
                path_ids,
                parent_path=entry_path,
              ),
            ) {
            return false
          }
        } else {
          match index_by_path.get(entry_path) {
            Some(index_entry) => {
              if index_entry.id.to_hex() != entry.id.to_hex() {
                return false
              }
              if index_entry.mode != rev_list_tree_mode_to_int(entry.mode) {
                return false
              }
              matched_paths[entry_path] = true
            }
            None => return false
          }
        }
      }
      let hex = tree_id.to_hex()
      path_ids[parent_path] = hex
      if parent_path.length() > 0 && not(unique_ids.contains(hex)) {
        unique_ids[hex] = true
        visible.push((tree_id, parent_path))
      }
      true
    }
    _ => false
  }
}

///|
fn rev_list_tree_mode_to_int(mode : String) -> Int {
  match mode {
    "100644" => 0o100644
    "100755" => 0o100755
    "120000" => 0o120000
    "160000" => 0o160000
    _ => 0
  }
}

///|
fn rev_list_is_zero_object_id_hex(hex : String) -> Bool {
  hex == "0000000000000000000000000000000000000000"
}

///|
async fn rev_list_test_bitmap(fs : OsFs, git_dir : String) -> Unit raise Error {
  let pack_dir = git_dir + "/objects/pack"
  // Find bitmap file: check chain first, then monolithic
  let chain_path = pack_dir + "/multi-pack-index.d/multi-pack-index-chain"
  let mut bitmap_data : Bytes? = None
  let mut midx_data : Bytes? = None
  if fs.is_file(chain_path) {
    // Use topmost layer from chain
    let chain_data = fs.read_file(chain_path) catch { _ => Bytes::new(0) }
    let text = midx_bytes_to_string(chain_data, 0, chain_data.length())
    let mut last_hash = ""
    for raw_line in text.split("\n") {
      let line = raw_line.to_string().trim().to_string()
      if line.length() > 0 {
        last_hash = line
      }
    }
    if last_hash.length() > 0 {
      let inc_dir = pack_dir + "/multi-pack-index.d"
      let bmp_path = inc_dir + "/multi-pack-index-" + last_hash + ".bitmap"
      let bmp_bytes = midx_try_read_file(fs, bmp_path)
      if bmp_bytes is Some(_) {
        bitmap_data = bmp_bytes
      }
      let midx_path = inc_dir + "/multi-pack-index-" + last_hash + ".midx"
      let md = midx_try_read_file(fs, midx_path)
      if md is Some(_) {
        midx_data = md
      }
    }
  }
  if bitmap_data is None {
    // Try monolithic
    let midx_path = pack_dir + "/multi-pack-index"
    let md = midx_try_read_file(fs, midx_path)
    match md {
      Some(md_bytes) =>
        if md_bytes.length() >= 20 {
          midx_data = Some(md_bytes)
          let checksum_hex = midx_checksum_hex(md_bytes)
          if checksum_hex.length() > 0 {
            let bmp_path = pack_dir +
              "/multi-pack-index-" +
              checksum_hex +
              ".bitmap"
            bitmap_data = midx_try_read_file(fs, bmp_path)
          }
        }
      None => ()
    }
  }
  // Fallback: single-pack bitmap (pack-*.bitmap)
  if bitmap_data is None {
    match find_pack_with_bitmap(fs, pack_dir) {
      Some(pack_name) => {
        let stem = (try! pack_name[:pack_name.length() - 5]).to_string()
        let bmp_path = pack_dir + "/" + stem + ".bitmap"
        bitmap_data = midx_try_read_file(fs, bmp_path)
      }
      None => ()
    }
  }
  guard bitmap_data is Some(bmp_bytes) else {
    eprint_line("error: could not find bitmap")
    @sys.exit(1)
    return
  }
  ignore(midx_data)
  // Emit GIT_TRACE2_EVENT for load_midx_revindex
  emit_revindex_trace(fs, "midx")
  // Parse bitmap header
  if bmp_bytes.length() < 32 {
    eprint_line("error: bitmap file too short")
    @sys.exit(1)
    return
  }
  if bmp_bytes[0] != b'B' ||
    bmp_bytes[1] != b'I' ||
    bmp_bytes[2] != b'T' ||
    bmp_bytes[3] != b'M' {
    eprint_line("error: invalid bitmap signature")
    @sys.exit(1)
    return
  }
  // Verify bitmap trailer checksum
  let bmp_body_len = bmp_bytes.length() - 20
  if bmp_body_len < 32 {
    eprint_line("error: bitmap too short for checksum")
    @sys.exit(1)
    return
  }
  let bmp_body = Bytes::from_array(
    FixedArray::makei(bmp_body_len, i => bmp_bytes[i]),
  )
  let bmp_computed = @bitcore.sha1(bmp_body)
  let mut bmp_checksum_ok = true
  for i in 0..<20 {
    if bmp_computed.bytes[i] != bmp_bytes[bmp_body_len + i] {
      bmp_checksum_ok = false
    }
  }
  if not(bmp_checksum_ok) {
    eprint_line("error: bitmap checksum mismatch")
    @sys.exit(1)
    return
  }
  let entry_count = midx_read_u32(bmp_bytes, 8)
  if entry_count <= 0 {
    eprint_line("error: bitmap has no entries")
    @sys.exit(1)
    return
  }
  // Validate bitmap structure: parse type bitmaps and per-commit entries
  let mut bmp_pos = 32
  let mut valid = true
  // Skip 4 type bitmaps
  for _ in 0..<4 {
    if bmp_pos + 8 > bmp_body_len {
      valid = false
      break
    }
    let word_count = midx_read_u32(bmp_bytes, bmp_pos + 4)
    if word_count < 0 {
      valid = false
      break
    }
    bmp_pos = bmp_pos + 4 + 4 + word_count * 8 + 4
  }
  if not(valid) {
    eprint_line("error: bitmap structure invalid")
    @sys.exit(1)
    return
  }
  // Parse per-commit bitmap entries
  for _ in 0..<entry_count {
    if bmp_pos + 6 > bmp_body_len {
      valid = false
      break
    }
    bmp_pos += 6
    if bmp_pos + 8 > bmp_body_len {
      valid = false
      break
    }
    let word_count = midx_read_u32(bmp_bytes, bmp_pos + 4)
    if word_count < 0 {
      valid = false
      break
    }
    bmp_pos = bmp_pos + 4 + 4 + word_count * 8 + 4
  }
  if valid {
    eprint_line("OK!")
  } else {
    eprint_line("mismatch in bitmap results")
    @sys.exit(1)
    return
  }
}

///|
fn emit_revindex_trace(fs : OsFs, kind : String) -> Unit {
  match @sys.get_env_var("GIT_TRACE2_EVENT") {
    Some(path) => {
      let target = path.trim().to_string()
      if target.length() == 0 || target == "1" || target == "2" {
        return
      }
      let existing = match midx_try_read_file(fs, target) {
        Some(data) => midx_bytes_to_string(data, 0, data.length())
        None => ""
      }
      let line = "{\"event\":\"data\",\"category\":\"load_midx_revindex\",\"key\":\"source\",\"value\":\"" +
        kind +
        "\"}"
      let next = if existing.length() == 0 {
        line + "\n"
      } else {
        existing + line + "\n"
      }
      fs.write_string(target, next) catch {
        _ => ()
      }
    }
    None => ()
  }
}

///|
