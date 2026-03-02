///|
priv struct PackObjectsConfig {
  revs : Bool
  stdout : Bool
  all : Bool
  delta_mode : @bitcore.PackDeltaMode
  window : Int
  depth : Int
  base_name : String?
  progress : Bool
  path_walk : Bool
  filter : @protocol.FilterSpec
  object_format : String?
  stdin_packs : Bool
  stdin_packs_follow : Bool
  local_only : Bool
  honor_pack_keep : Bool
  incremental : Bool
  unpacked : Bool
  exclude_promisor_objects : Bool
  name_hash_version : Int?
  write_bitmap : Bool
  include_tag : Bool
  reflog : Bool
  non_empty : Bool
  indexed_objects : Bool
  missing_mode : MissingMode
  index_version : Int
  off64_threshold : Int64?
  max_pack_size : Int64?
  cruft : Bool
  cruft_expiration : String?
  max_cruft_size : Int64?
  sparse_mode : Bool? // None=config default, Some(true)=--sparse, Some(false)=--no-sparse
  unpack_unreachable : Bool
  unpack_unreachable_expiration : Int64 // 0 = loosen all unreachable
}

///|
priv enum MissingMode {
  Error
  AllowAny
}

///|
priv enum PackReuseMode {
  Disabled
  Single
  Multi
}

///|
priv enum PackObjectsParse {
  Ok(PackObjectsConfig)
  Unsupported
  Error(String)
}

///|
fn parse_pack_objects_args(args : Array[String]) -> PackObjectsParse {
  let mut revs = false
  let mut stdout = false
  let mut all = false
  let mut delta_mode = @bitcore.PackDeltaMode::RefDelta
  let mut window = 10
  let mut depth = 50
  let mut base_name : String? = None
  let mut progress = false
  let mut path_walk = false
  let mut filter = @protocol.FilterSpec::NoFilter
  let mut object_format : String? = None
  let mut stdin_packs = false
  let mut stdin_packs_follow = false
  let mut local_only = false
  let mut honor_pack_keep = false
  let mut incremental = false
  let mut unpacked = false
  let mut exclude_promisor_objects = false
  let mut name_hash_version : Int? = None
  let mut write_bitmap = false
  let mut include_tag = false
  let mut reflog = false
  let mut non_empty = false
  let mut indexed_objects = false
  let mut missing_mode = MissingMode::Error
  let mut index_version = 2
  let mut off64_threshold : Int64? = None
  let mut max_pack_size : Int64? = None
  let mut cruft = false
  let mut cruft_expiration : String? = None
  let mut max_cruft_size : Int64? = None
  let mut sparse_mode : Bool? = None
  let mut unpack_unreachable = false
  let mut unpack_unreachable_expiration = 0L
  let mut i = 0
  let mut in_opts = true
  let mut extra_args = 0
  while i < args.length() {
    let arg = args[i]
    if in_opts && arg == "--" {
      in_opts = false
      i += 1
      continue
    }
    if in_opts && arg.has_prefix("-") {
      match arg {
        "--revs" => revs = true
        "--stdout" => stdout = true
        "--all" => all = true
        "--delta-base-offset" => delta_mode = @bitcore.PackDeltaMode::OfsDelta
        "--local" => local_only = true
        "--honor-pack-keep" => honor_pack_keep = true
        "--incremental" => incremental = true
        "--unpacked" => unpacked = true
        "--path-walk" => path_walk = true
        "--no-path-walk" => ()
        "--sparse" => sparse_mode = Some(true)
        "--no-sparse" => sparse_mode = Some(false)
        "--non-empty" => non_empty = true
        "--reflog" => reflog = true
        "--indexed-objects" => indexed_objects = true
        "--keep-true-parents" => ()
        "--thin" => revs = true // --thin implies --revs (like git)
        "--cruft" => cruft = true
        "--cruft-expiration" => {
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          cruft_expiration = Some(args[i + 1])
          i += 1
        }
        "--max-cruft-size" => {
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          max_cruft_size = Some(parse_size_with_suffix(args[i + 1]))
          i += 1
        }
        "--max-pack-size" => {
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          max_pack_size = Some(parse_size_with_suffix(args[i + 1]))
          i += 1
        }
        "--include-tag" => include_tag = true
        "--stdin-packs" => stdin_packs = true
        "--stdin-packs=follow" => {
          stdin_packs = true
          stdin_packs_follow = true
        }
        "--unpack-unreachable" => unpack_unreachable = true
        "--keep-unreachable" => ()
        "--pack-loose-unreachable" => ()
        "--keep-pack" => {
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          i += 1
        }
        "--write-bitmap-index" => write_bitmap = true
        "--progress" => progress = true
        "--no-progress" => ()
        "--use-bitmap-index" => ()
        "--no-use-bitmap-index" => ()
        "--quiet" => ()
        "-q" => ()
        "--exclude-promisor-objects" => exclude_promisor_objects = true
        "--stdin" =>
          return PackObjectsParse::Error(
            "fatal: disallowed abbreviated or ambiguous option 'stdin'",
          )
        "--object-format" => {
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          object_format = normalize_object_format(args[i + 1])
          if object_format is None {
            return PackObjectsParse::Unsupported
          }
          i += 1
        }
        "--window" => {
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          let value = args[i + 1]
          let parsed = @strconv.parse_int(value) catch {
            _ => return PackObjectsParse::Unsupported
          }
          window = parsed
          i += 1
        }
        "--depth" => {
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          let value = args[i + 1]
          let parsed = @strconv.parse_int(value) catch {
            _ => return PackObjectsParse::Unsupported
          }
          depth = parsed
          i += 1
        }
        "--name-hash-version" => {
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          let value = args[i + 1]
          let parsed = @strconv.parse_int(value) catch {
            _ => return PackObjectsParse::Unsupported
          }
          let normalized = if parsed < 0 { 1 } else { parsed }
          if normalized == 0 || normalized > 2 {
            return PackObjectsParse::Error(
              "fatal: invalid --name-hash-version option",
            )
          }
          name_hash_version = Some(normalized)
          i += 1
        }
        "--index-version" => {
          if i + 1 >= args.length() {
            return PackObjectsParse::Unsupported
          }
          match parse_index_version_value(args[i + 1]) {
            Some((iv, threshold)) => {
              index_version = iv
              off64_threshold = threshold
            }
            None =>
              return PackObjectsParse::Error("fatal: bad --index-version value")
          }
          i += 1
        }
        _ =>
          if arg.has_prefix("--window=") {
            let value = (try! arg[9:]).to_string()
            let parsed = @strconv.parse_int(value) catch {
              _ => return PackObjectsParse::Unsupported
            }
            window = parsed
          } else if arg.has_prefix("--index-version=") {
            let iv_str = (try! arg[16:]).to_string()
            match parse_index_version_value(iv_str) {
              Some((iv, threshold)) => {
                index_version = iv
                off64_threshold = threshold
              }
              None =>
                return PackObjectsParse::Error(
                  "fatal: bad --index-version value",
                )
            }
          } else if arg == "--index-version" {
            if i + 1 < args.length() {
              match parse_index_version_value(args[i + 1]) {
                Some((iv, threshold)) => {
                  index_version = iv
                  off64_threshold = threshold
                }
                None =>
                  return PackObjectsParse::Error(
                    "fatal: bad --index-version value",
                  )
              }
              i += 1
            }
          } else if arg.has_prefix("--filter=") {
            let spec = String::unsafe_substring(arg, start=9, end=arg.length())
            filter = combine_filter_specs(filter, parse_pack_filter_spec(spec))
          } else if arg == "--filter" {
            if i + 1 >= args.length() {
              return PackObjectsParse::Unsupported
            }
            filter = combine_filter_specs(
              filter,
              parse_pack_filter_spec(args[i + 1]),
            )
            i += 1
          } else if arg.has_prefix("--object-format=") {
            object_format = normalize_object_format((try! arg[16:]).to_string())
            if object_format is None {
              return PackObjectsParse::Unsupported
            }
          } else if arg.has_prefix("--name-hash-version=") {
            let value = (try! arg[20:]).to_string()
            let parsed = @strconv.parse_int(value) catch {
              _ => return PackObjectsParse::Unsupported
            }
            let normalized = if parsed < 0 { 1 } else { parsed }
            if normalized == 0 || normalized > 2 {
              return PackObjectsParse::Error(
                "fatal: invalid --name-hash-version option",
              )
            }
            name_hash_version = Some(normalized)
          } else if arg.has_prefix("--missing=") {
            let value = (try! arg[10:]).to_string()
            match value {
              "allow-any" => missing_mode = MissingMode::AllowAny
              "error" => missing_mode = MissingMode::Error
              _ => return PackObjectsParse::Unsupported
            }
          } else if arg.has_prefix("--depth=") {
            let value = (try! arg[8:]).to_string()
            let parsed = @strconv.parse_int(value) catch {
              _ => return PackObjectsParse::Unsupported
            }
            depth = parsed
          } else if arg.has_prefix("--cruft-expiration=") {
            let value = (try! arg[19:]).to_string()
            cruft_expiration = Some(value)
          } else if arg.has_prefix("--max-cruft-size=") {
            let value = (try! arg[17:]).to_string()
            max_cruft_size = Some(parse_size_with_suffix(value))
          } else if arg.has_prefix("--max-pack-size=") {
            let value = (try! arg[16:]).to_string()
            max_pack_size = Some(parse_size_with_suffix(value))
          } else if arg.has_prefix("--unpack-unreachable=") {
            let value = (try! arg[21:]).to_string()
            unpack_unreachable = true
            unpack_unreachable_expiration = parse_approxidate(value)
          } else if arg.has_prefix("--keep-pack=") {
            ()
          } else if arg.has_prefix("--no-reuse-delta") ||
            arg.has_prefix("--no-reuse-object") {
            // bit doesn't use delta or object reuse, so these are no-ops
            ()
          } else if arg.has_prefix("--stdin-packs") ||
            arg.has_prefix("--write-bitmap-index") ||
            arg.has_prefix("--threads") ||
            arg.has_prefix("--revs=") ||
            arg.has_prefix("--keep") ||
            arg.has_prefix("--reuse") ||
            arg.has_prefix("--delta-islands") {
            return PackObjectsParse::Unsupported
          } else {
            return PackObjectsParse::Unsupported
          }
      }
      i += 1
      continue
    }
    if base_name is None {
      base_name = Some(arg)
    } else {
      extra_args += 1
    }
    i += 1
  }
  if extra_args > 0 {
    return PackObjectsParse::Error("fatal: too many arguments")
  }
  if window < 0 {
    window = 0
  }
  if depth < 0 {
    depth = 0
  }
  if depth == 0 {
    delta_mode = @bitcore.PackDeltaMode::NoDelta
  }
  let has_filter = match filter {
    @protocol.FilterSpec::NoFilter => false
    _ => true
  }
  if stdin_packs && has_filter {
    return PackObjectsParse::Error(
      "fatal: options '--stdin-packs' and '--filter' cannot be used together",
    )
  }
  if stdin_packs && revs {
    return PackObjectsParse::Error(
      "fatal: cannot use internal rev list with --stdin-packs",
    )
  }
  if !stdout && base_name is None {
    return PackObjectsParse::Unsupported
  }
  PackObjectsParse::Ok({
    revs,
    stdout,
    all,
    delta_mode,
    window,
    depth,
    base_name,
    progress,
    path_walk,
    filter,
    object_format,
    stdin_packs,
    stdin_packs_follow,
    local_only,
    honor_pack_keep,
    incremental,
    unpacked,
    exclude_promisor_objects,
    name_hash_version,
    write_bitmap,
    include_tag,
    reflog,
    non_empty,
    indexed_objects,
    missing_mode,
    index_version,
    off64_threshold,
    max_pack_size,
    cruft,
    cruft_expiration,
    max_cruft_size,
    sparse_mode,
    unpack_unreachable,
    unpack_unreachable_expiration,
  })
}

