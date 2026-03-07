///| for-each-ref command implementation

///|
async fn handle_for_each_ref(args : Array[String]) -> Unit raise Error {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  let mut format = "%(objectname) %(objecttype)\t%(refname)"
  let mut count : Int? = None
  let sort_keys : Array[String] = []
  let patterns : Array[String] = []
  let excludes : Array[String] = []
  let points_at : Array[String] = []
  let mut merged : String? = None
  let mut no_merged : String? = None
  let mut contains : String? = None
  let mut no_contains : String? = None
  let mut quote_style = ""
  let mut omit_empty = false
  let mut use_stdin = false
  let mut ignore_case = false
  let mut color_mode = "" // "", "always", "never"
  let mut start_after : String? = None
  let mut include_root_refs = false
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
      "--no-sort" => sort_keys.clear()
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
      "--shell" | "-s" => {
        if quote_style != "" {
          eprint_line("error: more than one quoting style")
          @sys.exit(1)
          return
        }
        quote_style = "shell"
      }
      "--perl" | "-p" => {
        if quote_style != "" {
          eprint_line("error: more than one quoting style")
          @sys.exit(1)
          return
        }
        quote_style = "perl"
      }
      "--python" => {
        if quote_style != "" {
          eprint_line("error: more than one quoting style")
          @sys.exit(1)
          return
        }
        quote_style = "python"
      }
      "--tcl" => {
        if quote_style != "" {
          eprint_line("error: more than one quoting style")
          @sys.exit(1)
          return
        }
        quote_style = "tcl"
      }
      _ if arg.has_prefix("--exclude=") =>
        excludes.push(String::unsafe_substring(arg, start=10, end=arg.length()))
      "--omit-empty" => omit_empty = true
      "--stdin" => use_stdin = true
      "--ignore-case" | "-i" => ignore_case = true
      _ if arg.has_prefix("--contains=") =>
        contains = Some(
          String::unsafe_substring(arg, start=11, end=arg.length()),
        )
      "--contains" =>
        if i + 1 < args.length() {
          i += 1
          contains = Some(args[i])
        }
      _ if arg.has_prefix("--no-contains=") =>
        no_contains = Some(
          String::unsafe_substring(arg, start=14, end=arg.length()),
        )
      "--no-contains" =>
        if i + 1 < args.length() {
          i += 1
          no_contains = Some(args[i])
        }
      _ if arg.has_prefix("--start-after=") =>
        start_after = Some(
          String::unsafe_substring(arg, start=14, end=arg.length()),
        )
      "--include-root-refs" => include_root_refs = true
      "--color" | "--color=always" => color_mode = "always"
      "--color=auto" => color_mode = "auto"
      "--no-color" | "--color=never" => color_mode = "never"
      "--format" =>
        // --format VALUE (space-separated)
        if i + 1 < args.length() {
          i += 1
          format = args[i]
        }
      "--sort" =>
        // --sort VALUE (space-separated)
        if i + 1 < args.length() {
          i += 1
          sort_keys.push(args[i])
        }
      "--count" =>
        if i + 1 < args.length() {
          i += 1
          count = Some(
            @strconv.parse_int(args[i]) catch {
              err if @async.is_cancellation_error(err) => raise err
              _ => 0
            },
          )
        }
      _ if arg.has_prefix("-") => warn_unimplemented_arg("for-each-ref", arg)
      _ => patterns.push(arg)
    }
    i += 1
  }
  // --stdin: read patterns from stdin, fail if extra args
  if use_stdin {
    if patterns.length() > 0 {
      eprint_line("fatal: unknown arguments supplied with --stdin")
      @sys.exit(129)
      return
    }
    let stdin_text = decode_bytes(read_all_stdin())
    for line_view in stdin_text.split("\n") {
      let line = line_view.to_string()
      if line.length() > 0 {
        patterns.push(line)
      }
    }
  }
  // Collect all refs (with broken ref handling)
  let all_refs = for_each_ref_collect_refs(fs, git_dir)
  // If --include-root-refs, add root refs (HEAD, *_HEAD, etc.) excluding pseudo refs
  if include_root_refs {
    for_each_ref_collect_root_refs(fs, git_dir, all_refs)
  }
  // Load ObjectDb once for all filtering (points-at, merged, etc.)
  let filter_db : @bitlib.ObjectDb? = Some(@bitlib.ObjectDb::load(fs, git_dir)) catch {
    _ => None
  }
  // Filter by patterns
  let filtered : Array[(String, @bitcore.ObjectId)] = []
  for item in all_refs {
    let (refname, id) = item
    if patterns.length() > 0 {
      let mut matched = false
      let match_ref = if ignore_case { refname.to_lower() } else { refname }
      for pattern in patterns {
        let match_pat = if ignore_case { pattern.to_lower() } else { pattern }
        if for_each_ref_match_pattern(match_ref, match_pat) {
          matched = true
          break
        }
      }
      if not(matched) {
        continue
      }
    }
    // Filter by --exclude
    if excludes.length() > 0 {
      let mut excluded = false
      for excl in excludes {
        if for_each_ref_match_pattern(refname, excl) {
          excluded = true
          break
        }
      }
      if excluded {
        continue
      }
    }
    // Filter by --points-at
    if points_at.length() > 0 {
      let mut matches_points_at = false
      for target in points_at {
        match @bitrepo.rev_parse(fs, git_dir, target) {
          Some(target_id) => {
            let target_hex = target_id.to_hex()
            if id.to_hex() == target_hex {
              matches_points_at = true
            } else {
              // For tags, check if the deref target matches
              match filter_db {
                Some(fdb) => {
                  let peeled = for_each_ref_peel_to_commit(fs, fdb, id)
                  match peeled {
                    Some(peeled_id) if peeled_id.to_hex() == target_hex =>
                      matches_points_at = true
                    _ => ()
                  }
                }
                None => ()
              }
            }
          }
          _ => ()
        }
      }
      if not(matches_points_at) {
        continue
      }
    }
    filtered.push((refname, id))
  }
  // Filter by --merged / --no-merged / --contains / --no-contains
  if merged is Some(_) ||
    no_merged is Some(_) ||
    contains is Some(_) ||
    no_contains is Some(_) {
    let db_for_filter = match filter_db {
      Some(fdb) => fdb
      None => @bitlib.ObjectDb::load(fs, git_dir)
    }
    let merged_id : @bitcore.ObjectId? = match merged {
      Some(rev) => @bitrepo.rev_parse(fs, git_dir, rev) catch { _ => None }
      None => None
    }
    let no_merged_id : @bitcore.ObjectId? = match no_merged {
      Some(rev) => @bitrepo.rev_parse(fs, git_dir, rev) catch { _ => None }
      None => None
    }
    let contains_id : @bitcore.ObjectId? = match contains {
      Some(rev) => @bitrepo.rev_parse(fs, git_dir, rev) catch { _ => None }
      None => None
    }
    let no_contains_id : @bitcore.ObjectId? = match no_contains {
      Some(rev) => @bitrepo.rev_parse(fs, git_dir, rev) catch { _ => None }
      None => None
    }
    let new_filtered : Array[(String, @bitcore.ObjectId)] = []
    for item in filtered {
      let (_, ref_id) = item
      // Peel to commit
      let commit_id = for_each_ref_peel_to_commit(fs, db_for_filter, ref_id)
      match commit_id {
        None =>
          // Not a committish — excluded by all these filters
          continue
        Some(cid) => {
          // --merged: ref's commit must be ancestor of (or equal to) merged_id
          match merged_id {
            Some(mid) =>
              if not(for_each_ref_is_ancestor(fs, db_for_filter, cid, mid)) {
                continue
              }
            None => ()
          }
          // --no-merged: ref's commit must NOT be ancestor of no_merged_id
          match no_merged_id {
            Some(nmid) =>
              if for_each_ref_is_ancestor(fs, db_for_filter, cid, nmid) {
                continue
              }
            None => ()
          }
          // --contains: ref's commit must have contains_id as ancestor
          match contains_id {
            Some(coid) =>
              if not(for_each_ref_is_ancestor(fs, db_for_filter, coid, cid)) {
                continue
              }
            None => ()
          }
          // --no-contains: ref's commit must NOT have no_contains_id as ancestor
          match no_contains_id {
            Some(ncoid) =>
              if for_each_ref_is_ancestor(fs, db_for_filter, ncoid, cid) {
                continue
              }
            None => ()
          }
          new_filtered.push(item)
        }
      }
    }
    filtered.clear()
    for item in new_filtered {
      filtered.push(item)
    }
  }
  // Sort — last --sort key is primary, first is least significant
  // Use composite comparator: try keys in reverse order (primary first)
  if sort_keys.length() > 0 {
    filtered.sort_by(fn(a, b) {
      // Iterate from last key (most significant) to first
      let mut idx = sort_keys.length() - 1
      while idx >= 0 {
        let key = sort_keys[idx]
        let descending = key.has_prefix("-")
        let sort_field = if descending {
          String::unsafe_substring(key, start=1, end=key.length())
        } else {
          key
        }
        let cmp = for_each_ref_compare(
          fs, git_dir, a, b, sort_field, ignore_case,
        )
        let adjusted = if descending { -cmp } else { cmp }
        if adjusted != 0 {
          return adjusted
        }
        idx -= 1
      }
      // All keys equal — fall back on refname
      if ignore_case {
        lexicographic_compare(a.0.to_lower(), b.0.to_lower())
      } else {
        lexicographic_compare(a.0, b.0)
      }
    })
  } else {
    // Default sort by refname (lexicographic, not shortlex)
    filtered.sort_by(fn(a, b) {
      if ignore_case {
        lexicographic_compare(a.0.to_lower(), b.0.to_lower())
      } else {
        lexicographic_compare(a.0, b.0)
      }
    })
  }
  // Validate --start-after constraints
  match start_after {
    Some(_) => {
      if patterns.length() > 0 {
        eprint_line("fatal: cannot use --start-after with patterns")
        @sys.exit(1)
      }
      if sort_keys.length() > 0 {
        eprint_line("fatal: cannot use --start-after with custom sort options")
        @sys.exit(1)
      }
    }
    None => ()
  }
  // Apply --start-after filter (refs are already sorted by refname)
  match start_after {
    Some(sa) =>
      if sa != "" {
        let mut start_idx = 0
        for idx = 0; idx < filtered.length(); idx = idx + 1 {
          let refname = filtered[idx].0
          if lexicographic_compare(refname, sa) <= 0 {
            start_idx = idx + 1
          } else {
            break
          }
        }
        if start_idx > 0 {
          let new_filtered : Array[(String, @bitcore.ObjectId)] = []
          for idx = start_idx; idx < filtered.length(); idx = idx + 1 {
            new_filtered.push(filtered[idx])
          }
          filtered.clear()
          for item in new_filtered {
            filtered.push(item)
          }
        }
      }
    None => ()
  }
  // Validate format string upfront (before processing any refs)
  for_each_ref_validate_format(format)
  // raw + quoting constraint: %(raw) (not %(raw:size)) is incompatible with --shell/--python/--tcl
  if for_each_ref_format_has_raw_bare(format) &&
    (quote_style == "shell" || quote_style == "python" || quote_style == "tcl") {
    eprint_line(
      "fatal: --format=%(" +
      "raw) is incompatible with --" +
      quote_style +
      " quoting",
    )
    @sys.exit(1)
  }
  // Load object db for object lookups
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  // Pre-compute is-base values if format uses %(is-base:...)
  let is_base_results : Map[String, String] = {}
  let is_base_atoms = for_each_ref_extract_is_base_atoms(format)
  if is_base_atoms.length() > 0 {
    for_each_ref_compute_is_base(
      fs, git_dir, db, filtered, is_base_atoms, is_base_results,
    )
  }
  // Output
  let limit = count.unwrap_or(2147483647)
  let mut output_count = 0
  for item in filtered {
    if output_count >= limit {
      break
    }
    let (refname, id) = item
    let is_base_value = is_base_results.get(refname).unwrap_or("")
    let line_bytes = for_each_ref_format(
      fs, git_dir, db, format, refname, id, quote_style, color_mode, is_base_value,
    )
    if omit_empty && line_bytes.length() == 0 {
      continue
    }
    // Write raw bytes + newline to stdout
    let _ = @stdio.stdout.write_once(
      line_bytes,
      offset=0,
      len=line_bytes.length(),
    )
    let newline : Bytes = b"\n"
    let _ = @stdio.stdout.write_once(newline, offset=0, len=1)
    output_count += 1
  }
}

///|
/// Collect refs with broken/null ref handling.
/// Skips broken refs (empty files, invalid hex) and null OID refs with warnings.
async fn for_each_ref_collect_refs(
  fs : OsFs,
  git_dir : String,
) -> Array[(String, @bitcore.ObjectId)] {
  // Try show_ref first; if it works, filter null OIDs
  let refs = @bitrepo.show_ref(fs, git_dir) catch {
    _ =>
      // show_ref failed (likely broken ref) — collect manually with error handling
      for_each_ref_collect_refs_safe(fs, git_dir)
  }
  let result : Array[(String, @bitcore.ObjectId)] = []
  let zero_hex = "0000000000000000000000000000000000000000"
  for item in refs {
    let (refname, id) = item
    if id.to_hex() == zero_hex {
      eprint_line("warning: ignoring broken ref " + refname)
      continue
    }
    result.push((refname, id))
  }
  result
}

///|
/// Collect root refs (HEAD, *_HEAD, etc.) from .git/ directory.
/// Excludes pseudo refs (FETCH_HEAD, MERGE_HEAD) and dangling symrefs.
async fn for_each_ref_collect_root_refs(
  fs : OsFs,
  git_dir : String,
  out : Array[(String, @bitcore.ObjectId)],
) -> Unit {
  let pseudo_refs : Array[String] = ["FETCH_HEAD", "MERGE_HEAD"]
  let entries = fs.readdir(git_dir) catch { _ => return }
  for entry in entries {
    let name = entry
    // Root ref syntax: all uppercase, hyphens, underscores
    if not(for_each_ref_is_root_ref_syntax(name)) {
      continue
    }
    // Skip pseudo refs (FETCH_HEAD, MERGE_HEAD)
    let mut is_pseudo = false
    for pr in pseudo_refs {
      if name == pr {
        is_pseudo = true
        break
      }
    }
    if is_pseudo {
      continue
    }
    // Check if it's a root ref (HEAD, *_HEAD, or known irregular root refs)
    if not(for_each_ref_is_root_ref(name)) {
      continue
    }
    // Read the ref file
    let path = git_dir + "/" + name
    let content = fs.read_file(path) catch { _ => continue }
    let text = decode_bytes(content).trim(chars=" \t\n\r").to_string()
    if text.has_prefix("ref: ") {
      // Symbolic ref — resolve the target
      let target = String::unsafe_substring(text, start=5, end=text.length())
      // Check if target exists (dangling symref → skip)
      let resolved = @bitlib.resolve_ref(fs, git_dir, target) catch {
        _ => continue
      }
      match resolved {
        Some(id) => out.push((name, id))
        None => continue // dangling
      }
    } else {
      // Direct ref
      let id = @bitcore.ObjectId::from_hex(text) catch { _ => continue }
      out.push((name, id))
    }
  }
}

///|
fn for_each_ref_is_root_ref_syntax(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  for i = 0; i < name.length(); i = i + 1 {
    let c = name[i]
    if not((c >= 'A' && c <= 'Z') || c == '-' || c == '_') {
      return false
    }
  }
  true
}

///|
fn for_each_ref_is_root_ref(name : String) -> Bool {
  // HEAD is a root ref
  if name == "HEAD" {
    return true
  }
  // *_HEAD is a root ref (ORIG_HEAD, CHERRY_PICK_HEAD, etc.)
  if name.has_suffix("_HEAD") {
    return true
  }
  // Known irregular root refs
  let irregular : Array[String] = [
    "AUTO_MERGE", "BISECT_EXPECTED_REV", "NOTES_MERGE_PARTIAL", "NOTES_MERGE_REF",
    "MERGE_AUTOSTASH",
  ]
  for ir in irregular {
    if name == ir {
      return true
    }
  }
  false
}

///|
/// Safe ref collection that skips broken refs with warnings.
async fn for_each_ref_collect_refs_safe(
  fs : OsFs,
  git_dir : String,
) -> Array[(String, @bitcore.ObjectId)] {
  let out : Map[String, @bitcore.ObjectId] = {}
  let refs_dir = git_dir + "/refs"
  if fs.is_dir(refs_dir) {
    for_each_ref_collect_loose_safe(fs, git_dir, refs_dir, "refs", out)
  }
  let packed = git_dir + "/packed-refs"
  if fs.is_file(packed) {
    let data = fs.read_file(packed) catch { _ => Bytes::new(0) }
    if data.length() > 0 {
      let text = decode_bytes(data)
      for line_view in text.split("\n") {
        let line = line_view.to_string()
        if line.length() == 0 || line[0] == '#' || line[0] == '^' {
          continue
        }
        if line.length() >= 41 {
          let hex = String::unsafe_substring(line, start=0, end=40)
          let refname = String::unsafe_substring(
            line,
            start=41,
            end=line.length(),
          )
          let id = @bitcore.ObjectId::from_hex(hex) catch { _ => continue }
          out[refname] = id
        }
      }
    }
  }
  let result : Array[(String, @bitcore.ObjectId)] = []
  for item in out.to_array() {
    let (name, id) = item
    result.push((name, id))
  }
  result.sort_by(fn(a, b) { String::compare(a.0, b.0) })
  result
}

///|
async fn for_each_ref_collect_loose_safe(
  fs : OsFs,
  git_dir : String,
  dir : String,
  prefix : String,
  out : Map[String, @bitcore.ObjectId],
) -> Unit {
  let entries = fs.readdir(dir) catch { _ => return }
  for name in entries {
    let path = dir + "/" + name
    let rel = if prefix == "" { name } else { prefix + "/" + name }
    if fs.is_dir(path) {
      for_each_ref_collect_loose_safe(fs, git_dir, path, rel, out)
    } else if fs.is_file(path) {
      let data = fs.read_file(path) catch { _ => continue }
      let line = decode_bytes(data)
      // Trim trailing newline
      let trimmed = if line.has_suffix("\n") {
        String::unsafe_substring(line, start=0, end=line.length() - 1)
      } else {
        line
      }
      if trimmed.length() == 0 {
        // Empty ref file = broken
        eprint_line("warning: ignoring broken ref " + rel)
        continue
      }
      if trimmed.has_prefix("ref: ") {
        // Symbolic ref — resolve
        let target = String::unsafe_substring(
          trimmed,
          start=5,
          end=trimmed.length(),
        )
        let resolved = @bitlib.resolve_ref(fs, git_dir, target) catch {
          _ => None
        }
        match resolved {
          Some(id) => out[rel] = id
          None => eprint_line("warning: ignoring broken ref " + rel)
        }
      } else {
        let maybe_id : @bitcore.ObjectId? = Some(
          @bitcore.ObjectId::from_hex(trimmed),
        ) catch {
          _ => None
        }
        match maybe_id {
          Some(id) => out[rel] = id
          None => eprint_line("warning: ignoring broken ref " + rel)
        }
      }
    }
  }
}

///|
async fn for_each_ref_validate_format(format : String) -> Unit {
  // Parse format string and validate atoms upfront
  let chars = format.to_array()
  let len = chars.length()
  let mut i = 0
  while i < len {
    if chars[i] == '%' && i + 1 < len && chars[i + 1] == '(' {
      let start = i + 2
      let mut end_pos = start
      while end_pos < len && chars[end_pos] != ')' {
        end_pos = end_pos + 1
      }
      if end_pos < len {
        let atom = String::from_array(
          FixedArray::makei(end_pos - start, fn(j) { chars[start + j] }),
        )
        for_each_ref_validate_atom(atom)
        i = end_pos + 1
      } else {
        i = i + 1
      }
    } else {
      i = i + 1
    }
  }
  // Validate if/then/else/end balance
  for_each_ref_validate_if_then_else(format)
}

///|
async fn for_each_ref_validate_if_then_else(format : String) -> Unit {
  let chars = format.to_array()
  let len = chars.length()
  let atoms : Array[String] = []
  let mut i = 0
  while i < len {
    if chars[i] == '%' && i + 1 < len && chars[i + 1] == '(' {
      let start = i + 2
      let mut end_pos = start
      while end_pos < len && chars[end_pos] != ')' {
        end_pos = end_pos + 1
      }
      if end_pos < len {
        let atom = String::from_array(
          FixedArray::makei(end_pos - start, fn(j) { chars[start + j] }),
        )
        if atom == "if" ||
          atom.has_prefix("if:") ||
          atom == "then" ||
          atom == "else" ||
          atom == "end" ||
          atom.has_prefix("align:") ||
          atom == "align" {
          atoms.push(atom)
        }
        i = end_pos + 1
      } else {
        i = i + 1
      }
    } else {
      i = i + 1
    }
  }
  // Check structure using a stack: "if" and "align" both need %(end)
  if atoms.length() == 0 {
    return
  }
  // Stack entries: "if" or "align", with state tracking for if
  let stack : Array[String] = [] // "if", "if-then", "if-else", "align"
  for atom in atoms {
    if atom == "if" || atom.has_prefix("if:") {
      stack.push("if")
    } else if atom.has_prefix("align:") || atom == "align" {
      stack.push("align")
    } else if atom == "then" {
      if stack.length() == 0 || stack[stack.length() - 1] != "if" {
        if stack.length() > 0 && stack[stack.length() - 1] == "if-then" {
          eprint_line("fatal: format: %%(then) atom used more than once")
        } else if stack.length() > 0 && stack[stack.length() - 1] == "if-else" {
          eprint_line("fatal: format: %%(then) atom used after %%(else)")
        } else {
          eprint_line("fatal: format: %%(then) atom used without a %%(if) atom")
        }
        @sys.exit(1)
      }
      stack[stack.length() - 1] = "if-then"
    } else if atom == "else" {
      if stack.length() == 0 || stack[stack.length() - 1] != "if-then" {
        if stack.length() > 0 && stack[stack.length() - 1] == "if-else" {
          eprint_line("fatal: format: %%(else) atom used more than once")
        } else {
          eprint_line("fatal: format: %%(else) atom used without a %%(if) atom")
        }
        @sys.exit(1)
      }
      stack[stack.length() - 1] = "if-else"
    } else if atom == "end" {
      if stack.length() == 0 {
        eprint_line(
          "fatal: format: %%(end) atom used without corresponding %%(if)/%(align) atom",
        )
        @sys.exit(1)
      }
      let top = stack[stack.length() - 1]
      if top == "if" {
        // %(if) without %(then) before %(end)
        eprint_line("fatal: format: %%(if) atom used without a %%(then) atom")
        @sys.exit(1)
      }
      ignore(stack.pop())
    }
  }
  if stack.length() > 0 {
    let top = stack[stack.length() - 1]
    if top == "if" {
      eprint_line("fatal: format: %%(if) atom used without a %%(then) atom")
    } else if top == "if-then" || top == "if-else" {
      eprint_line(
        "fatal: format: expected %%(end) atom after %%(then) or %%(else)",
      )
    } else {
      eprint_line("fatal: format: expected %%(end) atom")
    }
    @sys.exit(1)
  }
}

///|
fn for_each_ref_format_has_raw_bare(format : String) -> Bool {
  // Check if format contains %(raw) but not %(raw:size)
  let chars = format.to_array()
  let len = chars.length()
  let mut i = 0
  while i < len {
    if chars[i] == '%' && i + 1 < len && chars[i + 1] == '(' {
      let start = i + 2
      let mut end_pos = start
      while end_pos < len && chars[end_pos] != ')' {
        end_pos += 1
      }
      if end_pos < len {
        let atom = String::from_array(
          FixedArray::makei(end_pos - start, fn(j) { chars[start + j] }),
        )
        if atom == "raw" || atom == "*raw" {
          return true
        }
        i = end_pos + 1
      } else {
        i += 1
      }
    } else {
      i += 1
    }
  }
  false
}

///|
async fn for_each_ref_validate_atom(atom : String) -> Unit {
  // Validate describe atom options
  if atom.has_prefix("describe:") {
    let options_str = String::unsafe_substring(atom, start=9, end=atom.length())
    let mut remaining = options_str
    while remaining.length() > 0 {
      let comma_pos = remaining.find(",")
      let (opt, rest) = match comma_pos {
        Some(pos) =>
          (
            String::unsafe_substring(remaining, start=0, end=pos),
            String::unsafe_substring(
              remaining,
              start=pos + 1,
              end=remaining.length(),
            ),
          )
        None => (remaining, "")
      }
      if opt == "tags" ||
        opt.has_prefix("abbrev=") ||
        opt.has_prefix("match=") ||
        opt.has_prefix("exclude=") {
        // valid
        ()
      } else {
        let bad = if rest.length() > 0 { opt + "," + rest } else { opt }
        eprint_line("fatal: unrecognized %(describe) argument: " + bad)
        @sys.exit(1)
      }
      remaining = rest
    }
  }
  // Validate trailers options
  if atom.has_prefix("trailers:") || atom.has_prefix("contents:trailers:") {
    let opts = if atom.has_prefix("contents:trailers:") {
      String::unsafe_substring(atom, start=18, end=atom.length())
    } else {
      String::unsafe_substring(atom, start=9, end=atom.length())
    }
    let mut remaining = opts
    while remaining.length() > 0 {
      let (opt, rest) = for_each_ref_split_trailer_opt(remaining)
      if opt == "only" ||
        opt == "only=yes" ||
        opt == "only=true" ||
        opt == "only=no" ||
        opt == "only=false" ||
        opt == "unfold" ||
        opt == "valueonly" ||
        opt.has_prefix("key=") ||
        opt.has_prefix("separator=") ||
        opt.has_prefix("key_value_separator=") {
        // valid
        ()
      } else if opt == "key" {
        eprint_line("fatal: expected %(trailers:key=<value>)")
        @sys.exit(1)
      } else {
        eprint_line("fatal: unknown %(trailers) argument: " + remaining)
        @sys.exit(1)
      }
      remaining = rest
    }
  }
  // Validate email options using prefix-based greedy parsing (matching git)
  if atom.has_prefix("authoremail:") ||
    atom.has_prefix("committeremail:") ||
    atom.has_prefix("taggeremail:") {
    let colon_pos = match atom.find(":") {
      Some(p) => p
      None => return
    }
    let options_str = String::unsafe_substring(
      atom,
      start=colon_pos + 1,
      end=atom.length(),
    )
    let atom_name = String::unsafe_substring(atom, start=0, end=colon_pos)
    let mut remaining = options_str
    while remaining.length() > 0 {
      if remaining.has_prefix("mailmap") {
        remaining = String::unsafe_substring(
          remaining,
          start=7,
          end=remaining.length(),
        )
      } else if remaining.has_prefix("trim") {
        remaining = String::unsafe_substring(
          remaining,
          start=4,
          end=remaining.length(),
        )
      } else if remaining.has_prefix("localpart") {
        remaining = String::unsafe_substring(
          remaining,
          start=9,
          end=remaining.length(),
        )
      } else {
        eprint_line(
          "fatal: unrecognized %(" + atom_name + ") argument: " + remaining,
        )
        @sys.exit(1)
      }
      // After consuming a valid token, expect comma or end
      if remaining.length() > 0 {
        if remaining.has_prefix(",") {
          remaining = String::unsafe_substring(
            remaining,
            start=1,
            end=remaining.length(),
          )
          // If nothing after comma, report empty arg error
          if remaining.length() == 0 {
            eprint_line(
              "fatal: unrecognized %(" + atom_name + ") argument: " + remaining,
            )
            @sys.exit(1)
          }
        } else {
          // No comma, but not at end → error
          eprint_line(
            "fatal: unrecognized %(" + atom_name + ") argument: " + remaining,
          )
          @sys.exit(1)
        }
      }
    }
  }
  // Validate HEAD
  if atom.has_prefix("HEAD:") {
    eprint_line("fatal: %(HEAD) does not take arguments")
    @sys.exit(1)
  }
  // Validate subject
  if atom.has_prefix("subject:") && atom != "subject:sanitize" {
    let arg = String::unsafe_substring(atom, start=8, end=atom.length())
    eprint_line("fatal: unrecognized %(subject) argument: " + arg)
    @sys.exit(1)
  }
  // Validate refname
  if atom.has_prefix("refname:") {
    let arg = String::unsafe_substring(atom, start=8, end=atom.length())
    match arg {
      "" | "short" => ()
      _ if arg.has_prefix("lstrip=") ||
        arg.has_prefix("strip=") ||
        arg.has_prefix("rstrip=") => ()
      _ => {
        eprint_line("fatal: unrecognized %(refname) argument: " + arg)
        @sys.exit(1)
      }
    }
  }
  // Validate color atom
  if atom == "color" {
    eprint_line("fatal: expected format: %(color:<color>)")
    @sys.exit(1)
  }
  // rest is not supported
  if atom == "rest" {
    eprint_line("fatal: %(rest) atom used without %(format:ref-filter)")
    @sys.exit(1)
  }
  // Validate contents
  if atom.has_prefix("contents:") {
    let arg = String::unsafe_substring(atom, start=9, end=atom.length())
    match arg {
      "body" | "subject" | "signature" | "size" => ()
      _ if arg.has_prefix("lines=") => {
        let n_str = String::unsafe_substring(arg, start=6, end=arg.length())
        let n = @strconv.parse_int(n_str) catch { _ => -1 }
        if n < 0 {
          eprint_line("fatal: positive value expected contents:lines=" + n_str)
          @sys.exit(1)
        }
      }
      _ if arg == "trailers" || arg.has_prefix("trailers:") => ()
      _ => {
        eprint_line("fatal: unrecognized %(contents) argument: " + arg)
        @sys.exit(1)
      }
    }
  }
  // Validate objectname:short= arguments
  if atom.has_prefix("objectname:short=") {
    let val_str = String::unsafe_substring(atom, start=17, end=atom.length())
    let mut valid = false
    try {
      let v = @strconv.parse_int(val_str)
      if v > 0 {
        valid = true
      }
    } catch {
      _ => ()
    }
    if not(valid) {
      eprint_line("fatal: positive value expected objectname:short=" + val_str)
      @sys.exit(1)
    }
  }
  // Validate date format arguments
  if atom.has_prefix("authordate:") ||
    atom.has_prefix("committerdate:") ||
    atom.has_prefix("taggerdate:") ||
    atom.has_prefix("creatordate:") {
    let colon_pos = atom.find(":").unwrap()
    let date_arg = String::unsafe_substring(
      atom,
      start=colon_pos + 1,
      end=atom.length(),
    )
    if not(for_each_ref_valid_date_format(date_arg)) {
      eprint_line("fatal: unknown date format " + date_arg)
      @sys.exit(1)
    }
  }
  // Validate ahead-behind atom
  if atom == "ahead-behind" {
    eprint_line("fatal: expected format: %(ahead-behind:<committish>)")
    @sys.exit(1)
  }
  if atom.has_prefix("ahead-behind:") {
    let committish = String::unsafe_substring(atom, start=13, end=atom.length())
    let fs = OsFs::new()
    let git_dir = find_git_dir(fs)
    match @bitrepo.rev_parse(fs, git_dir, committish) {
      None => {
        eprint_line("fatal: failed to find '" + committish + "'")
        @sys.exit(1)
      }
      Some(_) => ()
    }
  }
  // Validate unknown atom names (must be last check)
  if not(for_each_ref_is_known_atom(atom)) {
    eprint_line("fatal: unknown field name '" + atom + "'")
    @sys.exit(1)
  }
}

///|
fn for_each_ref_valid_date_format(arg : String) -> Bool {
  match arg {
    "default"
    | "relative"
    | "short"
    | "local"
    | "iso"
    | "iso8601"
    | "iso-strict"
    | "iso8601-strict"
    | "rfc"
    | "rfc2822"
    | "raw"
    | "unix"
    | "human"
    | "default-local"
    | "iso-local"
    | "iso8601-local"
    | "iso-strict-local"
    | "iso8601-strict-local"
    | "rfc-local"
    | "rfc2822-local"
    | "raw-local"
    | "unix-local"
    | "short-local"
    | "human-local"
    | "relative-local" => true
    _ if arg.has_prefix("format:") || arg.has_prefix("format-local:") => true
    _ => false
  }
}