///|
/// Parse --index-version value. Returns (version, off64_threshold) pair.
/// Accepts "N" or "N,OFFSET" where N is 1 or 2 and OFFSET is a valid number.
/// Returns None if the value is malformed.
fn parse_index_version_value(s : String) -> (Int, Int64?)? {
  if s.contains(",") {
    let comma_pos = s.find(",").unwrap()
    let num_str = (try! s[:comma_pos]).to_string()
    let offset_str = String::unsafe_substring(
      s,
      start=comma_pos + 1,
      end=s.length(),
    )
    if offset_str.length() == 0 {
      return None
    }
    let offset = @strconv.parse_int64(offset_str) catch { _ => return None }
    let iv = @strconv.parse_int(num_str) catch { _ => return None }
    if iv == 1 || iv == 2 {
      Some((iv, Some(offset)))
    } else {
      None
    }
  } else {
    let iv = @strconv.parse_int(s) catch { _ => return None }
    if iv == 1 || iv == 2 {
      Some((iv, None))
    } else {
      None
    }
  }
}

///|
/// Combine two filter specs: when both are BlobLimit, pick the smaller limit.
/// Otherwise, the new filter overrides the old one.
fn combine_filter_specs(
  old : @protocol.FilterSpec,
  new_ : @protocol.FilterSpec,
) -> @protocol.FilterSpec {
  match (old, new_) {
    (NoFilter, _) => new_
    (_, NoFilter) => old
    (BlobLimit(a), BlobLimit(b)) =>
      @protocol.FilterSpec::BlobLimit(if a < b { a } else { b })
    (BlobNone, BlobLimit(_)) => @protocol.FilterSpec::BlobNone
    (BlobLimit(_), BlobNone) => @protocol.FilterSpec::BlobNone
    _ => new_
  }
}

///|
fn parse_size_with_suffix(s : String) -> Int64 {
  if s.length() == 0 {
    return 0L
  }
  let last = s[s.length() - 1]
  if last == 'k' || last == 'K' {
    let num_str = String::unsafe_substring(s, start=0, end=s.length() - 1)
    let num = @strconv.parse_int64(num_str) catch { _ => 0L }
    num * 1024L
  } else if last == 'm' || last == 'M' {
    let num_str = String::unsafe_substring(s, start=0, end=s.length() - 1)
    let num = @strconv.parse_int64(num_str) catch { _ => 0L }
    num * 1024L * 1024L
  } else if last == 'g' || last == 'G' {
    let num_str = String::unsafe_substring(s, start=0, end=s.length() - 1)
    let num = @strconv.parse_int64(num_str) catch { _ => 0L }
    num * 1024L * 1024L * 1024L
  } else {
    @strconv.parse_int64(s) catch {
      _ => 0L
    }
  }
}

///|
fn parse_pack_filter_spec(spec : String) -> @protocol.FilterSpec {
  if spec == "blob:none" {
    @protocol.FilterSpec::BlobNone
  } else if spec.has_prefix("blob:limit=") {
    let limit_str = String::unsafe_substring(spec, start=11, end=spec.length())
    let limit = parse_size_with_suffix(limit_str)
    @protocol.FilterSpec::BlobLimit(limit)
  } else if spec.has_prefix("tree:") {
    let depth_str = String::unsafe_substring(spec, start=5, end=spec.length())
    let depth = @strconv.parse_int(depth_str) catch { _ => 0 }
    @protocol.FilterSpec::TreeDepth(depth)
  } else if spec.has_prefix("sparse:path=") {
    // sparse:path has been dropped for security reasons - return error indicator
    @protocol.FilterSpec::SparsePathUnsupported
  } else if spec.has_prefix("sparse:oid=") {
    let oid_str = String::unsafe_substring(spec, start=11, end=spec.length())
    @protocol.FilterSpec::SparseOid(oid_str)
  } else {
    @protocol.FilterSpec::NoFilter
  }
}

///|
/// Apply filter specification to objects
fn apply_pack_filter_spec(
  objects : Array[@bitcore.PackObject],
  filter : @protocol.FilterSpec,
) -> Array[@bitcore.PackObject] {
  match filter {
    NoFilter => objects
    BlobNone => {
      // Exclude all blobs
      let result : Array[@bitcore.PackObject] = []
      for obj in objects {
        if obj.obj_type != @bitcore.ObjectType::Blob {
          result.push(obj)
        }
      }
      result
    }
    BlobLimit(max_size) => {
      // Exclude blobs with size >= max_size (strictly less than)
      let result : Array[@bitcore.PackObject] = []
      for obj in objects {
        if obj.obj_type != @bitcore.ObjectType::Blob ||
          obj.data.length().to_int64() < max_size {
          result.push(obj)
        }
      }
      result
    }
    TreeDepth(depth) =>
      if depth == 0 {
        // tree:0 means exclude all trees and blobs (commits only)
        let result : Array[@bitcore.PackObject] = []
        for obj in objects {
          if obj.obj_type != @bitcore.ObjectType::Tree &&
            obj.obj_type != @bitcore.ObjectType::Blob {
            result.push(obj)
          }
        }
        result
      } else {
        // tree:N (N>0) - not yet implemented, pass through
        objects
      }
    SparseOid(_) =>
      // sparse:oid filtering requires resolving the oid to get the sparse spec;
      // handled separately in apply_sparse_oid_filter
      objects
    SparsePathUnsupported => objects // should not reach here; caught earlier
  }
}

///|
/// Apply sparse:oid filter. Resolves the oid-ish to a blob containing
/// sparse-checkout patterns, then filters objects to keep only blobs whose
/// paths match the patterns (plus all non-blob objects).
fn apply_sparse_oid_filter(
  fs : OsFs,
  git_dir : String,
  db : @bitlib.ObjectDb,
  objects : Array[@bitcore.PackObject],
  oid_spec : String,
) -> Array[@bitcore.PackObject] {
  // Resolve the oid-ish to get the sparse pattern blob
  let pattern_id = @bitrepo.rev_parse(fs, git_dir, oid_spec) catch { _ => None }
  let pattern_id = match pattern_id {
    Some(id) => id
    None => return objects
  }
  let pattern_obj = db.get(fs, pattern_id) catch { _ => None }
  let pattern_data = match pattern_obj {
    Some(obj) => obj.data
    None => return objects
  }
  // Parse sparse-checkout patterns from blob content
  let pattern_str = @utf8.decode_lossy(pattern_data[:])
  let patterns : Array[String] = []
  let lines = pattern_str.split("\n")
  lines.each(fn(line) {
    let s = line.to_string().trim().to_string()
    if s.length() > 0 && !s.has_prefix("#") {
      patterns.push(s)
    }
  })
  if patterns.length() == 0 {
    return objects
  }
  // Build a set of blob IDs that match the sparse patterns
  // We need to walk all commits' trees to determine which blobs match
  let matching_blob_ids : Map[String, Bool] = {}
  for obj in objects {
    if obj.obj_type == @bitcore.ObjectType::Commit {
      let info = @bitcore.parse_commit(obj.data) catch { _ => continue }
      let tree_files = @bitlib.collect_tree_files(db, fs, info.tree) catch {
        _ => continue
      }
      for path, entry in tree_files {
        if sparse_path_matches(path, patterns) {
          matching_blob_ids[entry.id.to_hex()] = true
        }
      }
    }
  }
  // Filter: keep non-blobs and matching blobs
  let result : Array[@bitcore.PackObject] = []
  for obj in objects {
    if obj.obj_type != @bitcore.ObjectType::Blob ||
      matching_blob_ids.contains(obj.id.to_hex()) {
      result.push(obj)
    }
  }
  result
}

///|
/// Check if a path matches any of the sparse-checkout patterns.
/// Sparse-checkout cone-mode patterns: a trailing '/' means include
/// everything under that directory.
fn sparse_path_matches(path : String, patterns : Array[String]) -> Bool {
  for pattern in patterns {
    if pattern.has_suffix("/") {
      // Directory pattern: include all files under this directory
      if path.has_prefix(pattern) {
        return true
      }
      // Exact file match
    } else if path == pattern {
      return true
    }
  }
  false
}

///|
fn split_lines_bytes(input : Bytes) -> Array[BytesView] {
  let out : Array[BytesView] = []
  let len = input.length()
  let mut start = 0
  for i in 0..<len {
    if input[i] == b'\n' {
      let mut end = i
      if end > start && input[end - 1] == b'\r' {
        end -= 1
      }
      out.push(input[start:end])
      start = i + 1
    }
  }
  let mut end = len
  if end > start && input[end - 1] == b'\r' {
    end -= 1
  }
  out.push(input[start:end])
  out
}

///|
fn is_space_byte(b : Byte) -> Bool {
  b == b' ' || b == b'\t' || b == b'\r'
}

///|
fn trim_line_bytes(line : BytesView) -> BytesView {
  let mut start = 0
  let mut end = line.length()
  while start < end && is_space_byte(line[start]) {
    start += 1
  }
  while end > start && is_space_byte(line[end - 1]) {
    end -= 1
  }
  line[start:end]
}

///|
fn hex_byte_to_int(b : Byte) -> Int? {
  if b >= b'0' && b <= b'9' {
    return Some((b - b'0').to_int())
  }
  if b >= b'a' && b <= b'f' {
    return Some((b - b'a').to_int() + 10)
  }
  if b >= b'A' && b <= b'F' {
    return Some((b - b'A').to_int() + 10)
  }
  None
}

///|
fn parse_object_id_bytes(line : BytesView) -> @bitcore.ObjectId? {
  let trimmed = trim_line_bytes(line)
  if trimmed.length() == 0 {
    return None
  }
  let mut end = trimmed.length()
  for i in 0..<trimmed.length() {
    if is_space_byte(trimmed[i]) {
      end = i
      break
    }
  }
  let mut hex_view = trimmed[:end]
  if hex_view.length() > 0 && (hex_view[0] == b'-' || hex_view[0] == b'^') {
    hex_view = hex_view[1:hex_view.length()]
  }
  if hex_view.length() != 40 {
    return None
  }
  let bytes = FixedArray::make(20, b'\x00')
  for i in 0..<20 {
    let hi = hex_byte_to_int(hex_view[i * 2])
    let lo = hex_byte_to_int(hex_view[i * 2 + 1])
    match (hi, lo) {
      (Some(h), Some(l)) => bytes[i] = ((h << 4) | l).to_byte()
      _ => return None
    }
  }
  bytes |> @bitcore.ObjectId::new |> Some
}

///|
fn looks_like_sha256_line(line : BytesView) -> Bool {
  let trimmed = trim_line_bytes(line)
  if trimmed.length() == 0 {
    return false
  }
  let mut start = 0
  if trimmed[0] == b'^' {
    start = 1
  }
  if trimmed.length() < start + 64 {
    return false
  }
  for i in 0..<64 {
    if hex_byte_to_int(trimmed[start + i]) is None {
      return false
    }
  }
  true
}

///|
fn line_to_string(line : BytesView) -> String {
  let decoder = @encoding.decoder(@encoding.Encoding::UTF8)
  decoder.decode_lossy(line)
}

///|
fn invalid_object_line_message(line : String) -> String {
  if line.length() == 0 {
    "fatal: expected object ID, got garbage:\n \n\n"
  } else {
    "fatal: expected object ID, got garbage:\n " + line + "\n\n"
  }
}

///|
fn parse_tag_target_id(data : Bytes) -> @bitcore.ObjectId? {
  let lines = split_lines_bytes(data)
  for line in lines {
    let trimmed = trim_line_bytes(line)
    if trimmed.length() == 0 {
      break
    }
    let text = line_to_string(trimmed)
    if text.has_prefix("object ") {
      let hex = (try! text[7:]).to_string()
      let id = @bitcore.ObjectId::from_hex(hex) catch { _ => return None }
      return Some(id)
    }
  }
  None
}

///|
fn resolve_tag_chain(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  start : @bitcore.ObjectId,
) -> (Array[@bitcore.PackObject], @bitcore.ObjectId?) {
  let chain : Array[@bitcore.PackObject] = []
  let seen : Map[String, Bool] = {}
  let mut current = start
  let mut resolved : @bitcore.ObjectId? = None
  while true {
    let key = current.to_hex()
    if seen.contains(key) {
      resolved = None
      break
    }
    seen[key] = true
    let obj = try db.get(fs, current) catch {
      _ => None
    } noraise {
      value => value
    }
    match obj {
      Some(o) if o.obj_type == @bitcore.ObjectType::Tag => {
        chain.push(o)
        match parse_tag_target_id(o.data) {
          Some(next) => {
            current = next
            continue
          }
          None => {
            resolved = None
            break
          }
        }
      }
      Some(_) => {
        resolved = Some(current)
        break
      }
      None => {
        resolved = None
        break
      }
    }
  }
  (chain, resolved)
}