///|
fn for_each_ref_is_known_atom(atom : String) -> Bool {
  // Get the base name (before any ':')
  let base = match atom.find(":") {
    Some(pos) => String::unsafe_substring(atom, start=0, end=pos)
    None => atom
  }
  match base {
    "refname"
    | "objectname"
    | "objecttype"
    | "objectsize"
    | "deltabase"
    | "upstream"
    | "push"
    | "HEAD"
    | "color"
    | "align"
    | "end"
    | "if"
    | "then"
    | "else"
    | "rest"
    | "raw"
    | "contents"
    | "body"
    | "subject"
    | "trailers"
    | "author"
    | "authordate"
    | "authorname"
    | "authoremail"
    | "committer"
    | "committerdate"
    | "committername"
    | "committeremail"
    | "tagger"
    | "taggerdate"
    | "taggername"
    | "taggeremail"
    | "creatordate"
    | "creator"
    | "object"
    | "type"
    | "tag"
    | "tree"
    | "parent"
    | "numparent"
    | "describe"
    | "symref"
    | "is-base"
    | "ahead-behind"
    | "worktreepath"
    | "*objectname"
    | "*objecttype"
    | "*objectsize"
    | "*deltabase"
    | "*raw" => true
    _ if base.has_prefix("*") => {
      let deref = String::unsafe_substring(base, start=1, end=base.length())
      for_each_ref_is_known_atom(deref)
    }
    _ => false
  }
}

///|
fn for_each_ref_compare(
  fs : OsFs,
  git_dir : String,
  a : (String, @bitcore.ObjectId),
  b : (String, @bitcore.ObjectId),
  field : String,
  ignore_case : Bool,
) -> Int {
  match field {
    "refname" | "refname:short" =>
      if ignore_case {
        lexicographic_compare(a.0.to_lower(), b.0.to_lower())
      } else {
        lexicographic_compare(a.0, b.0)
      }
    "objectname" => lexicographic_compare(a.1.to_hex(), b.1.to_hex())
    _ if field.has_prefix("version:refname") || field == "v:refname" =>
      for_each_ref_version_compare(a.0, b.0)
    _ if field.has_prefix("creatordate") ||
      field.has_prefix("authordate") ||
      field.has_prefix("committerdate") ||
      field.has_prefix("taggerdate") =>
      // If field has :format: suffix, sort by formatted string
      if field.find(":format:") is Some(_) {
        let val_a = for_each_ref_get_sort_value(fs, git_dir, a.1, field)
        let val_b = for_each_ref_get_sort_value(fs, git_dir, b.1, field)
        lexicographic_compare(val_a, val_b)
      } else {
        let ts_a = for_each_ref_get_timestamp(fs, git_dir, a.1, field)
        let ts_b = for_each_ref_get_timestamp(fs, git_dir, b.1, field)
        ts_a.compare(ts_b)
      }
    "raw" => {
      let bytes_a = for_each_ref_load_raw_bytes(fs, git_dir, a.1)
      let bytes_b = for_each_ref_load_raw_bytes(fs, git_dir, b.1)
      bytes_compare(bytes_a, bytes_b)
    }
    "raw:size" => {
      let bytes_a = for_each_ref_load_raw_bytes(fs, git_dir, a.1)
      let bytes_b = for_each_ref_load_raw_bytes(fs, git_dir, b.1)
      bytes_a.length().compare(bytes_b.length())
    }
    "contents:size" => {
      let size_a = for_each_ref_get_contents_size(fs, git_dir, a.1)
      let size_b = for_each_ref_get_contents_size(fs, git_dir, b.1)
      size_a.compare(size_b)
    }
    _ => {
      // Generic field comparison: extract field value for each ref and compare
      let val_a = for_each_ref_get_sort_value(fs, git_dir, a.1, field)
      let val_b = for_each_ref_get_sort_value(fs, git_dir, b.1, field)
      if ignore_case {
        lexicographic_compare(val_a.to_lower(), val_b.to_lower())
      } else {
        lexicographic_compare(val_a, val_b)
      }
    }
  }
}

///|
fn for_each_ref_load_raw_bytes(
  fs : OsFs,
  git_dir : String,
  id : @bitcore.ObjectId,
) -> Bytes {
  let db = @bitlib.ObjectDb::load(fs, git_dir) catch {
    _ => return Bytes::new(0)
  }
  let obj = db.get(fs, id) catch { _ => return Bytes::new(0) }
  match obj {
    Some(o) => o.data
    None => Bytes::new(0)
  }
}

///|
fn for_each_ref_get_contents_size(
  fs : OsFs,
  git_dir : String,
  id : @bitcore.ObjectId,
) -> Int {
  let db = @bitlib.ObjectDb::load(fs, git_dir) catch { _ => return 0 }
  let obj = db.get(fs, id) catch { _ => return 0 }
  match obj {
    Some(o) => {
      let text = decode_bytes(o.data)
      // Extract raw_message: everything after first blank line
      match text.find("\n\n") {
        Some(pos) => {
          let raw_message = String::unsafe_substring(
            text,
            start=pos + 2,
            end=text.length(),
          )
          // Count UTF-8 byte length
          let mut byte_len = 0
          for c in raw_message {
            let code = c.to_int()
            if code < 0x80 {
              byte_len += 1
            } else if code < 0x800 {
              byte_len += 2
            } else if code < 0x10000 {
              byte_len += 3
            } else {
              byte_len += 4
            }
          }
          byte_len
        }
        None => 0
      }
    }
    None => 0
  }
}

///|
fn bytes_compare(a : Bytes, b : Bytes) -> Int {
  let len = if a.length() < b.length() { a.length() } else { b.length() }
  let mut i = 0
  while i < len {
    let ca = a[i]
    let cb = b[i]
    if ca < cb {
      return -1
    }
    if ca > cb {
      return 1
    }
    i += 1
  }
  a.length().compare(b.length())
}

///|
fn for_each_ref_get_sort_value(
  fs : OsFs,
  git_dir : String,
  id : @bitcore.ObjectId,
  field : String,
) -> String {
  let db = @bitlib.ObjectDb::load(fs, git_dir) catch { _ => return "" }
  let obj = db.get(fs, id) catch { _ => return "" }
  guard obj is Some(o) else { return "" }
  let text = decode_bytes(o.data)
  // Handle date format fields for sorting
  if field.find(":format:") is Some(fmt_pos) {
    let fmt = String::unsafe_substring(
      field,
      start=fmt_pos + 8,
      end=field.length(),
    )
    // Get timestamp using creator logic
    let headers = if field.has_prefix("creator") {
      ["tagger ", "committer ", "author "]
    } else if field.has_prefix("author") {
      ["author "]
    } else if field.has_prefix("committer") {
      ["committer "]
    } else {
      ["tagger "]
    }
    for h in headers {
      for line_view in text.split("\n") {
        let line = line_view.to_string()
        if line.length() == 0 {
          break
        }
        if line.has_prefix(h) {
          let ident = String::unsafe_substring(
            line,
            start=h.length(),
            end=line.length(),
          )
          let (ts, tz) = for_each_ref_parse_ident_ts(ident)
          return format_timestamp_strftime(ts, tz, fmt)
        }
      }
    }
    return ""
  }
  // Determine which ident header to use
  let header = if field.has_prefix("author") {
    "author "
  } else if field.has_prefix("committer") {
    "committer "
  } else if field.has_prefix("tagger") {
    "tagger "
  } else if field.has_prefix("creator") {
    // Creator: try tagger, then committer, then author
    let headers = ["tagger ", "committer ", "author "]
    for h in headers {
      for line_view in text.split("\n") {
        let line = line_view.to_string()
        if line.length() == 0 {
          break
        }
        if line.has_prefix(h) {
          let ident = String::unsafe_substring(
            line,
            start=h.length(),
            end=line.length(),
          )
          return ident
        }
      }
    }
    return ""
  } else if field == "subject" || field == "body" || field == "contents" {
    // Extract message body for sorting
    match text.find("\n\n") {
      Some(pos) => {
        let msg = String::unsafe_substring(
          text,
          start=pos + 2,
          end=text.length(),
        )
        if field == "subject" {
          let first_line = match msg.find("\n") {
            Some(nl) => String::unsafe_substring(msg, start=0, end=nl)
            None => msg
          }
          return first_line
        }
        return msg
      }
      None => return ""
    }
  } else {
    return ""
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
      // Extract email part: <...>
      if field.has_suffix("email") {
        match ident.find("<") {
          Some(es) =>
            match ident.find(">") {
              Some(ee) if ee > es =>
                return String::unsafe_substring(ident, start=es, end=ee + 1)
              _ => ()
            }
          _ => ()
        }
      }
      // Extract name part: everything before <
      if field.has_suffix("name") {
        match ident.find("<") {
          Some(es) if es > 0 =>
            return String::unsafe_substring(ident, start=0, end=es)
              .trim_end(chars=" ")
              .to_string()
          _ => ()
        }
      }
      return ident
    }
  }
  ""
}

///|
fn for_each_ref_match_pattern(refname : String, pattern : String) -> Bool {
  // Simple glob matching for ref patterns
  match pattern.find("*") {
    Some(star_pos) => {
      let prefix = String::unsafe_substring(pattern, start=0, end=star_pos)
      let suffix = String::unsafe_substring(
        pattern,
        start=star_pos + 1,
        end=pattern.length(),
      )
      if not(refname.has_prefix(prefix)) {
        return false
      }
      if suffix.length() == 0 {
        return true
      }
      refname.has_suffix(suffix)
    }
    None =>
      // Non-glob: match exact ref or as path prefix (with / boundary)
      // Pattern ending with / matches everything under that directory
      refname == pattern ||
      (
        refname.has_prefix(pattern) &&
        pattern.length() <= refname.length() &&
        (
          (pattern.length() > 0 && pattern[pattern.length() - 1] == '/') ||
          (
            pattern.length() < refname.length() &&
            refname[pattern.length()] == '/'
          )
        )
      )
  }
}

///|
// Peel an object to its commit. Follows tag chains until a commit is found.
async fn for_each_ref_peel_to_commit(
  fs : OsFs,
  db : @bitlib.ObjectDb,
  id : @bitcore.ObjectId,
) -> @bitcore.ObjectId? {
  let mut current_id = id
  for _ in 0..<100 {
    let obj = db.get(fs, current_id) catch { _ => return None }
    match obj {
      Some(o) =>
        match o.obj_type {
          @bitcore.ObjectType::Commit => return Some(current_id)
          @bitcore.ObjectType::Tag => {
            let tag_text = decode_bytes(o.data)
            let mut target_hex = ""
            for line_view in tag_text.split("\n") {
              let line = line_view.to_string()
              if line.has_prefix("object ") {
                target_hex = String::unsafe_substring(
                  line,
                  start=7,
                  end=line.length(),
                )
                break
              }
            }
            if target_hex == "" {
              return None
            }
            current_id = @bitcore.ObjectId::from_hex(target_hex) catch {
              _ => return None
            }
          }
          _ => return None
        }
      None => return None
    }
  }
  None
}

///|
// Check if ancestor_id is an ancestor of (or equal to) descendant_id.
// Uses BFS walking from descendant through parent chain.
async fn for_each_ref_is_ancestor(
  fs : OsFs,
  db : @bitlib.ObjectDb,
  ancestor_id : @bitcore.ObjectId,
  descendant_id : @bitcore.ObjectId,
) -> Bool {
  if ancestor_id.to_hex() == descendant_id.to_hex() {
    return true
  }
  let visited : Map[String, Bool] = {}
  let queue : Array[@bitcore.ObjectId] = [descendant_id]
  visited[descendant_id.to_hex()] = true
  while queue.length() > 0 {
    let current = queue.remove(0)
    let obj = db.get(fs, current) catch { _ => continue }
    match obj {
      Some(o) if o.obj_type == @bitcore.ObjectType::Commit => {
        let commit_text = decode_bytes(o.data)
        for line_view in commit_text.split("\n") {
          let line = line_view.to_string()
          if line.has_prefix("parent ") {
            let parent_hex = String::unsafe_substring(
              line,
              start=7,
              end=line.length(),
            )
            if parent_hex == ancestor_id.to_hex() {
              return true
            }
            if not(visited.contains(parent_hex)) {
              visited[parent_hex] = true
              let parent_id = @bitcore.ObjectId::from_hex(parent_hex) catch {
                _ => continue
              }
              queue.push(parent_id)
            }
          } else if line == "" {
            break
          }
        }
      }
      _ => ()
    }
  }
  false
}

///|
fn lexicographic_compare(a : String, b : String) -> Int {
  let len = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<len {
    let ca = a[i].to_int()
    let cb = b[i].to_int()
    if ca != cb {
      return if ca < cb { -1 } else { 1 }
    }
  }
  if a.length() < b.length() {
    -1
  } else if a.length() > b.length() {
    1
  } else {
    0
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
  if field.has_prefix("creator") {
    // creator: try tagger first, then committer, then author
    let headers = ["tagger ", "committer ", "author "]
    for h in headers {
      for line_view in text.split("\n") {
        let line = line_view.to_string()
        if line.length() == 0 {
          break
        }
        if line.has_prefix(h) {
          let ident = String::unsafe_substring(
            line,
            start=h.length(),
            end=line.length(),
          )
          let (ts, _) = for_each_ref_parse_ident_ts(ident)
          return ts
        }
      }
    }
    return 0L
  }
  let header = if field.has_prefix("author") {
    "author "
  } else if field.has_prefix("committer") {
    "committer "
  } else {
    "tagger "
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
fn perl_quote_bytes_to_buf(data : Bytes, buf : Array[Byte]) -> Unit {
  // Perl quoting: wrap in single quotes, escape ' and \
  // Output raw bytes to avoid UTF-8 re-encoding corruption
  buf.push(b'\'')
  for i = 0; i < data.length(); i = i + 1 {
    let b = data[i]
    if b == b'\'' {
      buf.push(b'\\')
      buf.push(b'\'')
    } else if b == b'\\' {
      buf.push(b'\\')
      buf.push(b'\\')
    } else {
      buf.push(b)
    }
  }
  buf.push(b'\'')
}

///|
/// Check if format string contains atoms that require object data
/// (i.e., anything beyond objectname and refname).
fn for_each_ref_format_needs_object(format : String) -> Bool {
  let chars = format.to_array()
  let len = chars.length()
  let mut i = 0
  while i < len {
    if chars[i] == '%' && i + 1 < len && chars[i + 1] == '(' {
      let start = i + 2
      let mut end_pos = start
      while end_pos < len && chars[end_pos] != ')' {
        end_pos = end_pos + 1
      }
      if end_pos < len {
        let atom = String::from_array(
          FixedArray::makei(end_pos - start, fn(j) { chars[start + j] }),
        )
        // Atoms that DON'T need object data
        if not(
            atom == "refname" ||
            atom.has_prefix("refname:") ||
            atom == "objectname" ||
            atom.has_prefix("objectname:") ||
            atom == "HEAD" ||
            atom == "if" ||
            atom.has_prefix("if:") ||
            atom == "then" ||
            atom == "else" ||
            atom == "end" ||
            atom.has_prefix("color:") ||
            atom.has_prefix("align:") ||
            atom.has_prefix("is-base:") ||
            atom.has_prefix("ahead-behind:"),
          ) {
          return true
        }
        i = end_pos + 1
      } else {
        i = i + 1
      }
    } else {
      i = i + 1
    }
  }
  false
}

///|
fn byte_buf_push_char(buf : Array[Byte], c : Char) -> Unit {
  let code = c.to_int()
  if code < 0x80 {
    buf.push(code.to_byte())
  } else if code < 0x800 {
    buf.push((0xC0 | (code >> 6)).to_byte())
    buf.push((0x80 | (code & 0x3F)).to_byte())
  } else if code < 0x10000 {
    buf.push((0xE0 | (code >> 12)).to_byte())
    buf.push((0x80 | ((code >> 6) & 0x3F)).to_byte())
    buf.push((0x80 | (code & 0x3F)).to_byte())
  } else {
    buf.push((0xF0 | (code >> 18)).to_byte())
    buf.push((0x80 | ((code >> 12) & 0x3F)).to_byte())
    buf.push((0x80 | ((code >> 6) & 0x3F)).to_byte())
    buf.push((0x80 | (code & 0x3F)).to_byte())
  }
}

///|
// Parse align args like "30", "middle,30", "30,right", "width=42,position=middle", etc.
// Returns (width, position) where position: 0=left, 1=middle, 2=right
fn for_each_ref_parse_align_args(args : String) -> (Int, Int) {
  let mut width = 0
  let mut position = 0 // left by default
  for part_view in args.split(",") {
    let part_str = part_view.to_string().trim(chars=" \t").to_string()
    if part_str == "left" {
      position = 0
    } else if part_str == "middle" {
      position = 1
    } else if part_str == "right" {
      position = 2
    } else if part_str.has_prefix("position=") {
      let pval = String::unsafe_substring(
        part_str,
        start=9,
        end=part_str.length(),
      )
      if pval == "left" {
        position = 0
      } else if pval == "middle" {
        position = 1
      } else if pval == "right" {
        position = 2
      }
    } else if part_str.has_prefix("width=") {
      let wval = String::unsafe_substring(
        part_str,
        start=6,
        end=part_str.length(),
      )
      width = @strconv.parse_int(wval) catch { _ => width }
    } else {
      // Try parsing as integer (width)
      let parsed = @strconv.parse_int(part_str) catch { _ => 0 }
      if parsed > 0 {
        width = parsed
      }
    }
  }
  (width, position)
}

///|
async fn for_each_ref_format(
  fs : OsFs,
  git_dir : String,
  db : @bitlib.ObjectDb,
  format : String,
  refname : String,
  id : @bitcore.ObjectId,
  quote_style : String,
  color_mode : String,
  is_base_value : String,
) -> Bytes {
  let out : Array[Byte] = []
  let chars = format.to_array()
  let len = chars.length()
  let mut i = 0
  // Eagerly load object data
  let mut obj_type = "missing"
  let mut obj_size = 0
  let mut obj_data : Bytes = Bytes::new(0)
  let mut commit_data : Bytes = Bytes::new(0)
  let mut tag_data : Bytes = Bytes::new(0)
  let mut is_tag = false
  let mut deref_id : @bitcore.ObjectId = @bitcore.ObjectId::zero()
  let mut deref_type = ""
  let mut deref_broken = false
  let loaded_obj = db.get(fs, id) catch { _ => None }
  // Check for missing objects — if format needs object data, fatal error
  if loaded_obj is None && for_each_ref_format_needs_object(format) {
    eprint_line("fatal: missing object " + id.to_hex() + " for " + refname)
    @sys.exit(1)
  }
  match loaded_obj {
    Some(obj) => {
      obj_type = match obj.obj_type {
        @bitcore.ObjectType::Commit => "commit"
        @bitcore.ObjectType::Tree => "tree"
        @bitcore.ObjectType::Blob => "blob"
        @bitcore.ObjectType::Tag => "tag"
      }
      obj_data = obj.data
      obj_size = obj.data.length()
      if obj.obj_type == @bitcore.ObjectType::Commit {
        commit_data = obj.data
      } else if obj.obj_type == @bitcore.ObjectType::Tag {
        tag_data = obj.data
        is_tag = true
        // Follow tag chain to find the deref target (commit/tree/blob)
        let mut current_data = obj.data
        for _ in 0..<100 {
          // max depth to avoid infinite loops
          let tag_text = decode_bytes(current_data)
          let mut found_target = false
          let mut declared_type = ""
          let mut target_hex_str = ""
          for line_view in tag_text.split("\n") {
            let line = line_view.to_string()
            if line.has_prefix("object ") {
              target_hex_str = String::unsafe_substring(
                line,
                start=7,
                end=line.length(),
              )
            } else if line.has_prefix("type ") {
              declared_type = String::unsafe_substring(
                line,
                start=5,
                end=line.length(),
              )
            } else if line == "" {
              break
            }
          }
          if target_hex_str != "" {
            let target_id = @bitcore.ObjectId::from_hex(target_hex_str) catch {
              _ => break
            }
            let target_obj = db.get(fs, target_id) catch { _ => break }
            match target_obj {
              Some(tobj) => {
                let actual_type = match tobj.obj_type {
                  @bitcore.ObjectType::Commit => "commit"
                  @bitcore.ObjectType::Tree => "tree"
                  @bitcore.ObjectType::Blob => "blob"
                  @bitcore.ObjectType::Tag => "tag"
                }
                if declared_type != "" && declared_type != actual_type {
                  deref_broken = true
                  break
                }
                deref_id = target_id
                deref_type = actual_type
                if tobj.obj_type == @bitcore.ObjectType::Commit {
                  commit_data = tobj.data
                } else if tobj.obj_type == @bitcore.ObjectType::Tag {
                  // Continue following the tag chain
                  current_data = tobj.data
                  found_target = true
                }
                // For tree/blob deref, commit_data stays empty
              }
              None => break
            }
          }
          if not(found_target) {
            break
          }
        }
      }
    }
    None => ()
  }

  // if/then/else state tracking
  // 0=normal, 1=if_cond (evaluating condition atom), 2=then_branch, 3=else_branch
  let mut if_state = 0
  let mut if_cond_value = "" // the evaluated condition atom value
  let mut if_cond_raw : Bytes = Bytes::new(0) // raw bytes for condition
  let mut if_equals = "" // "" means no equals check, otherwise the value to compare
  let mut if_notequals = "" // "" means no notequals check
  let mut if_has_equals = false
  let mut if_has_notequals = false
  let mut if_result = false // true = then branch, false = else branch
  let mut if_depth = 0 // for nested if support
  // Scope stack for %(end) disambiguation: "if" or "align"
  let scope_stack : Array[String] = []
  // Alignment stack: (start_pos_in_out, width, position: 0=left, 1=middle, 2=right)
  let align_stack : Array[(Int, Int, Int)] = []
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
        // Handle alignment
        if atom.has_prefix("align:") {
          let align_args = String::unsafe_substring(
            atom,
            start=6,
            end=atom.length(),
          )
          let parsed = for_each_ref_parse_align_args(align_args)
          align_stack.push((out.length(), parsed.0, parsed.1))
          scope_stack.push("align")
          i = end_pos + 1
          continue
        }
        // Handle if/then/else/end flow control
        if atom == "if" || atom.has_prefix("if:") {
          if if_state != 0 {
            // Nested if - track depth
            if_depth += 1
            scope_stack.push("if")
            i = end_pos + 1
            continue
          }
          if_state = 1
          if_cond_value = ""
          if_cond_raw = Bytes::new(0)
          if_has_equals = false
          if_has_notequals = false
          if_equals = ""
          if_notequals = ""
          if atom.has_prefix("if:equals=") {
            if_equals = String::unsafe_substring(
              atom,
              start=10,
              end=atom.length(),
            )
            if_has_equals = true
          } else if atom.has_prefix("if:notequals=") {
            if_notequals = String::unsafe_substring(
              atom,
              start=13,
              end=atom.length(),
            )
            if_has_notequals = true
          }
          scope_stack.push("if")
          i = end_pos + 1
          continue
        }
        if atom == "then" {
          if if_depth > 0 {
            i = end_pos + 1
            continue
          }
          // Evaluate condition
          if if_has_equals {
            // For raw atom, compare raw bytes as string
            let cond_str = if if_cond_raw.length() > 0 {
              decode_bytes(if_cond_raw)
            } else {
              if_cond_value
            }
            if_result = cond_str == if_equals
          } else if if_has_notequals {
            let cond_str = if if_cond_raw.length() > 0 {
              decode_bytes(if_cond_raw)
            } else {
              if_cond_value
            }
            if_result = cond_str != if_notequals
          } else {
            // Simple %(if) - true if value is non-empty (git's is_empty: whitespace-only = empty)
            if_result = if if_cond_raw.length() > 0 {
              not(for_each_ref_is_empty_bytes(if_cond_raw))
            } else {
              not(for_each_ref_is_empty_value(if_cond_value))
            }
          }
          if_state = 2 // then branch
          i = end_pos + 1
          continue
        }
        if atom == "else" {
          if if_depth > 0 {
            i = end_pos + 1
            continue
          }
          if_state = 3 // else branch
          i = end_pos + 1
          continue
        }
        if atom == "end" {
          let scope_type = if scope_stack.length() > 0 {
            scope_stack.pop().unwrap()
          } else {
            "if"
          }
          if scope_type == "align" {
            // Close alignment scope — pad content
            if align_stack.length() > 0 {
              let entry = align_stack.pop().unwrap()
              let align_start = entry.0
              let align_width = entry.1
              let align_pos = entry.2 // 0=left, 1=middle, 2=right
              let content_len = out.length() - align_start
              if content_len < align_width {
                let pad_total = align_width - content_len
                let content : Array[Byte] = []
                for idx = align_start; idx < out.length(); idx = idx + 1 {
                  content.push(out[idx])
                }
                while out.length() > align_start {
                  let _ = out.pop()
                }
                if align_pos == 0 {
                  // left: content + spaces
                  for idx = 0; idx < content.length(); idx = idx + 1 {
                    out.push(content[idx])
                  }
                  for _ in 0..<pad_total {
                    out.push(b' ')
                  }
                } else if align_pos == 1 {
                  // middle: left_pad + content + right_pad
                  let left_pad = pad_total / 2
                  let right_pad = pad_total - left_pad
                  for _ in 0..<left_pad {
                    out.push(b' ')
                  }
                  for idx = 0; idx < content.length(); idx = idx + 1 {
                    out.push(content[idx])
                  }
                  for _ in 0..<right_pad {
                    out.push(b' ')
                  }
                } else {
                  // right: spaces + content
                  for _ in 0..<pad_total {
                    out.push(b' ')
                  }
                  for idx = 0; idx < content.length(); idx = idx + 1 {
                    out.push(content[idx])
                  }
                }
              }
              // If this is the outermost align and quote_style is set, quote the result
              if align_stack.length() == 0 && quote_style != "" {
                let aligned_content : Array[Byte] = []
                for idx = align_start; idx < out.length(); idx = idx + 1 {
                  aligned_content.push(out[idx])
                }
                while out.length() > align_start {
                  let _ = out.pop()
                }
                let aligned_str = decode_bytes(
                  Bytes::from_array(aligned_content[:]),
                )
                let quoted_result = for_each_ref_quote(aligned_str, quote_style)
                let encoded = @utf8.encode(quoted_result[:])
                for idx = 0; idx < encoded.length(); idx = idx + 1 {
                  out.push(encoded[idx])
                }
              }
            }
            i = end_pos + 1
            continue
          }
          // Close if scope
          if if_depth > 0 {
            if_depth -= 1
            i = end_pos + 1
            continue
          }
          if_state = 0
          i = end_pos + 1
          continue
        }
        // In if_cond state, evaluate the atom as condition value
        if if_state == 1 {
          if atom == "raw" || atom == "*raw" {
            if_cond_raw = if atom == "raw" {
              obj_data
            } else if is_tag {
              commit_data
            } else {
              Bytes::new(0)
            }
          } else {
            if_cond_value = for_each_ref_atom(
              fs, git_dir, db, atom, refname, id, obj_type, obj_size, obj_data, commit_data,
              tag_data, is_tag, deref_id, deref_type, color_mode, is_base_value,
            )
          }
          i = end_pos + 1
          continue
        }
        // In then/else branch, only output if condition matches
        if if_state == 2 && not(if_result) {
          i = end_pos + 1
          continue
        }
        if if_state == 3 && if_result {
          i = end_pos + 1
          continue
        }
        // Check for broken tag when deref atom is used
        if deref_broken && atom.has_prefix("*") {
          eprint_line("error: unable to parse object referenced by tag")
          @sys.exit(1)
        }
        // For raw/deref-raw atoms, handle binary data specially
        if (atom == "raw" || atom == "*raw") && quote_style == "" {
          let raw_bytes = if atom == "raw" {
            obj_data
          } else if is_tag {
            commit_data
          } else {
            Bytes::new(0)
          }
          for idx = 0; idx < raw_bytes.length(); idx = idx + 1 {
            out.push(raw_bytes[idx])
          }
        } else if (atom == "raw" || atom == "*raw") && quote_style == "perl" {
          // For --perl, perl-quote the raw binary data directly as bytes
          let raw_bytes = if atom == "raw" {
            obj_data
          } else if is_tag {
            commit_data
          } else {
            Bytes::new(0)
          }
          perl_quote_bytes_to_buf(raw_bytes, out)
        } else {
          let value = for_each_ref_atom(
            fs, git_dir, db, atom, refname, id, obj_type, obj_size, obj_data, commit_data,
            tag_data, is_tag, deref_id, deref_type, color_mode, is_base_value,
          )
          // Inside align blocks, don't quote individual atoms
          let effective_quote = if align_stack.length() > 0 {
            ""
          } else {
            quote_style
          }
          let quoted = for_each_ref_quote(value, effective_quote)
          let encoded = @utf8.encode(quoted[:])
          for idx = 0; idx < encoded.length(); idx = idx + 1 {
            out.push(encoded[idx])
          }
        }
        i = end_pos + 1
      } else {
        if for_each_ref_if_output_active(if_state, if_result, if_depth) {
          byte_buf_push_char(out, chars[i])
        }
        i += 1
      }
    } else if chars[i] == '%' &&
      i + 1 < len &&
      chars[i + 1] == '0' &&
      i + 2 < len {
      // %0a = newline, %00 = NUL, etc. (hex escape)
      let hex_ch = chars[i + 2]
      let val = match hex_ch {
        'a' | 'A' => Some('\n')
        'd' | 'D' => Some('\r')
        '0' => {
          let nul : Char = Int::unsafe_to_char(0)
          Some(nul)
        }
        _ => None
      }
      match val {
        Some(c) => {
          if for_each_ref_if_output_active(if_state, if_result, if_depth) {
            byte_buf_push_char(out, c)
          }
          i += 3
        }
        None => {
          if for_each_ref_if_output_active(if_state, if_result, if_depth) {
            byte_buf_push_char(out, chars[i])
          }
          i += 1
        }
      }
    } else if chars[i] == '%' &&
      i + 1 < len &&
      chars[i + 1] == 'x' &&
      i + 3 < len {
      // %xNN hex escape
      let hi = for_each_ref_hex_digit(chars[i + 2])
      let lo = for_each_ref_hex_digit(chars[i + 3])
      if hi >= 0 && lo >= 0 {
        if for_each_ref_if_output_active(if_state, if_result, if_depth) {
          out.push(((hi * 16 + lo) & 0xFF).to_byte())
        }
        i += 4
      } else {
        if for_each_ref_if_output_active(if_state, if_result, if_depth) {
          byte_buf_push_char(out, chars[i])
        }
        i += 1
      }
    } else if chars[i] == '%' && i + 1 < len && chars[i + 1] == '%' {
      if for_each_ref_if_output_active(if_state, if_result, if_depth) {
        out.push(b'%')
      }
      i += 2
    } else {
      if for_each_ref_if_output_active(if_state, if_result, if_depth) {
        byte_buf_push_char(out, chars[i])
      }
      i += 1
    }
  }
  // If color was used, append reset sequence at end of line
  if color_mode == "always" && format.find("%(color:") is Some(_) {
    let reset = "\u001b[m"
    for c in reset {
      byte_buf_push_char(out, c)
    }
  }
  Bytes::from_array(out[:])
}

///|
fn for_each_ref_quote(value : String, style : String) -> String {
  if style == "" {
    return value
  }
  match style {
    "shell" => {
      let buf = StringBuilder::new()
      buf.write_char('\'')
      for c in value {
        if c == '\'' {
          buf.write_string("'\\''")
        } else {
          buf.write_char(c)
        }
      }
      buf.write_char('\'')
      buf.to_string()
    }
    "perl" => {
      let buf = StringBuilder::new()
      buf.write_char('\'')
      for c in value {
        if c == '\'' || c == '\\' {
          buf.write_char('\\')
        }
        buf.write_char(c)
      }
      buf.write_char('\'')
      buf.to_string()
    }
    "python" => {
      let buf = StringBuilder::new()
      buf.write_char('\'')
      for c in value {
        if c == '\n' {
          buf.write_string("\\n")
        } else {
          if c == '\'' || c == '\\' {
            buf.write_char('\\')
          }
          buf.write_char(c)
        }
      }
      buf.write_char('\'')
      buf.to_string()
    }
    "tcl" => {
      let buf = StringBuilder::new()
      buf.write_char('"')
      for c in value {
        if c == '"' ||
          c == '\\' ||
          c == '[' ||
          c == ']' ||
          c == '$' ||
          c == '{' ||
          c == '}' {
          buf.write_char('\\')
        }
        buf.write_char(c)
      }
      buf.write_char('"')
      buf.to_string()
    }
    _ => value
  }
}