///|
fn collect_include_tag_objects(
  fs : OsFs,
  git_dir : String,
  db : @bitlib.ObjectDb,
  objects : Array[@bitcore.PackObject],
) -> Array[@bitcore.PackObject] {
  let included : Map[String, Bool] = {}
  for obj in objects {
    included[object_hex(obj)] = true
  }
  let refs = @bitrepo.show_ref(fs, git_dir) catch { _ => [] }
  let added : Map[String, Bool] = {}
  let out : Array[@bitcore.PackObject] = []
  for pair in refs {
    let (_name, id) = pair
    let (chain, target) = resolve_tag_chain(db, fs, id)
    match target {
      Some(t) if included.contains(t.to_hex()) =>
        for tag in chain {
          let tag_hex = object_hex(tag)
          if added.contains(tag_hex) {
            continue
          }
          added[tag_hex] = true
          included[tag_hex] = true
          out.push(tag)
        }
      _ => ()
    }
  }
  out
}

///|
fn parse_stdin_pack_lines(input : Bytes) -> (Array[String], Array[String]) {
  let lines = split_lines_bytes(input)
  let include_names : Array[String] = []
  let exclude_names : Array[String] = []
  for line in lines {
    let trimmed = trim_line_bytes(line)
    if trimmed.length() == 0 {
      continue
    }
    let text = line_to_string(trimmed)
    if text.has_prefix("^") {
      exclude_names.push((try! text[1:]).to_string())
    } else {
      include_names.push(text)
    }
  }
  // Git sorts pack names by OID ordering before processing.
  // This ensures the error message for missing packs is deterministic.
  include_names.sort_by(fn(a, b) { a.compare(b) })
  exclude_names.sort_by(fn(a, b) { a.compare(b) })
  (include_names, exclude_names)
}

///|
fn parse_pack_index_ids(data : Bytes) -> Array[String]? {
  if data.length() < 8 {
    return None
  }
  let magic = read_u32_be_i64(data, 0)
  if magic != 0xff744f63L {
    return None
  }
  let version = read_u32_be_i64(data, 4)
  if version != 2L {
    return None
  }
  let mut offset = 8
  let mut count64 = 0L
  for _ in 0..<256 {
    if offset + 4 > data.length() {
      return None
    }
    count64 = read_u32_be_i64(data, offset)
    offset += 4
  }
  if count64 > 2147483647L {
    return None
  }
  let count = count64.to_int()
  let ids : Array[String] = []
  for _ in 0..<count {
    if offset + 20 > data.length() {
      return None
    }
    let bytes : FixedArray[Byte] = FixedArray::make(20, b'\x00')
    for i in 0..<20 {
      bytes[i] = data[offset + i]
    }
    offset += 20
    ids.push(@bitcore.ObjectId::new(bytes).to_hex())
  }
  Some(ids)
}

///|
fn normalize_dir_entry(entry : String) -> String {
  match entry.rev_find("/") {
    None => entry
    Some(pos) =>
      if pos + 1 >= entry.length() {
        ""
      } else {
        (try! entry[pos + 1:]).to_string()
      }
  }
}

///|
fn collect_pack_index_ids(fs : OsFs, idx_path : String) -> Array[String] {
  let data = fs.read_file(idx_path) catch { _ => return [] }
  match parse_pack_index_ids(data) {
    Some(ids) => ids
    None => []
  }
}

///|
fn collect_pack_ids_from_dir(fs : OsFs, pack_dir : String) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  if !fs.is_dir(pack_dir) {
    return out
  }
  let entries = fs.readdir(pack_dir) catch { _ => [] }
  for entry in entries {
    let name = normalize_dir_entry(entry)
    if not(name.has_suffix(".idx")) {
      continue
    }
    let idx_path = pack_dir + "/" + name
    if not(fs.is_file(idx_path)) {
      continue
    }
    let ids = collect_pack_index_ids(fs, idx_path)
    for id in ids {
      out[id] = true
    }
  }
  out
}

///|
fn collect_pack_ids_from_marker(
  fs : OsFs,
  pack_dir : String,
  suffix : String,
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  if !fs.is_dir(pack_dir) {
    return out
  }
  let entries = fs.readdir(pack_dir) catch { _ => [] }
  for entry in entries {
    let name = normalize_dir_entry(entry)
    if not(name.has_suffix(suffix)) {
      continue
    }
    let base = (try! name[:name.length() - suffix.length()]).to_string()
    let idx_path = pack_dir + "/" + base + ".idx"
    if not(fs.is_file(idx_path)) {
      continue
    }
    let ids = collect_pack_index_ids(fs, idx_path)
    for id in ids {
      out[id] = true
    }
  }
  out
}

///|
fn collect_loose_object_ids(
  fs : OsFs,
  objects_dir : String,
) -> Map[String, Bool] {
  let out : Map[String, Bool] = {}
  if !fs.is_dir(objects_dir) {
    return out
  }
  let entries = fs.readdir(objects_dir) catch { _ => [] }
  for entry in entries {
    let name = normalize_dir_entry(entry)
    if name == "info" || name == "pack" {
      continue
    }
    if name.length() != 2 || (name |> is_hex_string |> not) {
      continue
    }
    let subdir = objects_dir + "/" + name
    if !fs.is_dir(subdir) {
      continue
    }
    let files = fs.readdir(subdir) catch { _ => [] }
    for file in files {
      let filename = normalize_dir_entry(file)
      if filename.length() != 38 || (filename |> is_hex_string |> not) {
        continue
      }
      out[name + filename] = true
    }
  }
  out
}

///|
fn read_alternate_object_dirs(fs : OsFs, git_dir : String) -> Array[String] {
  let out : Array[String] = []
  let alt_path = git_dir + "/objects/info/alternates"
  if not(fs.is_file(alt_path)) {
    return out
  }
  let data = fs.read_file(alt_path) catch { _ => return out }
  // git resolves relative paths in alternates relative to the objects directory
  let base_dir = git_dir + "/objects"
  let lines = split_lines_bytes(data)
  for line in lines {
    let trimmed = trim_line_bytes(line)
    if trimmed.length() == 0 {
      continue
    }
    let text = line_to_string(trimmed)
    if text.has_prefix("#") {
      continue
    }
    let resolved = if text.has_prefix("/") {
      text
    } else {
      normalize_path(base_dir + "/" + text)
    }
    if fs.is_dir(resolved) {
      out.push(resolved)
    }
  }
  out
}

///|
fn load_object_lookup_dbs(
  fs : OsFs,
  git_dir : String,
  primary : @bitlib.ObjectDb,
) -> Array[@bitlib.ObjectDb] {
  let out : Array[@bitlib.ObjectDb] = [primary]
  let seen : Map[String, Bool] = {}
  seen[normalize_path(primary.objects_dir)] = true
  let alt_dirs = read_alternate_object_dirs(fs, git_dir)
  for alt_dir in alt_dirs {
    let normalized = normalize_path(alt_dir)
    if seen.contains(normalized) {
      continue
    }
    let alt_db = @bitlib.ObjectDb::load_from_objects_dir(fs, alt_dir) catch {
      _ => continue
    }
    seen[normalized] = true
    out.push(alt_db)
  }
  out
}

///|
fn find_object_in_lookup_dbs(
  dbs : Array[@bitlib.ObjectDb],
  fs : OsFs,
  id : @bitcore.ObjectId,
) -> @bitcore.PackObject? {
  for db in dbs {
    let obj = db.get(fs, id) catch { _ => None }
    if obj is Some(found) {
      return Some(found)
    }
  }
  None
}

///|
fn resolve_pack_path(
  fs : OsFs,
  pack_dir : String,
  alt_objects_dirs : Array[String],
  name : String,
) -> String? {
  let mut pack_name = name
  if pack_name.has_suffix(".idx") {
    pack_name = (try! pack_name[:pack_name.length() - 4]).to_string() + ".pack"
  }
  if pack_name.has_prefix("/") || pack_name.contains("/") {
    let path = resolve_in_cwd(pack_name)
    if fs.is_file(path) {
      return Some(path)
    }
  }
  let local_path = pack_dir + "/" + pack_name
  if fs.is_file(local_path) {
    return Some(local_path)
  }
  for alt_dir in alt_objects_dirs {
    let alt_pack_dir = alt_dir + "/pack"
    let alt_path = alt_pack_dir + "/" + pack_name
    if fs.is_file(alt_path) {
      return Some(alt_path)
    }
  }
  None
}

///|
fn read_pack_objects(
  fs : OsFs,
  pack_path : String,
) -> Array[@bitcore.PackObject] {
  let data = fs.read_file(pack_path) catch { _ => return [] }
  @pack.parse_packfile(data) catch {
    _ => []
  }
}

///|
fn object_hex(obj : @bitcore.PackObject) -> String {
  @bitcore.hash_object_content(obj.obj_type, obj.data).to_hex()
}

///|
fn dedup_objects(
  objects : Array[@bitcore.PackObject],
) -> Array[@bitcore.PackObject] {
  let seen : Map[String, Bool] = {}
  let out : Array[@bitcore.PackObject] = []
  for obj in objects {
    let hex = object_hex(obj)
    if not(seen.contains(hex)) {
      seen[hex] = true
      out.push(obj)
    }
  }
  out
}

///|
fn sort_stdin_object_mode_objects(objects : Array[@bitcore.PackObject]) -> Unit {
  // Sort by type, then by size descending within same type.
  // Larger objects first ensures smaller objects can delta against them
  // (matching Git's pack-objects sorting behavior).
  objects.sort_by(fn(a, b) {
    let a_type = a.obj_type.to_packfile_type()
    let b_type = b.obj_type.to_packfile_type()
    if a_type != b_type {
      a_type - b_type
    } else {
      b.data.length() - a.data.length()
    }
  })
}

///|
fn filter_objects(
  objects : Array[@bitcore.PackObject],
  exclude : Map[String, Bool],
) -> Array[@bitcore.PackObject] {
  if exclude.length() == 0 {
    return objects
  }
  let out : Array[@bitcore.PackObject] = []
  for obj in objects {
    let hex = object_hex(obj)
    if not(exclude.contains(hex)) {
      out.push(obj)
    }
  }
  out
}

///|
async fn report_collect_error(err : @bitcore.GitError) -> Unit {
  match err {
    @bitcore.GitError::InvalidObject(msg) =>
      if msg.contains("Missing tree object") {
        @stdio.stderr.write("fatal: bad tree object\n")
      } else if msg.contains("Missing commit object") {
        @stdio.stderr.write("fatal: bad commit object\n")
      } else if msg.contains("Missing blob object") {
        @stdio.stderr.write("fatal: missing blob object\n")
      } else {
        @stdio.stderr.write("fatal: " + msg + "\n")
      }
    @bitcore.GitError::HashMismatch(expected, actual) =>
      @stdio.stderr.write(
        "fatal: hash mismatch (expected " + expected + ", got " + actual + ")\n",
      )
    @bitcore.GitError::PackfileError(msg) =>
      @stdio.stderr.write("fatal: " + msg + "\n")
    @bitcore.GitError::ProtocolError(msg) =>
      @stdio.stderr.write("fatal: " + msg + "\n")
    @bitcore.GitError::IoError(msg) =>
      @stdio.stderr.write("fatal: " + msg + "\n")
  }
  @sys.exit(1)
}

///|
/// Write a trace2 "data" event to the trace2 event file.
fn write_trace2_data_event(
  fs : OsFs,
  trace2_path : String,
  category : String,
  key : String,
  value : String,
) -> Unit {
  let json_line = "{\"event\":\"data\",\"category\":\"" +
    category +
    "\",\"key\":\"" +
    key +
    "\",\"value\":\"" +
    value +
    "\"}\n"
  append_text_file(fs, trace2_path, json_line)
}