///|
async fn for_each_ref_atom(
  fs : OsFs,
  git_dir : String,
  db : @bitlib.ObjectDb,
  atom : String,
  refname : String,
  id : @bitcore.ObjectId,
  obj_type : String,
  obj_size : Int,
  obj_data : Bytes,
  commit_data : Bytes,
  tag_data : Bytes,
  is_tag : Bool,
  deref_id : @bitcore.ObjectId,
  deref_type : String,
  color_mode : String,
  is_base_value : String,
) -> String {
  match atom {
    "refname" | "refname:" => refname
    "refname:short" => for_each_ref_short_refname(fs, git_dir, refname)
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
    "objectsize:disk" => {
      let disk_size = db.find_object_disk_size(fs, id) catch { _ => None }
      match disk_size {
        Some(s) => s.to_string()
        None => "0"
      }
    }
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
    "raw" => decode_bytes(obj_data)
    "raw:size" => obj_data.length().to_string()
    "*objectname" | "*objectname:long" =>
      if is_tag {
        deref_id.to_hex()
      } else {
        ""
      }
    "*objectname:short" =>
      if is_tag {
        let hex = deref_id.to_hex()
        (try! hex[:7]).to_string()
      } else {
        ""
      }
    "*raw" => if is_tag { decode_bytes(commit_data) } else { "" }
    "*raw:size" => if is_tag { commit_data.length().to_string() } else { "0" }
    "*objecttype" => if is_tag { deref_type } else { "" }
    "*objectsize" => if is_tag { commit_data.length().to_string() } else { "" }
    "*objectsize:disk" =>
      if is_tag {
        let disk_size = db.find_object_disk_size(fs, deref_id) catch {
          _ => None
        }
        match disk_size {
          Some(s) => s.to_string()
          None => "0"
        }
      } else {
        ""
      }
    // Generic deref (*) atoms: strip * prefix, evaluate using deref target data
    _ if atom.has_prefix("*") && is_tag => {
      let inner_atom = String::unsafe_substring(
        atom,
        start=1,
        end=atom.length(),
      )
      // Re-evaluate using the deref target's data
      for_each_ref_atom(
        fs,
        git_dir,
        db,
        inner_atom,
        refname,
        deref_id,
        deref_type,
        commit_data.length(),
        commit_data,
        commit_data,
        Bytes::new(0),
        false,
        @bitcore.ObjectId::zero(),
        "",
        color_mode,
        is_base_value,
      )
    }
    _ if atom.has_prefix("*") => ""
    _ if atom == "upstream" || atom.has_prefix("upstream:") =>
      for_each_ref_upstream_atom(fs, git_dir, db, atom, refname)
    _ if atom == "push" || atom.has_prefix("push:") =>
      for_each_ref_push_atom(fs, git_dir, db, atom, refname)
    _ if atom == "symref" || atom.has_prefix("symref:") =>
      for_each_ref_symref_atom(fs, git_dir, atom, refname)
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
    _ if atom.has_prefix("HEAD:") => {
      eprint_line("fatal: %(HEAD) does not take arguments")
      @sys.exit(1)
      ""
    }
    "symref" => ""
    "flag" =>
      // Not fully implemented
      ""
    _ if atom.has_prefix("is-base:") => is_base_value
    _ if atom.has_prefix("ahead-behind:") => "0 0" // TODO: full ahead-behind
    "worktreepath" =>
      // Check if this ref's branch is checked out in a worktree
      if refname.has_prefix("refs/heads/") {
        let branch = String::unsafe_substring(
          refname,
          start=11,
          end=refname.length(),
        )
        for_each_ref_worktree_path(fs, git_dir, branch)
      } else {
        ""
      }
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
      atom.has_prefix("tagger") ||
      atom.has_prefix("trailers") ||
      atom == "signature" ||
      atom.has_prefix("signature:") => {
      let mailmap = for_each_ref_read_mailmap(fs, git_dir)
      for_each_ref_commit_atom(atom, commit_data, tag_data, is_tag, mailmap)
    }
    _ if atom == "describe" || atom.has_prefix("describe:") =>
      for_each_ref_describe_atom(fs, git_dir, id, atom)
    _ if atom.has_prefix("*describe") => {
      // Deref describe: for tags, describe the target object
      let deref_atom = if atom == "*describe" {
        "describe"
      } else {
        "describe" + String::unsafe_substring(atom, start=9, end=atom.length())
      }
      if is_tag {
        let text = decode_bytes(tag_data)
        for line_view in text.split("\n") {
          let line = line_view.to_string()
          if line.has_prefix("object ") {
            let target_hex = String::unsafe_substring(
              line,
              start=7,
              end=line.length(),
            )
            let target_id = @bitcore.ObjectId::from_hex(target_hex) catch {
              _ => return ""
            }
            return for_each_ref_describe_atom(
              fs, git_dir, target_id, deref_atom,
            )
          }
        }
        ""
      } else {
        ""
      }
    }
    _ if atom.has_prefix("refname:") => {
      let arg = String::unsafe_substring(atom, start=8, end=atom.length())
      eprint_line("fatal: unrecognized %(refname) argument: " + arg)
      @sys.exit(1)
      ""
    }
    _ if atom.has_prefix("color:") || atom == "color:reset" =>
      if color_mode == "always" {
        for_each_ref_color_code(
          String::unsafe_substring(atom, start=6, end=atom.length()),
        )
      } else {
        ""
      }
    _ if atom.has_prefix("align:") || atom == "end" => ""
    _ if atom.has_prefix("if") ||
      atom.has_prefix("then") ||
      atom.has_prefix("else") => ""
    _ => ""
  }
}

///|
fn for_each_ref_if_output_active(
  if_state : Int,
  if_result : Bool,
  if_depth : Int,
) -> Bool {
  if if_depth > 0 {
    return false
  }
  match if_state {
    0 => true // normal mode
    1 => false // evaluating condition, don't output
    2 => if_result // then branch: output if condition true
    3 => not(if_result) // else branch: output if condition false
    _ => true
  }
}

///|
// git's is_empty: true if string contains only whitespace (space, tab, newline, etc.)
fn for_each_ref_is_empty_value(s : String) -> Bool {
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i]
    if c != ' ' && c != '\t' && c != '\n' && c != '\r' {
      return false
    }
  }
  true
}

///|
fn for_each_ref_is_empty_bytes(b : Bytes) -> Bool {
  for i = 0; i < b.length(); i = i + 1 {
    let c = b[i]
    if c != b' ' && c != b'\t' && c != b'\n' && c != b'\r' {
      return false
    }
  }
  true
}

///|
/// Get worktree path for a branch if it's checked out.
fn for_each_ref_worktree_path(
  fs : OsFs,
  git_dir : String,
  branch : String,
) -> String {
  // Check main worktree
  let head_path = git_dir + "/HEAD"
  let head_data = fs.read_file(head_path) catch { _ => Bytes::new(0) }
  if head_data.length() > 0 {
    let head_line = decode_bytes(head_data)
    let trimmed = if head_line.has_suffix("\n") {
      String::unsafe_substring(head_line, start=0, end=head_line.length() - 1)
    } else {
      head_line
    }
    if trimmed == "ref: refs/heads/" + branch {
      // Main worktree — git_dir is .git, worktree is parent
      let work_dir = if git_dir.has_suffix("/.git") {
        String::unsafe_substring(git_dir, start=0, end=git_dir.length() - 5)
      } else {
        git_dir
      }
      return work_dir
    }
  }
  // Check linked worktrees
  let worktrees_dir = git_dir + "/worktrees"
  if fs.is_dir(worktrees_dir) {
    let entries = fs.readdir(worktrees_dir) catch { _ => return "" }
    for name in entries {
      let wt_dir = worktrees_dir + "/" + name
      if fs.is_dir(wt_dir) {
        let wt_head = wt_dir + "/HEAD"
        let wt_data = fs.read_file(wt_head) catch { _ => continue }
        let wt_line = decode_bytes(wt_data)
        let wt_trimmed = if wt_line.has_suffix("\n") {
          String::unsafe_substring(wt_line, start=0, end=wt_line.length() - 1)
        } else {
          wt_line
        }
        if wt_trimmed == "ref: refs/heads/" + branch {
          // Read gitdir to get the actual worktree path
          let gitdir_file = wt_dir + "/gitdir"
          let gitdir_data = fs.read_file(gitdir_file) catch { _ => continue }
          let gitdir_line = decode_bytes(gitdir_data)
          let gitdir_trimmed = if gitdir_line.has_suffix("\n") {
            String::unsafe_substring(
              gitdir_line,
              start=0,
              end=gitdir_line.length() - 1,
            )
          } else {
            gitdir_line
          }
          // gitdir points to .git file in worktree, strip /.git
          if gitdir_trimmed.has_suffix("/.git") {
            return String::unsafe_substring(
              gitdir_trimmed,
              start=0,
              end=gitdir_trimmed.length() - 5,
            )
          }
          return gitdir_trimmed
        }
      }
    }
  }
  ""
}

///|
/// Extract is-base atom arguments from format string (e.g., "HEAD" from "%(is-base:HEAD)")
fn for_each_ref_extract_is_base_atoms(format : String) -> Array[String] {
  let result : Array[String] = []
  let chars = format.to_array()
  let len = chars.length()
  let mut i = 0
  while i < len {
    if chars[i] == '%' && i + 1 < len && chars[i + 1] == '(' {
      let start = i + 2
      let mut end_pos = start
      while end_pos < len && chars[end_pos] != ')' {
        end_pos = end_pos + 1
      }
      if end_pos < len {
        let atom = String::from_array(
          FixedArray::makei(end_pos - start, fn(j) { chars[start + j] }),
        )
        if atom.has_prefix("is-base:") {
          let name = String::unsafe_substring(atom, start=8, end=atom.length())
          result.push(name)
        }
        i = end_pos + 1
      } else {
        i = i + 1
      }
    } else {
      i = i + 1
    }
  }
  result
}

///|
/// Resolve a ref to its commit OID by peeling tags.
/// Returns None for non-commit objects, outputting appropriate errors to stderr.
async fn for_each_ref_resolve_to_commit(
  fs : OsFs,
  db : @bitlib.ObjectDb,
  refname : String,
  id : @bitcore.ObjectId,
) -> @bitcore.ObjectId? {
  let mut current_id = id
  for _ in 0..<100 {
    let obj = db.get(fs, current_id) catch { _ => return None }
    match obj {
      Some(o) =>
        match o.obj_type {
          @bitcore.ObjectType::Commit => return Some(current_id)
          @bitcore.ObjectType::Tag => {
            let tag_text = decode_bytes(o.data)
            let mut target_hex = ""
            let mut declared_type = ""
            for line_view in tag_text.split("\n") {
              let line = line_view.to_string()
              if line.has_prefix("object ") {
                target_hex = String::unsafe_substring(
                  line,
                  start=7,
                  end=line.length(),
                )
              } else if line.has_prefix("type ") {
                declared_type = String::unsafe_substring(
                  line,
                  start=5,
                  end=line.length(),
                )
              } else if line == "" {
                break
              }
            }
            if target_hex == "" {
              return None
            }
            let target_id = @bitcore.ObjectId::from_hex(target_hex) catch {
              _ => return None
            }
            // Check if declared type matches actual type (broken tag detection)
            let target_obj = db.get(fs, target_id) catch { _ => None }
            match target_obj {
              Some(tobj) => {
                let actual_type = match tobj.obj_type {
                  @bitcore.ObjectType::Commit => "commit"
                  @bitcore.ObjectType::Tree => "tree"
                  @bitcore.ObjectType::Blob => "blob"
                  @bitcore.ObjectType::Tag => "tag"
                }
                if declared_type != "" && declared_type != actual_type {
                  // Broken tag: type mismatch
                  eprint_line(
                    "error: object " +
                    target_hex +
                    " is a " +
                    actual_type +
                    ", not a " +
                    declared_type,
                  )
                  eprint_line(
                    "error: bad tag pointer to " + target_hex + " in " + refname,
                  )
                  return None
                }
                current_id = target_id
              }
              None => return None
            }
          }
          @bitcore.ObjectType::Blob | @bitcore.ObjectType::Tree =>
            // Not a commit
            return None
        }
      None => return None
    }
  }
  None
}

///|
/// Compute is-base values for all refs.
/// For each is-base atom, find the ref whose commit is the merge-base with the tip.
async fn for_each_ref_compute_is_base(
  fs : OsFs,
  git_dir : String,
  db : @bitlib.ObjectDb,
  filtered : Array[(String, @bitcore.ObjectId)],
  is_base_atoms : Array[String],
  results : Map[String, String],
) -> Unit {
  for atom_name in is_base_atoms {
    // Resolve the committish (e.g., "HEAD") to a commit OID
    let tip_id = @bitrepo.rev_parse(fs, git_dir, atom_name)
    match tip_id {
      None => {
        eprint_line("fatal: failed to find '" + atom_name + "'")
        @sys.exit(1)
      }
      Some(tip_oid) => {
        // Resolve tip to commit
        let tip_commit = for_each_ref_resolve_to_commit(
          fs, db, atom_name, tip_oid,
        )
        match tip_commit {
          None => {
            eprint_line("fatal: failed to find '" + atom_name + "'")
            @sys.exit(1)
          }
          Some(tip_commit_id) => {
            // Collect all refs that resolve to commits
            let commit_refs : Array[(String, @bitcore.ObjectId)] = []
            for item in filtered {
              let (refname, ref_id) = item
              let commit_id = for_each_ref_resolve_to_commit(
                fs, db, refname, ref_id,
              )
              match commit_id {
                Some(cid) => commit_refs.push((refname, cid))
                None => ()
              }
            }
            // Find the base: walk tip's parent chain (BFS) and find first matching commit
            let base_ref = for_each_ref_find_base(
              fs, db, tip_commit_id, commit_refs,
            )
            match base_ref {
              Some(ref_name) => {
                let existing = results.get(ref_name).unwrap_or("")
                if existing == "" {
                  results[ref_name] = "(" + atom_name + ")"
                }
              }
              None => ()
            }
          }
        }
      }
    }
  }
}

///|
/// Find which ref is the merge-base for the tip.
/// Uses BFS from tip through parent chain.
/// Returns the refname of the first ref whose commit is encountered.
async fn for_each_ref_find_base(
  fs : OsFs,
  db : @bitlib.ObjectDb,
  tip_id : @bitcore.ObjectId,
  commit_refs : Array[(String, @bitcore.ObjectId)],
) -> String? {
  if commit_refs.length() == 0 {
    return None
  }
  // Build set of commit OIDs -> refname (first ref wins)
  let commit_set : Map[String, String] = {}
  for item in commit_refs {
    let (refname, cid) = item
    let hex = cid.to_hex()
    if not(commit_set.contains(hex)) {
      commit_set[hex] = refname
    }
  }
  // BFS from tip through parent chain
  let queue : Array[@bitcore.ObjectId] = [tip_id]
  let visited : Map[String, Bool] = {}
  visited[tip_id.to_hex()] = true
  while queue.length() > 0 {
    let current = queue.remove(0)
    let current_hex = current.to_hex()
    // Check if any ref points to this commit
    match commit_set.get(current_hex) {
      Some(refname) => return Some(refname)
      None => ()
    }
    // Parse commit to get parents
    let obj = db.get(fs, current) catch { _ => None }
    match obj {
      Some(o) if o.obj_type == @bitcore.ObjectType::Commit => {
        let text = decode_bytes(o.data)
        for line_view in text.split("\n") {
          let line = line_view.to_string()
          if line.has_prefix("parent ") {
            let parent_hex = String::unsafe_substring(
              line,
              start=7,
              end=line.length(),
            )
            if not(visited.contains(parent_hex)) {
              visited[parent_hex] = true
              let parent_id = @bitcore.ObjectId::from_hex(parent_hex) catch {
                _ => continue
              }
              queue.push(parent_id)
            }
          } else if not(line.has_prefix("tree ")) &&
            not(line.has_prefix("author ")) &&
            not(line.has_prefix("committer ")) &&
            not(line.has_prefix("parent ")) {
            // Past header lines
            break
          }
        }
      }
      _ => ()
    }
  }
  None
}

///|
fn for_each_ref_color_code(color_name : String) -> String {
  let esc = "\u001b["
  match color_name {
    "reset" => esc + "m"
    "red" => esc + "31m"
    "green" => esc + "32m"
    "yellow" => esc + "33m"
    "blue" => esc + "34m"
    "magenta" => esc + "35m"
    "cyan" => esc + "36m"
    "white" => esc + "37m"
    "bold" => esc + "1m"
    "bold red" => esc + "1;31m"
    "bold green" => esc + "1;32m"
    "bold blue" => esc + "1;34m"
    _ => ""
  }
}