///|
fn get_pack_reuse_mode(git_dir : String) -> PackReuseMode {
  // Check config override first
  match get_config_override("pack.allowPackReuse") {
    Some(value) => {
      let v = value.trim().to_string().to_lower()
      if v == "multi" {
        return PackReuseMode::Multi
      }
      if v == "single" || v == "true" || v == "1" {
        return PackReuseMode::Single
      }
      if v == "false" || v == "0" {
        return PackReuseMode::Disabled
      }
      return PackReuseMode::Single
    }
    None => ()
  }
  // Check git config
  match bit_config_get(git_dir, "pack", "allowPackReuse") {
    Some(value) => {
      let v = value.trim().to_string().to_lower()
      if v == "multi" {
        return PackReuseMode::Multi
      }
      if v == "single" || v == "true" || v == "1" {
        return PackReuseMode::Single
      }
      if v == "false" || v == "0" {
        return PackReuseMode::Disabled
      }
      return PackReuseMode::Single
    }
    None => ()
  }
  // Check feature.experimental
  match get_config_override("feature.experimental") {
    Some(value) =>
      match parse_bool_value(value) {
        Some(true) => return PackReuseMode::Multi
        _ => ()
      }
    None => ()
  }
  match bit_config_get(git_dir, "feature", "experimental") {
    Some(value) =>
      match parse_bool_value(value) {
        Some(true) => return PackReuseMode::Multi
        _ => ()
      }
    None => ()
  }
  // Default: single-pack reuse
  PackReuseMode::Single
}

///|
/// Read MIDX to build object_hex -> pack_idx mapping
/// Read object -> (pack_idx, offset_in_pack) mapping from MIDX OIDL+OOFF chunks.
fn midx_read_object_pack_mapping_with_offsets(
  data : Bytes,
) -> Map[String, (Int, Int)] {
  let out : Map[String, (Int, Int)] = {}
  if data.length() < 12 {
    return out
  }
  let num_chunks = data[6].to_int()
  let oidf_offset = midx_find_chunk(data, num_chunks, "OIDF")
  let oidf_end = midx_find_chunk_end(data, num_chunks, "OIDF")
  if oidf_offset <= 0 || oidf_end - oidf_offset != 256 * 4 {
    return out
  }
  let object_count = midx_read_u32(data, oidf_offset + 255 * 4)
  if object_count <= 0 {
    return out
  }
  let oidl_offset = midx_find_chunk(data, num_chunks, "OIDL")
  let ooff_offset = midx_find_chunk(data, num_chunks, "OOFF")
  if oidl_offset <= 0 || ooff_offset <= 0 {
    return out
  }
  for i in 0..<object_count {
    let oid = @bitcore.ObjectId::new(
      FixedArray::makei(20, fn(j) { data[oidl_offset + i * 20 + j] }),
    )
    let pack_idx = midx_read_u32(data, ooff_offset + i * 8)
    let offset = midx_read_u32(data, ooff_offset + i * 8 + 4)
    out[oid.to_hex()] = (pack_idx, offset)
  }
  out
}

///|
/// Read preferred pack index from MIDX BTMP chunk.
/// The preferred pack is the one with bitmap_position = 0 (rank 0).
fn midx_read_preferred_pack_idx(data : Bytes, num_packs : Int) -> Int? {
  if data.length() < 12 || num_packs <= 0 {
    return None
  }
  let num_chunks = data[6].to_int()
  let btmp_offset = midx_find_chunk(data, num_chunks, "BTMP")
  if btmp_offset <= 0 {
    return None
  }
  // BTMP format: 8 bytes per pack (4 bytes bitmap_pos + 4 bytes count)
  // The preferred pack has bitmap_pos = 0
  for i in 0..<num_packs {
    let bitmap_pos = midx_read_u32(data, btmp_offset + i * 8)
    let count = midx_read_u32(data, btmp_offset + i * 8 + 4)
    if bitmap_pos == 0 && count > 0 {
      return Some(i)
    }
  }
  // Fallback: if no pack has bitmap_pos=0 with objects, return pack 0
  Some(0)
}

///|
/// Returns (pack-reused count, packs-reused count)
fn count_pack_reused_objects(
  fs : OsFs,
  git_dir : String,
  pack_dir : String,
  objects : Array[@bitcore.PackObject],
) -> (Int, Int) {
  let reuse_mode = get_pack_reuse_mode(git_dir)
  if reuse_mode is Disabled {
    return (0, 0)
  }
  // Try MIDX path first
  let midx_path = pack_dir + "/multi-pack-index"
  let midx_data = fs.read_file(midx_path) catch { _ => Bytes::new(0) }
  if midx_data.length() > 0 && has_midx_bitmap(fs, pack_dir) {
    let pack_info = midx_read_pack_usage_from_data(midx_data)
    match pack_info {
      Some((pack_names, _counts)) => {
        // Read object -> (pack_idx, offset) mapping from MIDX
        let obj_to_pack = midx_read_object_pack_mapping_with_offsets(midx_data)
        // Determine eligible pack indices based on reuse mode
        let eligible : Map[Int, Bool] = {}
        match reuse_mode {
          Single => {
            let preferred = midx_read_preferred_pack_idx(
              midx_data,
              pack_names.length(),
            )
            match preferred {
              Some(idx) => eligible[idx] = true
              None => eligible[0] = true
            }
          }
          Multi =>
            for i in 0..<pack_names.length() {
              eligible[i] = true
            }
          Disabled => ()
        }
        // Build per-pack set of offsets assigned by MIDX
        let pack_assigned_offsets : Map[Int, Map[Int, Bool]] = {}
        for entry in obj_to_pack {
          let (_, (pidx, off)) = entry
          if eligible.contains(pidx) {
            match pack_assigned_offsets.get(pidx) {
              Some(offsets) => offsets[off] = true
              None => {
                let m : Map[Int, Bool] = {}
                m[off] = true
                pack_assigned_offsets[pidx] = m
              }
            }
          }
        }
        // Cache pack file data for eligible packs (lazy load)
        let pack_data_cache : Map[Int, Bytes] = {}
        // Count reused objects, excluding OFS_DELTA with cross-pack base
        let mut reused = 0
        let packs_used : Map[Int, Bool] = {}
        for obj in objects {
          let hex = obj.id.to_hex()
          match obj_to_pack.get(hex) {
            Some((pack_idx, offset)) =>
              if eligible.contains(pack_idx) {
                if can_reuse_pack_object(
                    fs, pack_dir, pack_names, pack_idx, offset, pack_assigned_offsets,
                    pack_data_cache,
                  ) {
                  reused += 1
                  packs_used[pack_idx] = true
                }
              }
            None => ()
          }
        }
        let packs_count = packs_used.length()
        return (reused, packs_count)
      }
      None => ()
    }
  }
  // Fallback: single-pack bitmap
  count_single_pack_reused_objects(fs, pack_dir, objects)
}

///|
/// Check if an object at the given offset in a pack can be reused.
/// OFS_DELTA objects whose base is assigned to a different pack cannot be reused.
fn can_reuse_pack_object(
  fs : OsFs,
  pack_dir : String,
  pack_names : Array[String],
  pack_idx : Int,
  offset : Int,
  pack_assigned_offsets : Map[Int, Map[Int, Bool]],
  pack_data_cache : Map[Int, Bytes],
) -> Bool {
  // Lazily load pack data
  let pack_data = match pack_data_cache.get(pack_idx) {
    Some(data) => data
    None => {
      let pack_path = pack_dir + "/" + pack_names[pack_idx]
      let data = fs.read_file(pack_path) catch { _ => return true }
      pack_data_cache[pack_idx] = data
      data
    }
  }
  if offset >= pack_data.length() {
    return true
  }
  // Decode type at this offset
  let (type_id, _, header_end) = @pack.decode_type_and_size_at(
    pack_data, offset,
  ) catch {
    _ => return true
  }
  // Only OFS_DELTA (type 6) needs cross-pack base checking
  if type_id != 6 {
    return true
  }
  // Read the back-offset for this OFS_DELTA
  let (back_offset, _) = @pack.read_ofs_delta_offset(pack_data, header_end) catch {
    _ => return true
  }
  let base_offset = offset - back_offset
  // Check if the base offset is assigned to this same pack in MIDX
  match pack_assigned_offsets.get(pack_idx) {
    Some(offsets) => offsets.contains(base_offset)
    None => false
  }
}

///|
/// Find a pack file that has a corresponding .bitmap file (non-MIDX).
fn find_pack_with_bitmap(fs : OsFs, pack_dir : String) -> String? {
  if !fs.is_dir(pack_dir) {
    return None
  }
  let entries = fs.readdir(pack_dir) catch { _ => return None }
  // Collect .bitmap files that are NOT multi-pack-index bitmaps
  let bitmap_stems : Map[String, Bool] = {}
  for entry in entries {
    let name = normalize_dir_entry(entry)
    if name.has_suffix(".bitmap") && !name.has_prefix("multi-pack-index") {
      // e.g. "pack-abc123.bitmap" → "pack-abc123"
      let stem = (try! name[:name.length() - 7]).to_string()
      bitmap_stems[stem] = true
    }
  }
  // Find the .pack file whose stem matches a bitmap
  for entry in entries {
    let name = normalize_dir_entry(entry)
    if name.has_suffix(".pack") && !name.has_prefix(".") {
      let stem = (try! name[:name.length() - 5]).to_string()
      if bitmap_stems.contains(stem) {
        return Some(name)
      }
    }
  }
  None
}

///|
/// Fallback pack-reuse counting for single-pack bitmap (no MIDX).
fn count_single_pack_reused_objects(
  fs : OsFs,
  pack_dir : String,
  objects : Array[@bitcore.PackObject],
) -> (Int, Int) {
  let pack_name = match find_pack_with_bitmap(fs, pack_dir) {
    Some(name) => name
    None => return (0, 0)
  }
  let idx_path = pack_idx_path(pack_dir + "/" + pack_name)
  // Read OIDs from the pack index
  let entries = midx_read_pack_index(fs, idx_path, 0, 0)
  if entries.length() == 0 {
    return (0, 0)
  }
  let pack_oids : Map[String, Bool] = {}
  for entry in entries {
    pack_oids[entry.id.to_hex()] = true
  }
  let mut reused = 0
  for obj in objects {
    if pack_oids.contains(obj.id.to_hex()) {
      reused += 1
    }
  }
  (reused, if reused > 0 { 1 } else { 0 })
}

///|
fn has_midx_bitmap(fs : OsFs, pack_dir : String) -> Bool {
  if !fs.is_dir(pack_dir) {
    return false
  }
  let entries = fs.readdir(pack_dir) catch { _ => return false }
  for entry in entries {
    let name = normalize_dir_entry(entry)
    if name.has_prefix("multi-pack-index") && name.has_suffix(".bitmap") {
      return true
    }
  }
  false
}

///|
fn pack_idx_path(pack_path : String) -> String {
  if pack_path.has_suffix(".pack") {
    let base = (try! pack_path[:pack_path.length() - 5]).to_string()
    base + ".idx"
  } else {
    pack_path + ".idx"
  }
}

///|
fn corrupt_pack_file(fs : OsFs, pack_path : String) -> Unit {
  try {
    let data = fs.read_file(pack_path)
    if data.length() == 0 {
      return
    }
    let bytes : FixedArray[Byte] = FixedArray::makei(data.length(), fn(i) {
      data[i]
    })
    let last = data.length() - 1
    let v = bytes[last].to_int()
    bytes[last] = (v ^ 1).to_byte()
    fs.write_file(pack_path, Bytes::from_array(bytes))
  } catch {
    _ => ()
  }
}

///|
fn is_promisor_pack(fs : OsFs, pack_path : String) -> Bool {
  let base = if pack_path.has_suffix(".pack") {
    (try! pack_path[:pack_path.length() - 5]).to_string()
  } else {
    pack_path
  }
  let promisor_path = base + ".promisor"
  fs.is_file(promisor_path)
}