///|
async fn for_each_ref_describe_atom(
  _fs : OsFs,
  git_dir : String,
  id : @bitcore.ObjectId,
  atom : String,
) -> String {
  // Parse options from atom: "describe" or "describe:opt1,opt2,..."
  let options_str = if atom == "describe" {
    ""
  } else if atom.has_prefix("describe:") {
    String::unsafe_substring(atom, start=9, end=atom.length())
  } else {
    ""
  }
  let args : Array[String] = ["--git-dir=" + git_dir, "describe"]
  // Parse comma-separated options
  if options_str.length() > 0 {
    let mut remaining = options_str
    while remaining.length() > 0 {
      let comma_pos = remaining.find(",")
      let (opt, rest) = match comma_pos {
        Some(pos) =>
          (
            String::unsafe_substring(remaining, start=0, end=pos),
            String::unsafe_substring(
              remaining,
              start=pos + 1,
              end=remaining.length(),
            ),
          )
        None => (remaining, "")
      }
      if opt == "tags" {
        args.push("--tags")
      } else if opt.has_prefix("abbrev=") {
        args.push("--" + opt)
      } else if opt.has_prefix("match=") {
        let val = String::unsafe_substring(opt, start=6, end=opt.length())
        // Strip surrounding quotes if present
        let clean = for_each_ref_strip_quotes(val)
        args.push("--match")
        args.push(clean)
      } else if opt.has_prefix("exclude=") {
        let val = String::unsafe_substring(opt, start=8, end=opt.length())
        let clean = for_each_ref_strip_quotes(val)
        args.push("--exclude")
        args.push(clean)
      } else {
        // Bad argument — report from this option onward
        let bad = if rest.length() > 0 { opt + "," + rest } else { opt }
        eprint_line("fatal: unrecognized %(describe) argument: " + bad)
        @sys.exit(1)
      }
      remaining = rest
    }
  }
  args.push(id.to_hex())
  // Find real git path
  let git_exe = for_each_ref_find_real_git(git_dir)
  // Redirect stderr to suppress error messages from git describe
  let dev_null = @process.redirect_to_file("/dev/null")
  let (code, stdout) = @process.collect_stdout(
    git_exe,
    args[:],
    inherit_env=true,
    stderr=dev_null,
  )
  if code != 0 {
    return ""
  }
  // Trim trailing newline from output
  let out = stdout.text() catch { _ => return "" }
  let trimmed = if out.has_suffix("\n") {
    String::unsafe_substring(out, start=0, end=out.length() - 1)
  } else {
    out
  }
  trimmed
}

///|
fn for_each_ref_strip_quotes(s : String) -> String {
  if s.length() >= 2 {
    let first = s[0]
    let last = s[s.length() - 1]
    if (first == '"' && last == '"') || (first == '\'' && last == '\'') {
      return String::unsafe_substring(s, start=1, end=s.length() - 1)
    }
  }
  s
}

///|
fn for_each_ref_find_real_git(git_dir : String) -> String {
  // Try to find the real git executable
  // Check SHIM_REAL_GIT env var first
  match @sys.get_env_var("SHIM_REAL_GIT") {
    Some(path) if path.length() > 0 => path
    _ => {
      // Try git-dir relative path
      let fs = OsFs::new()
      let real_git_path = git_dir + "/../tools/git-shim/real-git-path"
      let data = fs.read_file(real_git_path) catch { _ => return "git" }
      let path = decode_bytes(data)
      let trimmed = if path.has_suffix("\n") {
        String::unsafe_substring(path, start=0, end=path.length() - 1)
      } else {
        path
      }
      if trimmed.length() > 0 {
        trimmed
      } else {
        "git"
      }
    }
  }
}

///|
fn for_each_ref_short_refname(
  fs : OsFs,
  git_dir : String,
  refname : String,
) -> String {
  // Implements git's refs_shorten_unambiguous_ref algorithm.
  // Rules (in order): %s, refs/%s, refs/tags/%s, refs/heads/%s,
  //   refs/remotes/%s, refs/remotes/%s/HEAD
  // Scan rules in reverse. For each matching rule, extract short_name.
  // Check if any other rule (all rules in strict mode, only prior rules in
  // loose mode) resolves short_name to an existing ref. If not, return it.
  guard refname.has_prefix("refs/") else { return refname }
  // Read core.warnambiguousrefs (default true = strict mode)
  let strict = for_each_ref_read_warn_ambiguous_refs(fs, git_dir)
  // Rule patterns and their prefixes/suffixes for matching
  // rule 0: "%s" - matches anything (skip, always matches)
  // rule 1: "refs/%s" - prefix "refs/"
  // rule 2: "refs/tags/%s" - prefix "refs/tags/"
  // rule 3: "refs/heads/%s" - prefix "refs/heads/"
  // rule 4: "refs/remotes/%s" - prefix "refs/remotes/"
  // rule 5: "refs/remotes/%s/HEAD" - prefix "refs/remotes/", suffix "/HEAD"
  let rule_prefixes = [
    "", "refs/", "refs/tags/", "refs/heads/", "refs/remotes/", "refs/remotes/",
  ]
  let rule_suffixes = ["", "", "", "", "", "/HEAD"]
  let num_rules = 6
  // Scan rules in reverse order (5 → 1), skip rule 0
  for i = num_rules - 1; i > 0; i = i - 1 {
    let prefix = rule_prefixes[i]
    let suffix = rule_suffixes[i]
    // Check if refname matches this rule
    if not(refname.has_prefix(prefix)) {
      continue
    }
    if suffix.length() > 0 && not(refname.has_suffix(suffix)) {
      continue
    }
    let short_name = String::unsafe_substring(
      refname,
      start=prefix.length(),
      end=refname.length() - suffix.length(),
    )
    if short_name.length() == 0 {
      continue
    }
    // In strict mode, check all rules. In loose mode, only check prior rules.
    let rules_to_fail = if strict { num_rules } else { i }
    let mut ambiguous = false
    for j = 0; j < rules_to_fail; j = j + 1 {
      if j == i {
        continue
      }
      let expanded = rule_prefixes[j] + short_name + rule_suffixes[j]
      if for_each_ref_ref_exists(fs, git_dir, expanded) {
        ambiguous = true
        break
      }
    }
    if not(ambiguous) {
      return short_name
    }
  }
  // Fallback: return refname as-is
  refname
}

///|
fn for_each_ref_ref_exists(
  fs : OsFs,
  git_dir : String,
  refname : String,
) -> Bool {
  let ref_path = git_dir + "/" + refname
  let ref_data = fs.read_file(ref_path) catch { _ => Bytes::new(0) }
  if ref_data.length() > 0 {
    return true
  }
  for_each_ref_packed_ref_exists(fs, git_dir, refname)
}

///|
fn for_each_ref_packed_ref_exists(
  fs : OsFs,
  git_dir : String,
  refname : String,
) -> Bool {
  let packed_refs_path = git_dir + "/packed-refs"
  let content = @utf8.decode_lossy(
    (fs.read_file(packed_refs_path) catch { _ => return false })[:],
  )
  for line_view in content.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 || line[0] == '#' || line[0] == '^' {
      continue
    }
    // Format: "<hex> <refname>"
    if line.length() > 41 {
      let ref_part = String::unsafe_substring(line, start=41, end=line.length())
      if ref_part == refname {
        return true
      }
    }
  }
  false
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
fn for_each_ref_symref_atom(
  fs : OsFs,
  git_dir : String,
  atom : String,
  refname : String,
) -> String {
  // Read the ref file to check if it's a symbolic ref
  let ref_path = git_dir + "/" + refname
  let content = @utf8.decode_lossy(
    (fs.read_file(ref_path) catch { _ => return "" })[:],
  )
  let line = match content.find("\n") {
    Some(pos) => String::unsafe_substring(content, start=0, end=pos)
    None => content
  }
  guard line.has_prefix("ref: ") else { return "" }
  let target = String::unsafe_substring(line, start=5, end=line.length())
  match atom {
    "symref" => target
    "symref:short" => for_each_ref_short_refname(fs, git_dir, target)
    _ if atom.has_prefix("symref:lstrip=") || atom.has_prefix("symref:strip=") => {
      let eq_pos = atom.find("=").unwrap()
      let n_str = String::unsafe_substring(
        atom,
        start=eq_pos + 1,
        end=atom.length(),
      )
      let n = @strconv.parse_int(n_str) catch { _ => 0 }
      if n < 0 {
        for_each_ref_lstrip_negative(target, -n)
      } else {
        for_each_ref_strip_refname(target, n)
      }
    }
    _ if atom.has_prefix("symref:rstrip=") => {
      let n_str = String::unsafe_substring(atom, start=14, end=atom.length())
      let n = @strconv.parse_int(n_str) catch { _ => 0 }
      for_each_ref_rstrip_n(target, n)
    }
    _ => target
  }
}