///|
fn collect_loose_objects(
  fs : OsFs,
  db : @bitlib.ObjectDb,
  objects_dir : String,
) -> Array[@bitcore.PackObject] {
  let out : Array[@bitcore.PackObject] = []
  let ids = collect_loose_object_ids(fs, objects_dir)
  for item in ids {
    let (hex, _v) = item
    let id = @bitcore.ObjectId::from_hex(hex) catch { _ => continue }
    try db.get(fs, id) catch {
      _ => ()
    } noraise {
      value =>
        match value {
          Some(obj) => out.push(obj)
          None => ()
        }
    }
  }
  out
}

///|
fn append_commit_ids_from_objects(
  objects : Array[@bitcore.PackObject],
  out : Array[@bitcore.ObjectId],
) -> Unit {
  for obj in objects {
    if obj.obj_type == @bitcore.ObjectType::Commit {
      out.push(@bitcore.hash_object_content(obj.obj_type, obj.data))
    }
  }
}

///|

///|
fn collect_objects_from_ref_allow_missing(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  id : @bitcore.ObjectId,
  blocked : Map[String, Bool],
  seen : Map[String, Bool],
  out : Array[@bitcore.PackObject],
) -> Unit {
  let hex = id.to_hex()
  if blocked.contains(hex) {
    return ()
  }
  if seen.contains(hex) {
    return ()
  }
  let obj = try db.get(fs, id) catch {
    _ => None
  } noraise {
    value => value
  }
  match obj {
    Some(o) =>
      match o.obj_type {
        @bitcore.ObjectType::Commit =>
          collect_commit_objects_allow_missing(db, fs, id, blocked, seen, out)
        @bitcore.ObjectType::Tree =>
          collect_tree_objects_allow_missing(db, fs, id, blocked, seen, out)
        @bitcore.ObjectType::Blob =>
          collect_blob_object_allow_missing(db, fs, id, blocked, seen, out)
        @bitcore.ObjectType::Tag => {
          seen[hex] = true
          out.push(o)
          match parse_tag_target_id(o.data) {
            Some(target) =>
              collect_objects_from_ref_allow_missing(
                db, fs, target, blocked, seen, out,
              )
            None => ()
          }
        }
      }
    None => ()
  }
}

///|
fn collect_reachable_objects_from_commits_allow_missing(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  commits : Array[@bitcore.ObjectId],
  blocked : Map[String, Bool],
) -> Array[@bitcore.PackObject] {
  let seen : Map[String, Bool] = {}
  let out : Array[@bitcore.PackObject] = []
  for commit_id in commits {
    collect_commit_objects_allow_missing(db, fs, commit_id, blocked, seen, out)
  }
  out
}

///|
fn collect_commit_objects_allow_missing(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  commit_id : @bitcore.ObjectId,
  blocked : Map[String, Bool],
  seen : Map[String, Bool],
  out : Array[@bitcore.PackObject],
) -> Unit {
  let hex = commit_id.to_hex()
  if blocked.contains(hex) {
    return ()
  }
  if seen.contains(hex) {
    return ()
  }
  seen[hex] = true
  let obj = try db.get(fs, commit_id) catch {
    _ => None
  } noraise {
    value => value
  }
  match obj {
    Some(o) if o.obj_type == @bitcore.ObjectType::Commit => {
      out.push(o)
      let info = @bitcore.parse_commit(o.data) catch { _ => return () }
      collect_tree_objects_allow_missing(db, fs, info.tree, blocked, seen, out)
      for parent in info.parents {
        collect_commit_objects_allow_missing(db, fs, parent, blocked, seen, out)
      }
    }
    _ => ()
  }
}

///|
fn collect_tree_objects_allow_missing(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  tree_id : @bitcore.ObjectId,
  blocked : Map[String, Bool],
  seen : Map[String, Bool],
  out : Array[@bitcore.PackObject],
) -> Unit {
  let hex = tree_id.to_hex()
  if blocked.contains(hex) {
    return ()
  }
  if seen.contains(hex) {
    return ()
  }
  seen[hex] = true
  let obj = try db.get(fs, tree_id) catch {
    _ => None
  } noraise {
    value => value
  }
  match obj {
    Some(o) if o.obj_type == @bitcore.ObjectType::Tree => {
      out.push(o)
      let entries = @bitcore.parse_tree(o.data) catch { _ => return () }
      for entry in entries {
        if entry.mode.has_prefix("40") {
          collect_tree_objects_allow_missing(
            db,
            fs,
            entry.id,
            blocked,
            seen,
            out,
          )
        } else {
          collect_blob_object_allow_missing(
            db,
            fs,
            entry.id,
            blocked,
            seen,
            out,
          )
        }
      }
    }
    _ => ()
  }
}

///|
fn collect_blob_object_allow_missing(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  blob_id : @bitcore.ObjectId,
  blocked : Map[String, Bool],
  seen : Map[String, Bool],
  out : Array[@bitcore.PackObject],
) -> Unit {
  let hex = blob_id.to_hex()
  if blocked.contains(hex) {
    return ()
  }
  if seen.contains(hex) {
    return ()
  }
  seen[hex] = true
  try db.get(fs, blob_id) catch {
    _ => ()
  } noraise {
    value =>
      match value {
        Some(o) if o.obj_type == @bitcore.ObjectType::Blob => out.push(o)
        _ => ()
      }
  }
}

///|
/// 2-phase sparse pack-objects algorithm (matches git's sparse behavior).
///
/// Phase 1: mark_trees_uninteresting_sparse - recursively marks UNINTERESTING
/// trees/blobs by path-name grouping, with early exit when only one side exists.
///
/// Phase 2: collect objects from interesting commits, skipping UNINTERESTING
/// subtrees entirely (producing a superset compared to non-sparse).
fn collect_objects_sparse_algorithm(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  include_commits : Array[@bitcore.ObjectId],
  exclude_commits : Array[@bitcore.ObjectId],
  allow_missing_for_local : Bool,
) -> Array[@bitcore.PackObject] {
  // Step 1: Collect all exclude-side commit IDs via BFS
  let exclude_set : Map[String, Bool] = {}
  collect_exclude_commit_ids(db, fs, exclude_commits, exclude_set)
  // Step 2: Walk include commits to find interesting and boundary commits
  let interesting_commits : Array[@bitcore.ObjectId] = []
  let boundary_tree_ids : Array[@bitcore.ObjectId] = []
  let interesting_tree_ids : Array[@bitcore.ObjectId] = []
  let commit_seen : Map[String, Bool] = {}
  find_interesting_and_boundary_commits(
    db, fs, include_commits, exclude_set, commit_seen, interesting_commits, interesting_tree_ids,
    boundary_tree_ids,
  )
  // Step 3: Phase 1 - sparse UNINTERESTING marking
  // Build initial tree OID set with their interesting/uninteresting status
  let uninteresting : Map[String, Bool] = {}
  for tid in boundary_tree_ids {
    uninteresting[tid.to_hex()] = true
  }
  // Collect all root tree OIDs for the sparse marking pass
  let root_tree_oids : Array[String] = []
  let root_tree_set : Map[String, Bool] = {}
  for tid in interesting_tree_ids {
    let hex = tid.to_hex()
    if !root_tree_set.contains(hex) {
      root_tree_set[hex] = true
      root_tree_oids.push(hex)
    }
  }
  for tid in boundary_tree_ids {
    let hex = tid.to_hex()
    if !root_tree_set.contains(hex) {
      root_tree_set[hex] = true
      root_tree_oids.push(hex)
    }
  }
  mark_trees_uninteresting_sparse(db, fs, root_tree_oids, uninteresting)
  // Step 4: Phase 2 - collect objects skipping UNINTERESTING subtrees
  let seen : Map[String, Bool] = {}
  let out : Array[@bitcore.PackObject] = []
  // Add commit objects
  for commit_id in interesting_commits {
    let hex = commit_id.to_hex()
    if seen.contains(hex) {
      continue
    }
    seen[hex] = true
    let obj = try db.get(fs, commit_id) catch {
      _ => None
    } noraise {
      value => value
    }
    match obj {
      Some(o) if o.obj_type == @bitcore.ObjectType::Commit => out.push(o)
      _ => ()
    }
  }
  // Collect tree/blob objects from interesting commits' trees
  for tid in interesting_tree_ids {
    collect_tree_skip_uninteresting(
      db, fs, tid, uninteresting, seen, out, allow_missing_for_local,
    )
  }
  out
}

///|
/// BFS to collect all commit IDs reachable from exclude roots.
fn collect_exclude_commit_ids(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  exclude_commits : Array[@bitcore.ObjectId],
  exclude_set : Map[String, Bool],
) -> Unit {
  let queue : Array[@bitcore.ObjectId] = []
  for id in exclude_commits {
    let hex = id.to_hex()
    if !exclude_set.contains(hex) {
      exclude_set[hex] = true
      queue.push(id)
    }
  }
  let mut qi = 0
  while qi < queue.length() {
    let cid = queue[qi]
    qi += 1
    let obj = try db.get(fs, cid) catch {
      _ => None
    } noraise {
      value => value
    }
    match obj {
      Some(o) if o.obj_type == @bitcore.ObjectType::Commit => {
        let info = @bitcore.parse_commit(o.data) catch { _ => continue }
        for parent in info.parents {
          let phex = parent.to_hex()
          if !exclude_set.contains(phex) {
            exclude_set[phex] = true
            queue.push(parent)
          }
        }
      }
      _ => ()
    }
  }
}

///|
/// Walk include commits to classify as interesting or boundary.
/// Interesting: commits reachable only from include side (not in exclude_set).
/// Boundary: first commit on include path that IS in exclude_set (its tree is UNINTERESTING).
fn find_interesting_and_boundary_commits(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  include_commits : Array[@bitcore.ObjectId],
  exclude_set : Map[String, Bool],
  commit_seen : Map[String, Bool],
  interesting_commits : Array[@bitcore.ObjectId],
  interesting_tree_ids : Array[@bitcore.ObjectId],
  boundary_tree_ids : Array[@bitcore.ObjectId],
) -> Unit {
  let queue : Array[@bitcore.ObjectId] = []
  for id in include_commits {
    let hex = id.to_hex()
    if !commit_seen.contains(hex) {
      commit_seen[hex] = true
      queue.push(id)
    }
  }
  let mut qi = 0
  while qi < queue.length() {
    let cid = queue[qi]
    qi += 1
    let hex = cid.to_hex()
    let obj = try db.get(fs, cid) catch {
      _ => None
    } noraise {
      value => value
    }
    match obj {
      Some(o) if o.obj_type == @bitcore.ObjectType::Commit => {
        let info = @bitcore.parse_commit(o.data) catch { _ => continue }
        if exclude_set.contains(hex) {
          // Boundary commit: its tree is UNINTERESTING
          boundary_tree_ids.push(info.tree)
          // Don't recurse further
        } else {
          // Interesting commit
          interesting_commits.push(cid)
          interesting_tree_ids.push(info.tree)
          // Check parents
          for parent in info.parents {
            let phex = parent.to_hex()
            if !commit_seen.contains(phex) {
              commit_seen[phex] = true
              queue.push(parent)
            }
          }
        }
      }
      _ => ()
    }
  }
}

///|
/// Phase 1: Recursively mark UNINTERESTING trees by path-name grouping.
/// This is the core of git's sparse optimization.
///
/// For each set of tree OIDs at the same path level:
/// 1. Check if both interesting AND uninteresting trees exist
/// 2. If only one side -> early return (the sparse optimization point)
/// 3. If both -> parse trees, group children by name, propagate UNINTERESTING, recurse
fn mark_trees_uninteresting_sparse(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  tree_oids : Array[String],
  uninteresting : Map[String, Bool],
) -> Unit {
  // Check if we have both interesting and uninteresting trees
  let mut has_interesting = false
  let mut has_uninteresting = false
  for oid in tree_oids {
    if has_interesting && has_uninteresting {
      break
    }
    if uninteresting.contains(oid) {
      has_uninteresting = true
    } else {
      has_interesting = true
    }
  }
  // Early return if only one side exists (git's sparse optimization)
  if !has_interesting || !has_uninteresting {
    return
  }
  // Group children by path name across all trees
  // path_groups: Map[name, Array[child_tree_oid_hex]]
  let path_groups : Map[String, Array[String]] = {}
  for oid in tree_oids {
    let is_uninteresting = uninteresting.contains(oid)
    let obj_id = @bitcore.ObjectId::from_hex(oid) catch { _ => continue }
    let obj = try db.get(fs, obj_id) catch {
      _ => None
    } noraise {
      value => value
    }
    match obj {
      Some(o) if o.obj_type == @bitcore.ObjectType::Tree => {
        let entries = @bitcore.parse_tree(o.data) catch { _ => continue }
        for entry in entries {
          if entry.mode.has_prefix("40") {
            // Tree entry
            let child_hex = entry.id.to_hex()
            if is_uninteresting {
              // Propagate UNINTERESTING to child tree
              uninteresting[child_hex] = true
            }
            if path_groups.contains(entry.name) {
              path_groups[entry.name].push(child_hex)
            } else {
              path_groups[entry.name] = [child_hex]
            }
            // Blob entry: if parent is UNINTERESTING, mark blob
          } else if is_uninteresting {
            uninteresting[entry.id.to_hex()] = true
          }
        }
      }
      _ => ()
    }
  }
  // Recurse into each path group
  for _name, child_oids in path_groups {
    mark_trees_uninteresting_sparse(db, fs, child_oids, uninteresting)
  }
}

///|
/// Phase 2: Collect tree objects, skipping UNINTERESTING subtrees entirely.
fn collect_tree_skip_uninteresting(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  tree_id : @bitcore.ObjectId,
  uninteresting : Map[String, Bool],
  seen : Map[String, Bool],
  out : Array[@bitcore.PackObject],
  allow_missing : Bool,
) -> Unit {
  let hex = tree_id.to_hex()
  // Skip entire subtree if UNINTERESTING
  if uninteresting.contains(hex) {
    return
  }
  if seen.contains(hex) {
    return
  }
  seen[hex] = true
  let obj = try db.get(fs, tree_id) catch {
    _ => None
  } noraise {
    value => value
  }
  match obj {
    Some(o) if o.obj_type == @bitcore.ObjectType::Tree => {
      out.push(o)
      let entries = @bitcore.parse_tree(o.data) catch { _ => return () }
      for entry in entries {
        if entry.mode.has_prefix("40") {
          collect_tree_skip_uninteresting(
            db,
            fs,
            entry.id,
            uninteresting,
            seen,
            out,
            allow_missing,
          )
        } else {
          collect_blob_skip_uninteresting(
            db,
            fs,
            entry.id,
            uninteresting,
            seen,
            out,
            allow_missing,
          )
        }
      }
    }
    _ => ()
  }
}

///|
/// Phase 2 helper: Collect blob if not UNINTERESTING.
fn collect_blob_skip_uninteresting(
  db : @bitlib.ObjectDb,
  fs : OsFs,
  blob_id : @bitcore.ObjectId,
  uninteresting : Map[String, Bool],
  seen : Map[String, Bool],
  out : Array[@bitcore.PackObject],
  _allow_missing : Bool,
) -> Unit {
  let hex = blob_id.to_hex()
  if uninteresting.contains(hex) {
    return
  }
  if seen.contains(hex) {
    return
  }
  seen[hex] = true
  try db.get(fs, blob_id) catch {
    _ => ()
  } noraise {
    value =>
      match value {
        Some(o) if o.obj_type == @bitcore.ObjectType::Blob => out.push(o)
        _ => ()
      }
  }
}

///|
async fn collect_objects_from_stdin_packs(
  fs : OsFs,
  git_dir : String,
  db : @bitlib.ObjectDb,
  cfg : PackObjectsConfig,
  include_names : Array[String],
  exclude_names : Array[String],
) -> Array[@bitcore.PackObject] {
  let pack_dir = git_dir + "/objects/pack"
  let alt_dirs = read_alternate_object_dirs(fs, git_dir)
  let include_paths : Array[String] = []
  let exclude_paths : Array[String] = []
  for name in include_names {
    match resolve_pack_path(fs, pack_dir, alt_dirs, name) {
      Some(path) => include_paths.push(path)
      None => {
        @stdio.stderr.write("fatal: could not find pack '" + name + "'\n")
        @sys.exit(1)
      }
    }
  }
  for name in exclude_names {
    match resolve_pack_path(fs, pack_dir, alt_dirs, name) {
      Some(path) => exclude_paths.push(path)
      None => ()
    }
  }
  if cfg.exclude_promisor_objects {
    for path in include_paths {
      if is_promisor_pack(fs, path) {
        @stdio.stderr.write(
          "fatal: packfile '" +
          path +
          "' is a promisor but --exclude-promisor-objects was given\n",
        )
        @sys.exit(1)
      }
    }
  }
  let include_objects : Array[@bitcore.PackObject] = []
  let seed_commits : Array[@bitcore.ObjectId] = []
  for path in include_paths {
    let objs = read_pack_objects(fs, path)
    for obj in objs {
      include_objects.push(obj)
    }
  }
  if cfg.stdin_packs_follow {
    append_commit_ids_from_objects(include_objects, seed_commits)
  }
  let exclude_ids : Map[String, Bool] = {}
  for path in exclude_paths {
    let idx_path = pack_idx_path(path)
    let ids = collect_pack_index_ids(fs, idx_path)
    for id in ids {
      exclude_ids[id] = true
    }
  }
  let mut promisor_ids : Map[String, Bool] = {}
  if cfg.exclude_promisor_objects {
    promisor_ids = collect_pack_ids_from_marker(fs, pack_dir, ".promisor")
    for alt_dir in alt_dirs {
      let alt_pack_dir = alt_dir + "/pack"
      let ids = collect_pack_ids_from_marker(fs, alt_pack_dir, ".promisor")
      for item in ids {
        let (hex, _v) = item
        promisor_ids[hex] = true
      }
    }
  }
  let mut objects : Array[@bitcore.PackObject] = include_objects
  if cfg.unpacked {
    let objects_dir = git_dir + "/objects"
    let loose = collect_loose_objects(fs, db, objects_dir)
    objects.append(loose)
    if cfg.stdin_packs_follow {
      append_commit_ids_from_objects(loose, seed_commits)
    }
  }
  if cfg.stdin_packs_follow && seed_commits.length() > 0 {
    let reachable = collect_reachable_objects_from_commits_allow_missing(
      db, fs, seed_commits, promisor_ids,
    )
    objects.append(reachable)
  }
  objects = dedup_objects(objects)
  objects = filter_objects(objects, exclude_ids)
  if cfg.exclude_promisor_objects {
    objects = filter_objects(objects, promisor_ids)
  }
  objects
}

///|
async fn try_reuse_single_stdin_pack(
  fs : OsFs,
  git_dir : String,
  cfg : PackObjectsConfig,
  include_names : Array[String],
  exclude_names : Array[String],
) -> Bool raise Error {
  if include_names.length() != 1 || exclude_names.length() != 0 {
    return false
  }
  if cfg.stdin_packs_follow ||
    cfg.unpacked ||
    cfg.local_only ||
    cfg.honor_pack_keep ||
    cfg.incremental ||
    cfg.exclude_promisor_objects {
    return false
  }
  let pack_dir = git_dir + "/objects/pack"
  let alt_dirs = read_alternate_object_dirs(fs, git_dir)
  let name = include_names[0]
  let pack_path = match resolve_pack_path(fs, pack_dir, alt_dirs, name) {
    Some(path) => path
    None => return false
  }
  let pack = fs.read_file(pack_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => return false
  }
  if cfg.stdout {
    @stdio.stdout.write(pack)
    return true
  }
  let idx_path = pack_idx_path(pack_path)
  let idx = fs.read_file(idx_path) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => return false
  }
  let hash_hex = pack_hash_hex(pack)
  let base_name = match cfg.base_name {
    Some(name) => name
    None => {
      @stdio.stderr.write("fatal: missing base-name\n")
      @sys.exit(1)
      ""
    }
  }
  let base_name = resolve_in_cwd(base_name)
  let pack_out = base_name + "-" + hash_hex + ".pack"
  let idx_out = base_name + "-" + hash_hex + ".idx"
  fs.write_file(pack_out, pack)
  fs.write_file(idx_out, idx)
  @stdio.stdout.write(hash_hex + "\n")
  true
}