///|
fn for_each_ref_upstream_atom(
  fs : OsFs,
  git_dir : String,
  db : @bitlib.ObjectDb,
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
    "upstream:short" => for_each_ref_short_refname(fs, git_dir, upstream_ref)
    "upstream:remotename" => remote
    "upstream:remoteref" =>
      if merge.has_prefix("refs/heads/") {
        merge
      } else {
        upstream_ref
      }
    _ if atom == "upstream:track" ||
      atom == "upstream:trackshort" ||
      atom == "upstream:track,nobracket" ||
      atom == "upstream:nobracket,track" => {
      // Check if upstream ref exists
      let upstream_exists = (@bitrepo.rev_parse(fs, git_dir, upstream_ref) catch {
          _ => None
        })
        is Some(_)
      if not(upstream_exists) {
        // Upstream is gone
        if atom == "upstream:trackshort" {
          return ""
        }
        if atom.find("nobracket") is Some(_) {
          return "gone"
        }
        return "[gone]"
      }
      // Compute ahead/behind
      let (ahead, behind) = for_each_ref_ahead_behind(
        fs, git_dir, db, refname, upstream_ref,
      )
      if atom == "upstream:trackshort" {
        if ahead > 0 && behind > 0 {
          "<>"
        } else if ahead > 0 {
          ">"
        } else if behind > 0 {
          "<"
        } else {
          "="
        }
      } else {
        let nobracket = atom.find("nobracket") is Some(_)
        if ahead > 0 && behind > 0 {
          if nobracket {
            "ahead " + ahead.to_string() + ", behind " + behind.to_string()
          } else {
            "[ahead " +
            ahead.to_string() +
            ", behind " +
            behind.to_string() +
            "]"
          }
        } else if ahead > 0 {
          if nobracket {
            "ahead " + ahead.to_string()
          } else {
            "[ahead " + ahead.to_string() + "]"
          }
        } else if behind > 0 {
          if nobracket {
            "behind " + behind.to_string()
          } else {
            "[behind " + behind.to_string() + "]"
          }
        } else {
          ""
        }
      }
    }
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
  db : @bitlib.ObjectDb,
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
  let remote_cfg = remotes.get(remote)
  guard remote_cfg is Some(_) else { return "" }
  // Compute push ref using push refspec mapping
  let local_ref = "refs/heads/" + branch
  let push_ref = match remote_cfg {
    Some(cfg) => {
      // Try to map through push refspecs
      let push_specs = @bitlib.parse_push_refspecs(cfg.push)
      let mut mapped : String? = None
      for spec in push_specs {
        match @bitlib.refspec_map_dst(spec.src, spec.dst, local_ref) {
          Some(dst) => {
            mapped = Some(dst)
            break
          }
          None => continue
        }
      }
      match mapped {
        Some(dst) =>
          // Convert remote ref to tracking ref: refs/heads/X -> refs/remotes/remote/X
          if dst.has_prefix("refs/heads/") {
            let dst_branch = String::unsafe_substring(
              dst,
              start=11,
              end=dst.length(),
            )
            "refs/remotes/" + remote + "/" + dst_branch
          } else {
            "refs/remotes/" + remote + "/" + branch
          }
        None => "refs/remotes/" + remote + "/" + branch
      }
    }
    None => "refs/remotes/" + remote + "/" + branch
  }
  // Compute remote ref (what ref on the remote side)
  let remote_ref = match remote_cfg {
    Some(cfg) => {
      let push_specs = @bitlib.parse_push_refspecs(cfg.push)
      let mut mapped : String? = None
      for spec in push_specs {
        match @bitlib.refspec_map_dst(spec.src, spec.dst, local_ref) {
          Some(dst) => {
            mapped = Some(dst)
            break
          }
          None => continue
        }
      }
      mapped.unwrap_or("")
    }
    None => ""
  }
  match atom {
    "push" => push_ref
    "push:short" => for_each_ref_short_refname(fs, git_dir, push_ref)
    "push:remotename" => remote
    "push:remoteref" => remote_ref
    _ if atom == "push:track" ||
      atom == "push:trackshort" ||
      atom == "push:track,nobracket" ||
      atom == "push:nobracket,track" => {
      let push_exists = (@bitrepo.rev_parse(fs, git_dir, push_ref) catch {
          _ => None
        })
        is Some(_)
      if not(push_exists) {
        if atom == "push:trackshort" {
          return ""
        }
        if atom.find("nobracket") is Some(_) {
          return "gone"
        }
        return "[gone]"
      }
      let (ahead, behind) = for_each_ref_ahead_behind(
        fs, git_dir, db, refname, push_ref,
      )
      if atom == "push:trackshort" {
        if ahead > 0 && behind > 0 {
          "<>"
        } else if ahead > 0 {
          ">"
        } else if behind > 0 {
          "<"
        } else {
          "="
        }
      } else {
        let nobracket = atom.find("nobracket") is Some(_)
        if ahead > 0 && behind > 0 {
          if nobracket {
            "ahead " + ahead.to_string() + ", behind " + behind.to_string()
          } else {
            "[ahead " +
            ahead.to_string() +
            ", behind " +
            behind.to_string() +
            "]"
          }
        } else if ahead > 0 {
          if nobracket {
            "ahead " + ahead.to_string()
          } else {
            "[ahead " + ahead.to_string() + "]"
          }
        } else if behind > 0 {
          if nobracket {
            "behind " + behind.to_string()
          } else {
            "[behind " + behind.to_string() + "]"
          }
        } else {
          ""
        }
      }
    }
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
fn for_each_ref_read_warn_ambiguous_refs(fs : OsFs, git_dir : String) -> Bool {
  let content = @bitlib.read_config_content(fs, git_dir)
  let blocks = @bitlib.parse_config_blocks(content)
  for block in blocks {
    if block.section != Some("core") {
      continue
    }
    for line in block.lines {
      match @bitlib.parse_config_kv(line) {
        Some((key, value)) if key == "warnambiguousrefs" => {
          let v = value.to_lower()
          if v == "false" || v == "no" || v == "off" || v == "0" {
            return false
          }
        }
        _ => ()
      }
    }
  }
  true // default is true (strict)
}

///|
fn for_each_ref_ahead_behind(
  fs : OsFs,
  git_dir : String,
  db : @bitlib.ObjectDb,
  local_ref : String,
  upstream_ref : String,
) -> (Int, Int) {
  // Resolve both refs to OIDs
  let local_opt = @bitrepo.rev_parse(fs, git_dir, local_ref) catch {
    _ => return (0, 0)
  }
  guard local_opt is Some(local_id) else { return (0, 0) }
  let upstream_opt = @bitrepo.rev_parse(fs, git_dir, upstream_ref) catch {
    _ => return (0, 0)
  }
  guard upstream_opt is Some(upstream_id) else { return (0, 0) }
  if local_id.to_hex() == upstream_id.to_hex() {
    return (0, 0)
  }
  // Walk from both sides to find merge base
  let local_ancestors : Map[String, Bool] = {}
  for_each_ref_walk_ancestors(fs, db, local_id, local_ancestors)
  let upstream_ancestors : Map[String, Bool] = {}
  for_each_ref_walk_ancestors(fs, db, upstream_id, upstream_ancestors)
  // Count ahead: commits reachable from local but not upstream
  let mut ahead = 0
  for entry in local_ancestors {
    if not(upstream_ancestors.contains(entry.0)) {
      ahead += 1
    }
  }
  // Count behind: commits reachable from upstream but not local
  let mut behind = 0
  for entry in upstream_ancestors {
    if not(local_ancestors.contains(entry.0)) {
      behind += 1
    }
  }
  (ahead, behind)
}

///|
fn for_each_ref_walk_ancestors(
  fs : OsFs,
  db : @bitlib.ObjectDb,
  start : @bitcore.ObjectId,
  out : Map[String, Bool],
) -> Unit {
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
async fn for_each_ref_commit_atom(
  atom : String,
  commit_data : Bytes,
  tag_data : Bytes,
  is_tag : Bool,
  mailmap : Array[MailmapEntry],
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
  let mut past_headers = false
  let message_lines : Array[String] = []
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
    } else {
      message_lines.push(raw_line)
    }
  }
  // Find signature start index
  let mut sig_start = message_lines.length()
  for i = 0; i < message_lines.length(); i = i + 1 {
    let line = for_each_ref_strip_cr(message_lines[i])
    if line == "-----BEGIN PGP SIGNATURE-----" ||
      line == "-----BEGIN SSH SIGNATURE-----" {
      sig_start = i
      break
    }
  }
  // Parse multiline subject from lines before signature
  let mut subject_end = 0
  for i = 0; i < sig_start; i = i + 1 {
    let line = for_each_ref_strip_cr(message_lines[i])
    if line.length() == 0 {
      break
    }
    subject_end = i + 1
  }
  // Build subject (joined with space)
  let subject_parts : Array[String] = []
  for i = 0; i < subject_end; i = i + 1 {
    subject_parts.push(for_each_ref_strip_cr(message_lines[i]))
  }
  let subject = subject_parts.join(" ")
  // Find body start: skip blank lines after subject
  let mut body_start = subject_end
  while body_start < message_lines.length() {
    if for_each_ref_strip_cr(message_lines[body_start]).length() > 0 {
      break
    }
    body_start = body_start + 1
  }
  // body = everything from body_start to end (including signature)
  let body_parts : Array[String] = []
  for i = body_start; i < message_lines.length(); i = i + 1 {
    body_parts.push(message_lines[i])
  }
  let body = if body_parts.length() > 0 { body_parts.join("\n") } else { "" }
  // contents_body = from body_start to sig_start
  let contents_body_parts : Array[String] = []
  for i = body_start; i < sig_start; i = i + 1 {
    contents_body_parts.push(message_lines[i])
  }
  let contents_body = if contents_body_parts.length() > 0 {
    contents_body_parts.join("\n")
  } else {
    ""
  }
  // signature = from sig_start to end
  let sig_parts : Array[String] = []
  for i = sig_start; i < message_lines.length(); i = i + 1 {
    sig_parts.push(message_lines[i])
  }
  let signature = if sig_parts.length() > 0 { sig_parts.join("\n") } else { "" }
  // contents = full raw message (all message_lines joined)
  let raw_message = if message_lines.length() > 0 {
    message_lines.join("\n")
  } else {
    ""
  }
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
    "authorname:mailmap" =>
      for_each_ref_ident_name(for_each_ref_apply_mailmap(author, mailmap))
    "authoremail" => for_each_ref_ident_email(author)
    "authoremail:trim" => for_each_ref_ident_email_trim(author)
    "authoremail:localpart"
    | "authoremail:trim,localpart"
    | "authoremail:localpart,trim" => for_each_ref_ident_email_localpart(author)
    _ if atom.has_prefix("authoremail:") =>
      for_each_ref_resolve_name_or_email(
        author,
        "email",
        String::unsafe_substring(atom, start=12, end=atom.length()),
        mailmap,
      )
    "authordate" | "authordate:default" => for_each_ref_ident_date(author)
    "authordate:short" => for_each_ref_ident_date_short(author)
    "authordate:iso8601" | "authordate:iso" =>
      for_each_ref_ident_date_iso(author)
    "authordate:unix" => for_each_ref_ident_date_unix(author)
    "authordate:rfc2822" | "authordate:rfc" =>
      for_each_ref_ident_date_rfc(author)
    "authordate:raw" => for_each_ref_ident_date_raw(author)
    "authordate:relative" => for_each_ref_ident_date(author) // simplified
    "authordate:default-local" | "authordate:local" =>
      for_each_ref_ident_date_local(author)
    "authordate:short-local" => for_each_ref_ident_date_short_local(author)
    "authordate:iso8601-local" | "authordate:iso-local" =>
      for_each_ref_ident_date_iso_local(author)
    "authordate:rfc2822-local" | "authordate:rfc-local" =>
      for_each_ref_ident_date_rfc_local(author)
    "authordate:raw-local" => for_each_ref_ident_date_raw_local(author)
    "authordate:relative-local" => for_each_ref_ident_date(author) // relative is tz-independent
    _ if atom.has_prefix("authordate:format-local:") => {
      let fmt = String::unsafe_substring(atom, start=24, end=atom.length())
      for_each_ref_ident_date_strftime_local(author, fmt)
    }
    _ if atom.has_prefix("authordate:format:") => {
      let fmt = String::unsafe_substring(atom, start=18, end=atom.length())
      for_each_ref_ident_date_strftime(author, fmt)
    }
    "committername" => for_each_ref_ident_name(committer)
    "committername:mailmap" =>
      for_each_ref_ident_name(for_each_ref_apply_mailmap(committer, mailmap))
    "committeremail" => for_each_ref_ident_email(committer)
    "committeremail:trim" => for_each_ref_ident_email_trim(committer)
    "committeremail:localpart"
    | "committeremail:trim,localpart"
    | "committeremail:localpart,trim" =>
      for_each_ref_ident_email_localpart(committer)
    _ if atom.has_prefix("committeremail:") =>
      for_each_ref_resolve_name_or_email(
        committer,
        "email",
        String::unsafe_substring(atom, start=15, end=atom.length()),
        mailmap,
      )
    "committerdate" | "committerdate:default" =>
      for_each_ref_ident_date(committer)
    "committerdate:short" => for_each_ref_ident_date_short(committer)
    "committerdate:iso8601" | "committerdate:iso" =>
      for_each_ref_ident_date_iso(committer)
    "committerdate:unix" => for_each_ref_ident_date_unix(committer)
    "committerdate:rfc2822" | "committerdate:rfc" =>
      for_each_ref_ident_date_rfc(committer)
    "committerdate:raw" => for_each_ref_ident_date_raw(committer)
    "committerdate:relative" => for_each_ref_ident_date(committer) // simplified
    "committerdate:default-local" | "committerdate:local" =>
      for_each_ref_ident_date_local(committer)
    "committerdate:short-local" =>
      for_each_ref_ident_date_short_local(committer)
    "committerdate:iso8601-local" | "committerdate:iso-local" =>
      for_each_ref_ident_date_iso_local(committer)
    "committerdate:rfc2822-local" | "committerdate:rfc-local" =>
      for_each_ref_ident_date_rfc_local(committer)
    "committerdate:raw-local" => for_each_ref_ident_date_raw_local(committer)
    "committerdate:relative-local" => for_each_ref_ident_date(committer) // relative is tz-independent
    _ if atom.has_prefix("committerdate:format-local:") => {
      let fmt = String::unsafe_substring(atom, start=27, end=atom.length())
      for_each_ref_ident_date_strftime_local(committer, fmt)
    }
    _ if atom.has_prefix("committerdate:format:") => {
      let fmt = String::unsafe_substring(atom, start=21, end=atom.length())
      for_each_ref_ident_date_strftime(committer, fmt)
    }
    "taggername" => for_each_ref_ident_name(tagger)
    "taggername:mailmap" =>
      for_each_ref_ident_name(for_each_ref_apply_mailmap(tagger, mailmap))
    "taggeremail" => for_each_ref_ident_email(tagger)
    "taggeremail:trim" => for_each_ref_ident_email_trim(tagger)
    "taggeremail:localpart"
    | "taggeremail:trim,localpart"
    | "taggeremail:localpart,trim" => for_each_ref_ident_email_localpart(tagger)
    _ if atom.has_prefix("taggeremail:") =>
      for_each_ref_resolve_name_or_email(
        tagger,
        "email",
        String::unsafe_substring(atom, start=12, end=atom.length()),
        mailmap,
      )
    "taggerdate" | "taggerdate:default" => for_each_ref_ident_date(tagger)
    "taggerdate:short" => for_each_ref_ident_date_short(tagger)
    "taggerdate:iso8601" | "taggerdate:iso" =>
      for_each_ref_ident_date_iso(tagger)
    "taggerdate:unix" => for_each_ref_ident_date_unix(tagger)
    "taggerdate:rfc2822" | "taggerdate:rfc" =>
      for_each_ref_ident_date_rfc(tagger)
    "taggerdate:raw" => for_each_ref_ident_date_raw(tagger)
    "taggerdate:relative" => for_each_ref_ident_date(tagger) // simplified
    "taggerdate:default-local" | "taggerdate:local" =>
      for_each_ref_ident_date_local(tagger)
    "taggerdate:short-local" => for_each_ref_ident_date_short_local(tagger)
    "taggerdate:iso8601-local" | "taggerdate:iso-local" =>
      for_each_ref_ident_date_iso_local(tagger)
    "taggerdate:rfc2822-local" | "taggerdate:rfc-local" =>
      for_each_ref_ident_date_rfc_local(tagger)
    "taggerdate:raw-local" => for_each_ref_ident_date_raw_local(tagger)
    "taggerdate:relative-local" => for_each_ref_ident_date(tagger) // relative is tz-independent
    _ if atom.has_prefix("taggerdate:format-local:") => {
      let fmt = String::unsafe_substring(atom, start=24, end=atom.length())
      for_each_ref_ident_date_strftime_local(tagger, fmt)
    }
    _ if atom.has_prefix("taggerdate:format:") => {
      let fmt = String::unsafe_substring(atom, start=18, end=atom.length())
      for_each_ref_ident_date_strftime(tagger, fmt)
    }
    "creatordate" | "creatordate:default" => for_each_ref_ident_date(creator)
    "creatordate:short" => for_each_ref_ident_date_short(creator)
    "creatordate:iso8601" | "creatordate:iso" =>
      for_each_ref_ident_date_iso(creator)
    "creatordate:unix" => for_each_ref_ident_date_unix(creator)
    "creatordate:rfc2822" | "creatordate:rfc" =>
      for_each_ref_ident_date_rfc(creator)
    "creatordate:raw" => for_each_ref_ident_date_raw(creator)
    "creatordate:relative" => for_each_ref_ident_date(creator) // simplified
    "creatordate:default-local" | "creatordate:local" =>
      for_each_ref_ident_date_local(creator)
    "creatordate:short-local" => for_each_ref_ident_date_short_local(creator)
    "creatordate:iso8601-local" | "creatordate:iso-local" =>
      for_each_ref_ident_date_iso_local(creator)
    "creatordate:rfc2822-local" | "creatordate:rfc-local" =>
      for_each_ref_ident_date_rfc_local(creator)
    "creatordate:raw-local" => for_each_ref_ident_date_raw_local(creator)
    "creatordate:relative-local" => for_each_ref_ident_date(creator) // relative is tz-independent
    _ if atom.has_prefix("creatordate:format-local:") => {
      let fmt = String::unsafe_substring(atom, start=25, end=atom.length())
      for_each_ref_ident_date_strftime_local(creator, fmt)
    }
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
    _ if atom.has_prefix("subject:") => {
      let arg = String::unsafe_substring(atom, start=8, end=atom.length())
      eprint_line("fatal: unrecognized %(subject) argument: " + arg)
      @sys.exit(1)
      ""
    }
    "body" => body
    "contents" => raw_message
    "contents:body" => contents_body
    "contents:subject" => subject
    "contents:signature" => signature
    "contents:size" => {
      let mut byte_len = 0
      for c in raw_message {
        let code = c.to_int()
        if code < 0x80 {
          byte_len += 1
        } else if code < 0x800 {
          byte_len += 2
        } else if code < 0x10000 {
          byte_len += 3
        } else {
          byte_len += 4
        }
      }
      byte_len.to_string()
    }
    _ if atom.has_prefix("contents:lines=") => {
      let n_str = String::unsafe_substring(atom, start=15, end=atom.length())
      let n = @strconv.parse_int(n_str) catch { _ => 0 }
      if n <= 0 {
        ""
      } else {
        // Get first N lines of the commit/tag message
        let msg = if raw_message.length() > 0 { raw_message } else { subject }
        let lines : Array[String] = []
        for line_view in msg.split("\n") {
          if lines.length() >= n {
            break
          }
          lines.push(line_view.to_string())
        }
        // Trim trailing empty lines
        while lines.length() > 0 && lines[lines.length() - 1] == "" {
          ignore(lines.pop())
        }
        lines.join("\n")
      }
    }
    "trailers" => for_each_ref_format_trailers_atom(atom, raw_message)
    _ if atom.has_prefix("trailers:") =>
      for_each_ref_format_trailers_atom(atom, raw_message)
    "contents:trailers" => {
      let trailer_atom = "trailers"
      for_each_ref_format_trailers_atom(trailer_atom, raw_message)
    }
    _ if atom.has_prefix("contents:trailers:") => {
      let trailer_atom = "trailers" +
        String::unsafe_substring(atom, start=17, end=atom.length())
      for_each_ref_format_trailers_atom(trailer_atom, raw_message)
    }
    _ if atom.has_prefix("contents:") => {
      let arg = String::unsafe_substring(atom, start=9, end=atom.length())
      eprint_line("fatal: unrecognized %(contents) argument: " + arg)
      @sys.exit(1)
      ""
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
fn for_each_ref_strip_cr(s : String) -> String {
  if s.has_suffix("\r") {
    String::unsafe_substring(s, start=0, end=s.length() - 1)
  } else {
    s
  }
}

///|
fn for_each_ref_parse_trailers(
  message : String,
) -> Array[(String, String, Bool)] {
  // Find the last paragraph (trailer block) in the message
  // A trailer line is "key: value" or a continuation line (starts with space/tab)
  // Non-trailer lines in the block are kept with is_trailer=false
  let lines : Array[String] = []
  for line_view in message.split("\n") {
    lines.push(line_view.to_string())
  }
  // Remove trailing empty lines
  while lines.length() > 0 &&
        for_each_ref_strip_cr(lines[lines.length() - 1]).length() == 0 {
    ignore(lines.pop())
  }
  if lines.length() == 0 {
    return []
  }
  // Find start of last paragraph (separated by blank line)
  let mut para_start = lines.length()
  for i = lines.length() - 1; i >= 0; i = i - 1 {
    let line = for_each_ref_strip_cr(lines[i])
    if line.length() == 0 {
      break
    }
    para_start = i
  }
  // Parse trailer lines from last paragraph
  let result : Array[(String, String, Bool)] = []
  let mut i = para_start
  while i < lines.length() {
    let line = lines[i]
    let stripped = for_each_ref_strip_cr(line)
    // Check if this is a "key: value" line
    match stripped.find(": ") {
      Some(colon_pos) if colon_pos > 0 => {
        let key = String::unsafe_substring(stripped, start=0, end=colon_pos)
        let mut value = String::unsafe_substring(
          stripped,
          start=colon_pos + 2,
          end=stripped.length(),
        )
        // Check for continuation lines
        let mut j = i + 1
        while j < lines.length() {
          let next = lines[j]
          let next_stripped = for_each_ref_strip_cr(next)
          if next_stripped.length() > 0 &&
            (next_stripped.has_prefix(" ") || next_stripped.has_prefix("\t")) {
            value = value + "\n" + next_stripped
            j = j + 1
          } else {
            break
          }
        }
        result.push((key, value, true))
        i = j
      }
      _ => {
        // Non-trailer line (like "[ v2 updated patch description ]")
        result.push((stripped, "", false))
        i = i + 1
      }
    }
  }
  result
}

///|
async fn for_each_ref_format_trailers_atom(
  atom : String,
  message : String,
) -> String {
  // Parse options from atom: "trailers" or "trailers:opt1,opt2,..."
  let options_str = if atom == "trailers" {
    ""
  } else if atom.has_prefix("trailers:") {
    String::unsafe_substring(atom, start=9, end=atom.length())
  } else {
    ""
  }
  // Parse options
  let mut only = true // default: only=true (show only key:value trailers)
  let mut only_set = false
  let mut unfold = false
  let mut valueonly = false
  let keys : Array[String] = []
  let mut separator : String? = None
  let mut key_value_separator : String? = None
  if options_str.length() > 0 {
    // Parse comma-separated options, but key= values may contain commas in key=X,key=Y
    let mut remaining = options_str
    while remaining.length() > 0 {
      let (opt, rest) = for_each_ref_split_trailer_opt(remaining)
      if opt == "only" || opt == "only=yes" || opt == "only=true" {
        only = true
        only_set = true
      } else if opt == "only=no" || opt == "only=false" {
        only = false
        only_set = true
      } else if opt == "unfold" {
        unfold = true
      } else if opt == "valueonly" {
        valueonly = true
      } else if opt.has_prefix("key=") {
        let key_val = String::unsafe_substring(opt, start=4, end=opt.length())
        // Strip trailing colon if present
        let key_clean = if key_val.has_suffix(":") {
          String::unsafe_substring(key_val, start=0, end=key_val.length() - 1)
        } else {
          key_val
        }
        keys.push(key_clean)
      } else if opt == "key" {
        eprint_line("fatal: expected %(trailers:key=<value>)")
        @sys.exit(1)
      } else if opt.has_prefix("separator=") {
        let sep_raw = String::unsafe_substring(opt, start=10, end=opt.length())
        separator = Some(for_each_ref_decode_hex_escapes(sep_raw))
      } else if opt.has_prefix("key_value_separator=") {
        let sep_raw = String::unsafe_substring(opt, start=20, end=opt.length())
        key_value_separator = Some(for_each_ref_decode_hex_escapes(sep_raw))
      } else {
        eprint_line("fatal: unknown %(trailers) argument: " + remaining)
        @sys.exit(1)
      }
      remaining = rest
    }
  }
  // Default: if no only= was set and no key filter, show all trailers (including non-trailer lines)
  if not(only_set) && keys.length() == 0 {
    only = false
  }
  let trailers = for_each_ref_parse_trailers(message)
  // Filter and format
  let output_lines : Array[String] = []
  for trailer in trailers {
    let (key, value, is_trailer) = trailer
    // Apply key filter
    if keys.length() > 0 {
      if is_trailer {
        let mut key_matched = false
        for k in keys {
          if key.to_lower() == k.to_lower() {
            key_matched = true
            break
          }
        }
        if not(key_matched) {
          continue
        }
        // Non-trailer lines: only include if only=no
      } else if only {
        continue
      }
    } else if only && not(is_trailer) {
      continue
    }
    // Format the line
    let line = if is_trailer {
      let val = if unfold {
        // Unfold continuation lines: replace \n followed by whitespace with single space
        for_each_ref_unfold_trailer_value(value)
      } else {
        value
      }
      if valueonly {
        val
      } else {
        let kvs = match key_value_separator {
          Some(s) => s
          None => ": "
        }
        key + kvs + val
      }
    } else {
      key // non-trailer line, key holds the full line
    }
    output_lines.push(line)
  }
  // Join with separator
  let sep = match separator {
    Some(s) => s
    None => "\n"
  }
  let result = output_lines.join(sep)
  // Add trailing newline if using default separator and there are results
  if separator is None && result.length() > 0 {
    result + "\n"
  } else {
    result
  }
}

///|
fn for_each_ref_split_trailer_opt(s : String) -> (String, String) {
  // Split on first comma that is not inside a key= value
  // Special handling: "key=X" consumes up to next recognized option
  let chars = s.to_array()
  let len = chars.length()
  let mut i = 0
  while i < len {
    if chars[i] == ',' {
      return (
        String::from_array(FixedArray::makei(i, fn(j) { chars[j] })),
        String::from_array(
          FixedArray::makei(len - i - 1, fn(j) { chars[i + 1 + j] }),
        ),
      )
    }
    i = i + 1
  }
  (s, "")
}

///|
fn for_each_ref_decode_hex_escapes(s : String) -> String {
  // Decode %xNN hex escapes
  let chars = s.to_array()
  let len = chars.length()
  let buf = StringBuilder::new()
  let mut i = 0
  while i < len {
    if i + 3 < len && chars[i] == '%' && chars[i + 1] == 'x' {
      let hi = for_each_ref_hex_digit(chars[i + 2])
      let lo = for_each_ref_hex_digit(chars[i + 3])
      if hi >= 0 && lo >= 0 {
        buf.write_char(Int::unsafe_to_char(hi * 16 + lo))
        i = i + 4
        continue
      }
    }
    buf.write_char(chars[i])
    i = i + 1
  }
  buf.to_string()
}

///|
fn for_each_ref_hex_digit(c : Char) -> Int {
  if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int()
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 'a'.to_int() + 10
  } else if c >= 'A' && c <= 'F' {
    c.to_int() - 'A'.to_int() + 10
  } else {
    -1
  }
}

///|
fn for_each_ref_unfold_trailer_value(value : String) -> String {
  // Replace newline+whitespace with single space
  let buf = StringBuilder::new()
  let chars = value.to_array()
  let len = chars.length()
  let mut i = 0
  while i < len {
    if chars[i] == '\n' &&
      i + 1 < len &&
      (chars[i + 1] == ' ' || chars[i + 1] == '\t') {
      buf.write_char(' ')
      // Skip the newline and leading whitespace
      i = i + 1
      while i < len && (chars[i] == ' ' || chars[i] == '\t') {
        i = i + 1
      }
    } else {
      buf.write_char(chars[i])
      i = i + 1
    }
  }
  buf.to_string()
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
fn for_each_ref_ident_date_raw(ident : String) -> String {
  let (ts, tz) = for_each_ref_parse_ident_ts(ident)
  if ts == 0L {
    return ""
  }
  ts.to_string() + " " + tz
}

///|
fn for_each_ref_ident_date_raw_local(ident : String) -> String {
  let (ts, _tz) = for_each_ref_parse_ident_ts(ident)
  if ts == 0L {
    return ""
  }
  ts.to_string() + " +0000"
}

///|
fn for_each_ref_ident_date_local(ident : String) -> String {
  let (ts, _tz) = for_each_ref_parse_ident_ts(ident)
  if ts == 0L {
    return ""
  }
  format_timestamp_default_notz(ts, "+0000")
}

///|
fn for_each_ref_ident_date_short_local(ident : String) -> String {
  let (ts, _tz) = for_each_ref_parse_ident_ts(ident)
  if ts == 0L {
    return ""
  }
  format_timestamp_short(ts, "+0000")
}

///|
fn for_each_ref_ident_date_iso_local(ident : String) -> String {
  let (ts, _tz) = for_each_ref_parse_ident_ts(ident)
  if ts == 0L {
    return ""
  }
  format_timestamp_iso(ts, "+0000")
}

///|
fn for_each_ref_ident_date_rfc_local(ident : String) -> String {
  let (ts, _tz) = for_each_ref_parse_ident_ts(ident)
  if ts == 0L {
    return ""
  }
  format_timestamp_rfc2822(ts, "+0000")
}

///|
fn for_each_ref_ident_date_strftime(ident : String, fmt : String) -> String {
  let (ts, tz) = for_each_ref_parse_ident_ts(ident)
  if ts == 0L {
    return ""
  }
  format_timestamp_strftime(ts, tz, fmt)
}

///|
fn for_each_ref_ident_date_strftime_local(
  ident : String,
  fmt : String,
) -> String {
  let (ts, _tz) = for_each_ref_parse_ident_ts(ident)
  if ts == 0L {
    return ""
  }
  format_timestamp_strftime(ts, "+0000", fmt)
}

///|
fn format_timestamp_strftime(ts : Int64, tz : String, fmt : String) -> String {
  let (year, month, day, hour, minute, second) = epoch_to_calendar(ts, tz)
  let dow = day_of_week(year, month, day)
  let dow_names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  let dow_full = [
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
  ]
  let month_names = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov",
    "Dec",
  ]
  let month_full = [
    "January", "February", "March", "April", "May", "June", "July", "August", "September",
    "October", "November", "December",
  ]
  let buf = StringBuilder::new()
  let chars = fmt.to_array()
  let len = chars.length()
  let mut i = 0
  while i < len {
    if chars[i] == '%' && i + 1 < len {
      i += 1
      match chars[i] {
        'Y' => buf.write_string(year.to_string())
        'y' => buf.write_string(pad2(year % 100))
        'm' => buf.write_string(pad2(month))
        'd' => buf.write_string(pad2(day))
        'e' =>
          if day < 10 {
            buf.write_string(" " + day.to_string())
          } else {
            buf.write_string(day.to_string())
          }
        'H' => buf.write_string(pad2(hour))
        'M' => buf.write_string(pad2(minute))
        'S' => buf.write_string(pad2(second))
        'a' => buf.write_string(dow_names[dow])
        'A' => buf.write_string(dow_full[dow])
        'b' | 'h' => buf.write_string(month_names[month - 1])
        'B' => buf.write_string(month_full[month - 1])
        'w' => buf.write_string(dow.to_string())
        'u' => buf.write_string((if dow == 0 { 7 } else { dow }).to_string())
        'j' => {
          let yday = day_of_year(year, month, day)
          if yday < 10 {
            buf.write_string("00" + yday.to_string())
          } else if yday < 100 {
            buf.write_string("0" + yday.to_string())
          } else {
            buf.write_string(yday.to_string())
          }
        }
        'z' => buf.write_string(tz)
        'Z' => buf.write_string("") // timezone name not available
        's' => buf.write_string(ts.to_string())
        'n' => buf.write_char('\n')
        't' => buf.write_char('\t')
        '%' => buf.write_char('%')
        'I' => {
          let h12 = if hour == 0 {
            12
          } else if hour > 12 {
            hour - 12
          } else {
            hour
          }
          buf.write_string(pad2(h12))
        }
        'l' => {
          let h12 = if hour == 0 {
            12
          } else if hour > 12 {
            hour - 12
          } else {
            hour
          }
          if h12 < 10 {
            buf.write_string(" " + h12.to_string())
          } else {
            buf.write_string(h12.to_string())
          }
        }
        'p' => buf.write_string(if hour < 12 { "AM" } else { "PM" })
        'P' => buf.write_string(if hour < 12 { "am" } else { "pm" })
        'D' => {
          buf.write_string(pad2(month))
          buf.write_char('/')
          buf.write_string(pad2(day))
          buf.write_char('/')
          buf.write_string(pad2(year % 100))
        }
        'F' => {
          buf.write_string(year.to_string())
          buf.write_char('-')
          buf.write_string(pad2(month))
          buf.write_char('-')
          buf.write_string(pad2(day))
        }
        'T' | 'X' => {
          buf.write_string(pad2(hour))
          buf.write_char(':')
          buf.write_string(pad2(minute))
          buf.write_char(':')
          buf.write_string(pad2(second))
        }
        'R' => {
          buf.write_string(pad2(hour))
          buf.write_char(':')
          buf.write_string(pad2(minute))
        }
        _ => {
          buf.write_char('%')
          buf.write_char(chars[i])
        }
      }
    } else {
      buf.write_char(chars[i])
    }
    i += 1
  }
  buf.to_string()
}

///|
fn day_of_year(year : Int, month : Int, day : Int) -> Int {
  let days_in_months = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  let is_leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
  let mut yday = 0
  for m in 0..<(month - 1) {
    yday += days_in_months[m]
    if m == 1 && is_leap {
      yday += 1
    }
  }
  yday + day
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
/// Mailmap entry: (old_email, old_name?, new_email?, new_name?)
struct MailmapEntry {
  old_email : String // case-insensitive match key (stored lowercase)
  old_name : String // optional: match only if name also matches
  new_email : String // replacement email (empty = keep original)
  new_name : String // replacement name (empty = keep original)
}

///|
fn for_each_ref_read_mailmap(
  fs : OsFs,
  git_dir : String,
) -> Array[MailmapEntry] {
  let entries : Array[MailmapEntry] = []
  // .mailmap is in worktree root (parent of .git dir)
  let worktree = if git_dir.has_suffix("/.git") {
    String::unsafe_substring(git_dir, start=0, end=git_dir.length() - 5)
  } else {
    git_dir
  }
  let data = fs.read_file(worktree + "/.mailmap") catch { _ => return entries }
  let text = decode_bytes(data)
  for line_view in text.split("\n") {
    let line = line_view.to_string()
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    let trimmed = line
    // Parse <email> occurrences
    let emails : Array[String] = []
    let email_positions : Array[(Int, Int)] = [] // (start_lt, end_gt)
    let mut pos = 0
    while pos < trimmed.length() {
      match
        String::unsafe_substring(trimmed, start=pos, end=trimmed.length()).find(
          "<",
        ) {
        Some(rel_start) => {
          let abs_start = pos + rel_start
          match
            String::unsafe_substring(
              trimmed,
              start=abs_start,
              end=trimmed.length(),
            ).find(">") {
            Some(rel_end) => {
              let abs_end = abs_start + rel_end
              emails.push(
                String::unsafe_substring(
                  trimmed,
                  start=abs_start + 1,
                  end=abs_end,
                ),
              )
              email_positions.push((abs_start, abs_end))
              pos = abs_end + 1
            }
            None => break
          }
        }
        None => break
      }
    }
    if emails.length() == 1 {
      // Form 1: Proper Name <commit@email>
      let name_part = String::unsafe_substring(
        trimmed,
        start=0,
        end=email_positions[0].0,
      )
      let new_name = for_each_ref_trim_string(name_part)
      entries.push({
        old_email: emails[0].to_lower(),
        old_name: "",
        new_email: "",
        new_name,
      })
    } else if emails.length() == 2 {
      let name_before_first = for_each_ref_trim_string(
        String::unsafe_substring(trimmed, start=0, end=email_positions[0].0),
      )
      let name_between = for_each_ref_trim_string(
        String::unsafe_substring(
          trimmed,
          start=email_positions[0].1 + 1,
          end=email_positions[1].0,
        ),
      )
      if name_before_first.length() == 0 && name_between.length() == 0 {
        // Form 2: <proper@email> <commit@email>
        entries.push({
          old_email: emails[1].to_lower(),
          old_name: "",
          new_email: emails[0],
          new_name: "",
        })
      } else if name_before_first.length() > 0 && name_between.length() == 0 {
        // Form 3: Proper Name <proper@email> <commit@email>
        entries.push({
          old_email: emails[1].to_lower(),
          old_name: "",
          new_email: emails[0],
          new_name: name_before_first,
        })
      } else if name_before_first.length() > 0 && name_between.length() > 0 {
        // Form 4: Proper Name <proper@email> Commit Name <commit@email>
        entries.push({
          old_email: emails[1].to_lower(),
          old_name: name_between,
          new_email: emails[0],
          new_name: name_before_first,
        })
      }
    }
  }
  entries
}

///|
fn for_each_ref_trim_string(s : String) -> String {
  let chars = s.to_array()
  let mut start = 0
  let mut end = chars.length()
  while start < end && (chars[start] == ' ' || chars[start] == '\t') {
    start += 1
  }
  while end > start && (chars[end - 1] == ' ' || chars[end - 1] == '\t') {
    end -= 1
  }
  if start == 0 && end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

///|
fn for_each_ref_apply_mailmap(
  ident : String,
  mailmap : Array[MailmapEntry],
) -> String {
  if ident.length() == 0 || mailmap.length() == 0 {
    return ident
  }
  let lt_pos = match ident.find("<") {
    Some(p) => p
    None => return ident
  }
  let gt_pos = match ident.find(">") {
    Some(p) => p
    None => return ident
  }
  let orig_name = for_each_ref_trim_string(
    String::unsafe_substring(ident, start=0, end=lt_pos),
  )
  let orig_email = String::unsafe_substring(ident, start=lt_pos + 1, end=gt_pos)
  let rest = String::unsafe_substring(
    ident,
    start=gt_pos + 1,
    end=ident.length(),
  )
  let orig_email_lower = orig_email.to_lower()
  for entry in mailmap {
    if entry.old_email == orig_email_lower {
      if entry.old_name.length() > 0 && entry.old_name != orig_name {
        continue
      }
      let new_name = if entry.new_name.length() > 0 {
        entry.new_name
      } else {
        orig_name
      }
      let new_email = if entry.new_email.length() > 0 {
        entry.new_email
      } else {
        orig_email
      }
      return new_name + " <" + new_email + ">" + rest
    }
  }
  ident
}

///|
fn for_each_ref_resolve_name_or_email(
  ident : String,
  kind : String,
  opts : String,
  mailmap : Array[MailmapEntry],
) -> String {
  let mut use_mailmap = false
  let mut use_trim = false
  let mut use_localpart = false
  let mut remaining = opts
  while remaining.length() > 0 {
    if remaining.has_prefix("mailmap") {
      use_mailmap = true
      remaining = String::unsafe_substring(
        remaining,
        start=7,
        end=remaining.length(),
      )
    } else if remaining.has_prefix("trim") {
      use_trim = true
      remaining = String::unsafe_substring(
        remaining,
        start=4,
        end=remaining.length(),
      )
    } else if remaining.has_prefix("localpart") {
      use_localpart = true
      remaining = String::unsafe_substring(
        remaining,
        start=9,
        end=remaining.length(),
      )
    } else if remaining.has_prefix(",") {
      remaining = String::unsafe_substring(
        remaining,
        start=1,
        end=remaining.length(),
      )
    } else {
      break
    }
  }
  let resolved_ident = if use_mailmap {
    for_each_ref_apply_mailmap(ident, mailmap)
  } else {
    ident
  }
  match kind {
    "name" => for_each_ref_ident_name(resolved_ident)
    "email" =>
      if use_localpart {
        for_each_ref_ident_email_localpart(resolved_ident)
      } else if use_trim {
        for_each_ref_ident_email_trim(resolved_ident)
      } else {
        for_each_ref_ident_email(resolved_ident)
      }
    _ => ""
  }
}

///|