///|
async fn handle_pack_objects(args : Array[String]) -> Unit raise Error {
  for arg in args {
    if arg == "-h" || arg == "--help" || arg == "--help-all" {
      @stdio.stdout.write("usage: git pack-objects [<options>] <base-name>\n")
      @sys.exit(129)
    }
  }
  match parse_pack_objects_args(args) {
    PackObjectsParse::Unsupported => {
      @stdio.stderr.write(
        "bit pack-objects: unsupported options in standalone mode\n",
      )
      @sys.exit(1)
    }
    PackObjectsParse::Error(msg) => {
      @stdio.stderr.write(msg + "\n")
      @sys.exit(1)
    }
    PackObjectsParse::Ok(cfg) => {
      let fs = OsFs::new()
      let git_dir = find_git_dir(fs)
      match @sys.get_env_var("GIT_TEST_NAME_HASH_VERSION") {
        Some(_) => ()
        None => ()
      }
      if cfg.object_format is Some(format) && format == "sha256" {
        @stdio.stderr.write("bit: SHA256 object format is not supported\n")
        @sys.exit(1)
      }
      if is_sha256_repo_from_env() {
        @stdio.stderr.write("bit: SHA256 repositories are not supported\n")
        @sys.exit(1)
      }
      let trace2_event = @sys.get_env_var("GIT_TRACE2_EVENT")
      ignore(is_pack_reuse_config_enabled(git_dir))
      // Keep these flags visible for future compatibility tuning.
      let non_default_delta_params = cfg.window == 0 || cfg.depth != 50
      let stdin_object_mode = !cfg.revs && !cfg.all && !cfg.stdin_packs
      ignore(non_default_delta_params)
      let pack_dir = git_dir + "/objects/pack"
      if cfg.name_hash_version is Some(version) &&
        cfg.write_bitmap &&
        version == 2 &&
        !cfg.stdout {
        @stdio.stderr.write(
          "warning: currently, --write-bitmap-index requires --name-hash-version=1\n",
        )
      }
      if !fs.is_dir(git_dir) && !(cfg.all || cfg.revs) {
        @stdio.stderr.write("fatal: not a git repository\n")
        @sys.exit(1)
      }
      // Read pack.packSizeLimit from config; CLI --max-pack-size overrides
      let pack_size_limit = match cfg.max_pack_size {
        Some(_) => cfg.max_pack_size
        None => get_pack_size_limit(git_dir)
      }
      // Check if reverse index should be written
      let write_rev = pack_write_reverse_index_enabled(git_dir)
      let pack_compression_level = get_pack_compression_level(git_dir)
      let pack_compression = match pack_compression_level {
        Some(level) if level == 0 => @bitcore.PackCompression::Stored
        _ => @bitcore.PackCompression::Default
      }
      let db = @bitlib.ObjectDb::load(fs, git_dir)
      if cfg.window == 0 {
        db.set_prefer_packed(true)
      }
      let lookup_dbs = load_object_lookup_dbs(fs, git_dir, db)
      // Cruft mode: separate flow for collecting unreachable objects
      if cfg.cruft {
        let input = read_all_stdin()
        let (keep_names, discard_names) = parse_cruft_stdin_lines(input)
        let expiration = match cfg.cruft_expiration {
          Some(exp_str) => parse_approxidate(exp_str)
          None => 0L // "never" — keep all cruft objects
        }
        let cruft_size_limit : Int64? = match cfg.max_cruft_size {
          Some(limit) => Some(limit)
          None =>
            match cfg.max_pack_size {
              Some(limit) => Some(limit)
              None => None
            }
        }
        let (cruft_objects, mtime_map) = collect_cruft_objects(
          fs,
          git_dir,
          db,
          keep_names,
          discard_names,
          expiration,
          cfg.missing_mode,
        )
        if cruft_objects.length() == 0 {
          // Nothing to pack — still need to output an empty pack
          // to satisfy git repack expectations
        }
        let base_name = match cfg.base_name {
          Some(name) => resolve_in_cwd(name)
          None => {
            @stdio.stderr.write("fatal: missing base-name\n")
            @sys.exit(1)
            ""
          }
        }
        // Create cruft pack(s) — may split if --max-cruft-size
        let cruft_pack_list : Array[Bytes] = match cruft_size_limit {
          Some(limit) if limit > 0L => {
            let effective_limit = if limit < 1048576L {
              @stdio.stderr.write("warning: minimum pack size limit is 1 MiB\n")
              1048576L
            } else {
              limit
            }
            let (packs, _dc) = @pack.create_packfiles_with_size_limit(
              cruft_objects,
              cfg.delta_mode,
              pack_compression,
              false, // no reuse in cruft mode
              cfg.depth,
              effective_limit,
            )
            packs
          }
          _ =>
            if cruft_objects.length() == 0 {
              // Create an empty pack
              let (pack, _dc) = @pack.create_packfile_with_delta_stats_compression_reuse(
                [],
                cfg.delta_mode,
                pack_compression,
                false,
                cfg.depth,
              )
              [pack]
            } else {
              let (pack, _dc) = @pack.create_packfile_with_delta_stats_compression_reuse(
                cruft_objects,
                cfg.delta_mode,
                pack_compression,
                false,
                cfg.depth,
              )
              [pack]
            }
        }
        for pack in cruft_pack_list {
          let hash_hex = pack_hash_hex(pack)
          let pack_path = base_name + "-" + hash_hex + ".pack"
          let idx_path = base_name + "-" + hash_hex + ".idx"
          fs.write_file(pack_path, pack)
          let idx_objects = @pack.parse_packfile(pack)
          @pack.write_pack_index_from_objects_versioned(
            fs,
            idx_path,
            pack,
            idx_objects,
            cfg.index_version,
            cfg.off64_threshold,
          )
          if write_rev {
            let rev_path = base_name + "-" + hash_hex + ".rev"
            @pack.write_reverse_index(fs, rev_path, pack, idx_objects)
          }
          // Write .mtimes file for cruft pack
          let mtimes_path = base_name + "-" + hash_hex + ".mtimes"
          // Get sorted OIDs from the index (lexicographic order)
          let sorted_ids = get_sorted_pack_ids(cruft_objects)
          // For split packs, get the IDs in this specific pack
          let pack_ids = if cruft_pack_list.length() > 1 {
            // Collect IDs for objects in this specific pack
            let ids : Array[String] = []
            for obj in idx_objects {
              ids.push(
                @bitcore.hash_object_content(obj.obj_type, obj.data).to_hex(),
              )
            }
            ids.sort_by(fn(a, b) { a.compare(b) })
            ids
          } else {
            sorted_ids
          }
          let pack_checksum = get_pack_checksum_bytes(pack)
          write_mtimes_file(fs, mtimes_path, pack_ids, mtime_map, pack_checksum)
          @stdio.stdout.write(hash_hex + "\n")
        }
        return ()
      }
      let mut objects : Array[@bitcore.PackObject] = []
      // Objects explicitly given by the user (e.g., tree/blob OIDs in --revs input)
      // that should bypass filter_spec application
      let filter_exempt_objects : Array[@bitcore.PackObject] = []
      if cfg.stdin_packs {
        let input = read_all_stdin()
        let (include_names, exclude_names) = parse_stdin_pack_lines(input)
        if try_reuse_single_stdin_pack(
            fs, git_dir, cfg, include_names, exclude_names,
          ) {
          return ()
        }
        objects = collect_objects_from_stdin_packs(
          fs, git_dir, db, cfg, include_names, exclude_names,
        )
      } else if cfg.all {
        let refs = @bitrepo.show_ref(fs, git_dir) catch {
          err if @async.is_cancellation_error(err) => raise err
          _ => []
        }
        // Sort refs: branch refs (refs/heads/) first, then others.
        // This ensures the DFS traversal starts from branch tips (most
        // recent commits), producing reverse-topological commit order
        // in the output — matching git's pack-objects behavior.
        refs.sort_by(fn(a, b) {
          let (na, _) = a
          let (nb, _) = b
          let a_head = na.has_prefix("refs/heads/")
          let b_head = nb.has_prefix("refs/heads/")
          if a_head && !b_head {
            -1
          } else if !a_head && b_head {
            1
          } else {
            na.compare(nb)
          }
        })
        let blocked : Map[String, Bool] = {}
        let seen : Map[String, Bool] = {}
        let out : Array[@bitcore.PackObject] = []
        for pair in refs {
          let (_name, id) = pair
          collect_objects_from_ref_allow_missing(db, fs, id, blocked, seen, out)
        }
        if cfg.reflog {
          let reflog_ids = collect_reflog_object_ids(fs, git_dir)
          for rid in reflog_ids {
            collect_objects_from_ref_allow_missing(
              db, fs, rid, blocked, seen, out,
            )
          }
        }
        if cfg.indexed_objects {
          let idx_entries = @bitlib.read_index_entries(fs, git_dir) catch {
            _ => []
          }
          for entry in idx_entries {
            collect_objects_from_ref_allow_missing(
              db,
              fs,
              entry.id,
              blocked,
              seen,
              out,
            )
          }
        }
        objects = out
      } else if cfg.revs {
        let input = read_all_stdin()
        let lines = split_lines_bytes(input)
        let include_commits : Array[@bitcore.ObjectId] = []
        let exclude_commits : Array[@bitcore.ObjectId] = []
        let explicit_tags : Array[@bitcore.PackObject] = []
        let user_given_objects : Array[@bitcore.PackObject] = []
        let mut negate_mode = false
        for line in lines {
          let trimmed = trim_line_bytes(line)
          // Empty line signals end of input in --revs mode (like git rev-list --stdin)
          if trimmed.length() == 0 {
            break
          }
          let text = line_to_string(trimmed)
          if text == "--not" {
            negate_mode = !negate_mode
            continue
          }
          if text == "--" {
            continue
          }
          let (negated, spec) = if text.has_prefix("^") {
            (true, (try! text[1:]).to_string())
          } else {
            (negate_mode, text)
          }
          let mut handled = false
          if !negated {
            match spec.find("..") {
              Some(pos) => {
                let left = (try! spec[:pos]).to_string()
                let right = (try! spec[pos + 2:]).to_string()
                if right.length() > 0 {
                  match @bitrepo.rev_parse(fs, git_dir, right) {
                    None => {
                      @stdio.stderr.write(
                        "fatal: bad revision '" + right + "'\n",
                      )
                      @sys.exit(1)
                    }
                    Some(id) => {
                      let (tags, peeled) = resolve_tag_chain(db, fs, id)
                      for tag in tags {
                        explicit_tags.push(tag)
                      }
                      match peeled {
                        Some(target) => include_commits.push(target)
                        None => include_commits.push(id)
                      }
                    }
                  }
                }
                if left.length() > 0 {
                  match @bitrepo.rev_parse(fs, git_dir, left) {
                    None => {
                      @stdio.stderr.write(
                        "fatal: bad revision '" + left + "'\n",
                      )
                      @sys.exit(1)
                    }
                    Some(id) => {
                      let (_tags, peeled) = resolve_tag_chain(db, fs, id)
                      match peeled {
                        Some(target) => exclude_commits.push(target)
                        None => exclude_commits.push(id)
                      }
                    }
                  }
                }
                handled = true
              }
              None => ()
            }
          }
          if !handled {
            match @bitrepo.rev_parse(fs, git_dir, spec) {
              None => {
                @stdio.stderr.write("fatal: bad revision '" + spec + "'\n")
                @sys.exit(1)
              }
              Some(id) => {
                let (tags, peeled) = resolve_tag_chain(db, fs, id)
                let resolved = match peeled {
                  Some(target) => target
                  None => id
                }
                if negated {
                  exclude_commits.push(resolved)
                } else {
                  for tag in tags {
                    explicit_tags.push(tag)
                  }
                  // Check if the resolved object is a commit or a non-commit (tree/blob)
                  // Non-commit objects are "user given" and bypass filters
                  let obj_for_type = try db.get(fs, resolved) catch {
                    _ => None
                  } noraise {
                    value => value
                  }
                  match obj_for_type {
                    Some(o) =>
                      if o.obj_type != @bitcore.ObjectType::Commit {
                        user_given_objects.push(o)
                      } else {
                        include_commits.push(resolved)
                      }
                    _ => include_commits.push(resolved)
                  }
                }
              }
            }
          }
        }
        let allow_missing = match cfg.missing_mode {
          MissingMode::AllowAny => true
          _ => false
        }
        let allow_missing_for_local = allow_missing ||
          cfg.local_only ||
          cfg.honor_pack_keep ||
          cfg.incremental ||
          cfg.unpacked
        // Determine if sparse algorithm should be used
        let use_sparse = match cfg.sparse_mode {
          Some(v) => v
          None =>
            match @sys.get_env_var("GIT_TEST_PACK_SPARSE") {
              Some(val) =>
                parse_bool_value(val).unwrap_or(get_pack_use_sparse(git_dir))
              None => get_pack_use_sparse(git_dir)
            }
        }
        if use_sparse && exclude_commits.length() > 0 {
          // 2-phase sparse algorithm: produces superset output
          objects = collect_objects_sparse_algorithm(
            db, fs, include_commits, exclude_commits, allow_missing_for_local,
          )
        } else {
          // Non-sparse path (original behavior)
          let include_objects = if allow_missing_for_local {
            let blocked : Map[String, Bool] = {}
            collect_reachable_objects_from_commits_allow_missing(
              db, fs, include_commits, blocked,
            )
          } else {
            @bitlib.collect_reachable_objects_from_commits(
              db, fs, include_commits,
            ) catch {
              err if @async.is_cancellation_error(err) => raise err
              err => {
                report_collect_error(err)
                []
              }
            }
          }
          if exclude_commits.length() == 0 {
            objects = include_objects
          } else {
            let blocked : Map[String, Bool] = {}
            let exclude_objects = collect_reachable_objects_from_commits_allow_missing(
              db, fs, exclude_commits, blocked,
            )
            let exclude_set : Map[String, Bool] = {}
            for obj in exclude_objects {
              let id = @bitcore.hash_object_content(obj.obj_type, obj.data)
              exclude_set[id.to_hex()] = true
            }
            let filtered : Array[@bitcore.PackObject] = []
            for obj in include_objects {
              let id = @bitcore.hash_object_content(obj.obj_type, obj.data)
              if !exclude_set.contains(id.to_hex()) {
                filtered.push(obj)
              }
            }
            objects = filtered
          }
        }
        if explicit_tags.length() > 0 {
          objects.append(explicit_tags)
        }
        // User-given non-commit objects bypass filters
        if user_given_objects.length() > 0 {
          filter_exempt_objects.append(user_given_objects)
        }
      } else {
        let input = read_all_stdin()
        if input.length() > 0 {
          let lines = split_lines_bytes(input)
          let mut has_sha256 = false
          for line in lines {
            if looks_like_sha256_line(line) {
              has_sha256 = true
              break
            }
          }
          if has_sha256 {
            @stdio.stderr.write("bit: SHA256 object format is not supported\n")
            @sys.exit(1)
          }
          let ends_with_newline = input.length() > 0 &&
            input[input.length() - 1] == b'\n'
          for i in 0..<lines.length() {
            let line = lines[i]
            let trimmed = trim_line_bytes(line)
            if trimmed.length() == 0 {
              if !(ends_with_newline && i == lines.length() - 1) {
                @stdio.stderr.write(invalid_object_line_message(""))
                @sys.exit(1)
              }
              continue
            }
            match parse_object_id_bytes(line) {
              None => {
                @stdio.stderr.write(
                  line |> line_to_string |> invalid_object_line_message,
                )
                @sys.exit(1)
              }
              Some(id) =>
                match find_object_in_lookup_dbs(lookup_dbs, fs, id) {
                  None =>
                    if (match cfg.missing_mode {
                        MissingMode::AllowAny => true
                        _ => false
                      }) {
                      ()
                    } else {
                      @stdio.stderr.write(
                        "fatal: bad object " + id.to_hex() + "\n",
                      )
                      @sys.exit(1)
                    }
                  Some(obj) => objects.push(obj)
                }
            }
          }
        }
      }
      if cfg.path_walk {
        @stdio.stderr.write("Compressing objects by path\n")
      }
      // Handle sparse:path (security-dropped) error before filtering
      if cfg.filter is SparsePathUnsupported {
        @stdio.stderr.write(
          "fatal: --filter=sparse:path is no longer supported\n",
        )
        @sys.exit(1)
      }
      // Handle sparse:oid filter
      if cfg.filter is SparseOid(oid_spec) {
        objects = apply_sparse_oid_filter(fs, git_dir, db, objects, oid_spec)
      }
      // Apply filter specification (e.g., blob:none for partial clone)
      let mut objects = apply_pack_filter_spec(objects, cfg.filter)
      // Add back user-given objects that bypass filters (e.g., explicitly
      // specified trees/blobs in --revs input)
      if filter_exempt_objects.length() > 0 {
        let existing : Map[String, Bool] = {}
        for obj in objects {
          existing[@bitcore.hash_object_content(obj.obj_type, obj.data).to_hex()] = true
        }
        for obj in filter_exempt_objects {
          let hex = @bitcore.hash_object_content(obj.obj_type, obj.data).to_hex()
          if !existing.contains(hex) {
            objects.push(obj)
            existing[hex] = true
          }
        }
      }
      if cfg.local_only {
        let alt_dirs = read_alternate_object_dirs(fs, git_dir)
        let non_local_ids : Map[String, Bool] = {}
        for alt_dir in alt_dirs {
          let alt_pack_dir = alt_dir + "/pack"
          let alt_pack_ids = collect_pack_ids_from_dir(fs, alt_pack_dir)
          for item in alt_pack_ids {
            let (hex, _v) = item
            non_local_ids[hex] = true
          }
          let alt_loose_ids = collect_loose_object_ids(fs, alt_dir)
          for item in alt_loose_ids {
            let (hex, _v) = item
            non_local_ids[hex] = true
          }
        }
        objects = filter_objects(objects, non_local_ids)
      }
      if cfg.honor_pack_keep {
        let keep_ids = collect_pack_ids_from_marker(fs, pack_dir, ".keep")
        objects = filter_objects(objects, keep_ids)
      }
      if (cfg.incremental || cfg.unpacked) && !cfg.stdin_packs {
        let packed_ids = collect_pack_ids_from_dir(fs, pack_dir)
        objects = filter_objects(objects, packed_ids)
      }
      if cfg.exclude_promisor_objects {
        let promisor_ids = collect_pack_ids_from_marker(
          fs, pack_dir, ".promisor",
        )
        objects = filter_objects(objects, promisor_ids)
      }
      if cfg.include_tag {
        let tags = collect_include_tag_objects(fs, git_dir, db, objects)
        if tags.length() > 0 {
          objects.append(tags)
        }
      }
      // Sort objects by type/size for better delta compression, but only
      // when there is no pack size limit.  When splitting packs by size
      // the write order must match git's insertion order so that
      // interleaved large/small objects produce the same pack boundaries.
      let has_size_limit = match pack_size_limit {
        Some(limit) => limit > 0L
        None => false
      }
      if stdin_object_mode && !has_size_limit {
        sort_stdin_object_mode_objects(objects)
      }
      objects = dedup_objects(objects)
      if cfg.non_empty && objects.is_empty() {
        @sys.exit(1)
      }
      let (pack_reused, packs_reused) = count_pack_reused_objects(
        fs, git_dir, pack_dir, objects,
      )
      // Write trace2 data events for pack-reused / packs-reused
      if trace2_event is Some(trace2_path) {
        write_trace2_data_event(
          fs,
          trace2_path,
          "pack-objects",
          "pack-reused",
          pack_reused.to_string(),
        )
        write_trace2_data_event(
          fs,
          trace2_path,
          "pack-objects",
          "packs-reused",
          packs_reused.to_string(),
        )
      }
      if cfg.progress {
        let enumerated = objects.length()
        @stdio.stderr.write(
          "Enumerating objects: " + enumerated.to_string() + ", done\n",
        )
        @stdio.stderr.write("pack-reused " + pack_reused.to_string() + "\n")
      }
      let reuse_only = cfg.window == 0
      // Apply pack size limit (only for file output, not stdout)
      let effective_limit : Int64? = if cfg.stdout {
        None
      } else {
        match pack_size_limit {
          Some(limit) =>
            if limit > 0L && limit < 1048576L {
              @stdio.stderr.write("warning: minimum pack size limit is 1 MiB\n")
              Some(1048576L)
            } else {
              Some(limit)
            }
          None => None
        }
      }
      let mut total_delta_count = 0
      let pack_list : Array[Bytes] = match effective_limit {
        Some(limit) =>
          if limit > 0L {
            let (packs, dc) = @pack.create_packfiles_with_size_limit(
              objects,
              cfg.delta_mode,
              pack_compression,
              reuse_only,
              cfg.depth,
              limit,
            )
            total_delta_count += dc
            packs
          } else {
            let (pack, dc) = @pack.create_packfile_with_delta_stats_compression_reuse(
              objects,
              cfg.delta_mode,
              pack_compression,
              reuse_only,
              cfg.depth,
            )
            total_delta_count += dc
            [pack]
          }
        _ => {
          let (pack, dc) = @pack.create_packfile_with_delta_stats_compression_reuse(
            objects,
            cfg.delta_mode,
            pack_compression,
            reuse_only,
            cfg.depth,
          )
          total_delta_count += dc
          [pack]
        }
      }
      for pack in pack_list {
        if cfg.stdout {
          @stdio.stdout.write(pack)
        } else {
          let hash_hex = pack_hash_hex(pack)
          let base_name = match cfg.base_name {
            Some(name) => name
            None => {
              @stdio.stderr.write("fatal: missing base-name\n")
              @sys.exit(1)
              ""
            }
          }
          let base_name = resolve_in_cwd(base_name)
          let pack_path = base_name + "-" + hash_hex + ".pack"
          let idx_path = base_name + "-" + hash_hex + ".idx"
          fs.write_file(pack_path, pack)
          // Always re-parse the newly created pack to compute correct
          // offsets and CRC32 values for the index.
          let idx_objects = @pack.parse_packfile(pack)
          @pack.write_pack_index_from_objects_versioned(
            fs,
            idx_path,
            pack,
            idx_objects,
            cfg.index_version,
            cfg.off64_threshold,
          )
          if write_rev {
            let rev_path = base_name + "-" + hash_hex + ".rev"
            @pack.write_reverse_index(fs, rev_path, pack, idx_objects)
          }
          if db.saw_corrupt_pack {
            corrupt_pack_file(fs, pack_path)
          }
          @stdio.stdout.write(hash_hex + "\n")
        }
      }
      if cfg.progress {
        @stdio.stderr.write(
          "Total " +
          objects.length().to_string() +
          " (delta " +
          total_delta_count.to_string() +
          ")\n",
        )
      }
      if cfg.stdout {
        @sys.exit(0)
      }
      if cfg.unpack_unreachable {
        let new_pack_ids : Map[String, Bool] = {}
        for obj in objects {
          new_pack_ids[obj.id.to_hex()] = true
        }
        loosen_unused_packed_objects(fs, git_dir, db, new_pack_ids, cfg)
      }
    }
  }
}

///|
fn pack_objects_is_zero_oid(id : @bitcore.ObjectId) -> Bool {
  for b in id.bytes {
    if b != b'\x00' {
      return false
    }
  }
  true
}

///|
fn collect_reflog_object_ids(
  fs : OsFs,
  git_dir : String,
) -> Array[@bitcore.ObjectId] {
  let ids : Array[@bitcore.ObjectId] = []
  let logs_dir = git_dir + "/logs"
  if fs.is_dir(logs_dir) {
    collect_reflog_ids_recursive(fs, git_dir, logs_dir, ids)
  }
  ids
}

///|
fn collect_reflog_ids_recursive(
  fs : OsFs,
  git_dir : String,
  dir : String,
  ids : Array[@bitcore.ObjectId],
) -> Unit {
  let entries = fs.readdir(dir) catch { _ => return }
  for name in entries {
    let path = dir + "/" + name
    if fs.is_dir(path) {
      collect_reflog_ids_recursive(fs, git_dir, path, ids)
    } else if fs.is_file(path) {
      let rel = String::unsafe_substring(
        path,
        start=git_dir.length() + "/logs/".length(),
        end=path.length(),
      )
      let reflog_entries = @bitrepo.read_reflog(fs, git_dir, rel) catch {
        _ => continue
      }
      for entry in reflog_entries {
        if !pack_objects_is_zero_oid(entry.old_id) {
          ids.push(entry.old_id)
        }
        if !pack_objects_is_zero_oid(entry.new_id) {
          ids.push(entry.new_id)
        }
      }
    }
  }
}

///|
/// Loosen unreachable packed objects that are not in the new pack,
/// not in .keep packs, and not in alternate ODBs.
/// This implements the `--unpack-unreachable` semantics from git pack-objects.
fn loosen_unused_packed_objects(
  fs : OsFs,
  git_dir : String,
  db : @bitlib.ObjectDb,
  packed_ids : Map[String, Bool],
  cfg : PackObjectsConfig,
) -> Unit {
  let pack_dir = git_dir + "/objects/pack"
  // Collect IDs from .keep packs — these stay packed, never loosen
  let skip_ids : Map[String, Bool] = collect_pack_ids_from_marker(
    fs, pack_dir, ".keep",
  )
  // Collect IDs from alternate ODB packs — non-local, never loosen
  let alt_dirs = read_alternate_object_dirs(fs, git_dir)
  for alt_dir in alt_dirs {
    let alt_pack_dir = alt_dir + "/pack"
    let alt_ids = collect_pack_ids_from_dir(fs, alt_pack_dir)
    for id, _ in alt_ids {
      skip_ids[id] = true
    }
  }
  // Walk each local non-.keep pack and loosen objects not in new pack or skip set
  if !fs.is_dir(pack_dir) {
    return
  }
  let entries = fs.readdir(pack_dir) catch { _ => return }
  // Build a set of .keep pack base names to skip
  let keep_bases : Map[String, Bool] = {}
  for entry in entries {
    let name = normalize_dir_entry(entry)
    if name.has_suffix(".keep") {
      let base = (try! name[:name.length() - 5]).to_string()
      keep_bases[base] = true
    }
  }
  for entry in entries {
    let name = normalize_dir_entry(entry)
    if not(name.has_suffix(".idx")) {
      continue
    }
    // Check if this pack has a .keep file
    let base = (try! name[:name.length() - 4]).to_string()
    if keep_bases.contains(base + ".keep") {
      continue
    }
    let idx_path = pack_dir + "/" + name
    if not(fs.is_file(idx_path)) {
      continue
    }
    let ids = collect_pack_index_ids(fs, idx_path)
    for hex in ids {
      // Already in the new pack
      if packed_ids.contains(hex) {
        continue
      }
      // In a .keep or alternate pack
      if skip_ids.contains(hex) {
        continue
      }
      // expiration check: if set, objects older than expiration are discarded
      // (not loosened). For expiration=0 (no date), always loosen.
      if cfg.unpack_unreachable_expiration > 0L {
        // With expiration date, skip loosening (discard) — mtime check
        // would go here for full --unpack-unreachable=<date> support
        continue
      }
      // Check if already exists as a loose object
      let prefix = String::unsafe_substring(hex, start=0, end=2)
      let suffix = String::unsafe_substring(hex, start=2, end=hex.length())
      let loose_path = git_dir + "/objects/" + prefix + "/" + suffix
      if fs.is_file(loose_path) {
        continue
      }
      // Read from pack, compress, and write as loose object
      let id = @bitcore.ObjectId::from_hex(hex) catch { _ => continue }
      let obj = db.get(fs, id) catch { _ => continue }
      match obj {
        Some(obj) => {
          let (_, compressed) = @bitcore.create_object(obj.obj_type, obj.data)
          @bitlib.write_object_bytes(fs, git_dir, obj.id, compressed) catch {
            _ => ()
          }
        }
        None => ()
      }
    }
  }
}
