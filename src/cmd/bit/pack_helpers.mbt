///|
fn shim_cwd_from_env() -> String? {
  @sys.get_env_var("GIT_SHIM_CWD")
}

///|
fn resolve_in_cwd(path : String) -> String {
  let base = match shim_cwd_from_env() {
    Some(cwd) => Some(cwd)
    None => @sys.get_env_var("GIT_SHIM_PWD")
  }
  match base {
    None => path
    Some(cwd) => if path.has_prefix("/") { path } else { cwd + "/" + path }
  }
}

///|
fn pack_hash_id(pack : Bytes) -> @bitcore.ObjectId raise @bitcore.GitError {
  if pack.length() < 20 {
    raise @bitcore.GitError::PackfileError("Packfile too short")
  }
  let start = pack.length() - 20
  let bytes : FixedArray[Byte] = FixedArray::make(20, b'\x00')
  for i in 0..<20 {
    bytes[i] = pack[start + i]
  }
  @bitcore.ObjectId::new(bytes)
}

///|
fn pack_hash_hex(pack : Bytes) -> String raise @bitcore.GitError {
  pack_hash_id(pack).to_hex()
}

///|
/// Scan a pack for REF_DELTA (type 7) entries and return their base object
/// hex IDs.  This is used by --fix-thin to find which external bases need
/// to be appended.
fn scan_ref_delta_bases(pack : Bytes) -> Array[String] {
  let result : Array[String] = []
  if pack.length() < 12 {
    return result
  }
  let num_objects = (pack[8].to_int() << 24) |
    (pack[9].to_int() << 16) |
    (pack[10].to_int() << 8) |
    pack[11].to_int()
  let mut offset = 12
  for _i in 0..<num_objects {
    if offset >= pack.length() - 20 {
      break
    }
    // Read type/size header
    let first = pack[offset].to_int()
    let obj_type = (first >> 4) & 0x7
    let mut byte_val = first
    offset += 1
    while (byte_val & 0x80) != 0 {
      if offset >= pack.length() {
        return result
      }
      byte_val = pack[offset].to_int()
      offset += 1
    }
    match obj_type {
      7 => {
        // REF_DELTA: next 20 bytes are base object hash
        if offset + 20 > pack.length() {
          return result
        }
        let hex = bytes_to_hex_at(pack, offset, 20)
        result.push(hex)
        offset += 20
        // Skip compressed delta data
        offset = skip_zlib_data(pack, offset)
      }
      6 => {
        // OFS_DELTA: skip variable-length offset, then compressed data
        if offset >= pack.length() {
          return result
        }
        let mut b = pack[offset].to_int()
        offset += 1
        while (b & 0x80) != 0 {
          if offset >= pack.length() {
            return result
          }
          b = pack[offset].to_int()
          offset += 1
        }
        offset = skip_zlib_data(pack, offset)
      }
      _ =>
        // Regular object: skip compressed data
        offset = skip_zlib_data(pack, offset)
    }
  }
  result
}

///|
fn bytes_to_hex_at(data : Bytes, offset : Int, len : Int) -> String {
  let hex_chars = "0123456789abcdef"
  let buf = StringBuilder::new()
  for i in 0..<len {
    let b = data[offset + i].to_int()
    buf.write_char(hex_chars[b >> 4].to_int().unsafe_to_char())
    buf.write_char(hex_chars[b & 0xf].to_int().unsafe_to_char())
  }
  buf.to_string()
}

///|
fn skip_zlib_data(data : Bytes, offset : Int) -> Int {
  // zlib data starts with a 2-byte header (0x78xx).
  // We need to find the end of the compressed stream.
  // Use zlib decompression to find the consumed length.
  let (_, after) = @zlib.zlib_decompress_at(data, offset) catch {
    _ => return data.length() - 20 // Skip to trailer on error
  }
  after
}

///|
/// Parse git config file and get value for section.key
fn bit_config_get(git_dir : String, section : String, key : String) -> String? {
  let config_path = git_dir + "/config"
  let content = @fs.read_file_to_string(config_path) catch { _ => return None }
  parse_git_config_value(content, section, key)
}

///|
/// Parse INI-style git config content
fn parse_git_config_value(
  content : String,
  target_section : String,
  target_key : String,
) -> String? {
  let lines = content.split("\n")
  let mut current_section = ""
  let target_section_lower = target_section.to_lower()
  let target_key_lower = target_key.to_lower()
  for line_iter in lines {
    let line = line_iter.to_string().trim().to_string()
    if line.length() == 0 || line.has_prefix("#") || line.has_prefix(";") {
      continue
    }
    if line.has_prefix("[") {
      // Section header: [section] or [section "subsection"]
      match line.find("]") {
        Some(idx) => {
          let section_part = (try! line[1:idx]).to_string()
          // Handle subsection: [remote "origin"] -> remote.origin
          match section_part.find(" ") {
            Some(si) => {
              let main_sec = (try! section_part[:si]).to_string()
              let sub_sec = (try! section_part[si + 1:])
                .to_string()
                .trim()
                .to_string()
                .replace(old="\"", new="")
              current_section = main_sec.to_lower() + "." + sub_sec.to_lower()
            }
            None => current_section = section_part.to_lower()
          }
        }
        None => ()
      }
      continue
    }
    // Key = value
    match line.find("=") {
      Some(idx) => {
        let k = (try! line[:idx]).to_string().trim().to_string()
        let v = (try! line[idx + 1:]).to_string().trim().to_string()
        if current_section == target_section_lower &&
          k.to_lower() == target_key_lower {
          return Some(v)
        }
      }
      None => ()
    }
  }
  None
}

///|
/// Parse size value like "3m", "1k", "1g", "1024"
fn parse_size_value(value : String) -> Int64? {
  let trimmed = value.trim().to_string().to_lower()
  if trimmed.length() == 0 {
    return None
  }
  let len = trimmed.length()
  let last_char = trimmed[len - 1]
  let (num_str, multiplier) : (String, Int64) = if last_char >= '0' &&
    last_char <= '9' {
    (trimmed, 1L)
  } else {
    let num_part = (try! trimmed[:len - 1]).to_string()
    let mult : Int64 = match last_char {
      'k' => 1024L
      'm' => 1024L * 1024L
      'g' => 1024L * 1024L * 1024L
      _ => return None
    }
    (num_part, mult)
  }
  let num = @strconv.parse_int64(num_str) catch { _ => return None }
  Some(num * multiplier)
}

///|
fn parse_bool_value(value : String) -> Bool? {
  let trimmed = value.trim().to_string().to_lower()
  match trimmed {
    "true" | "yes" | "on" | "1" => Some(true)
    "false" | "no" | "off" | "0" => Some(false)
    _ => {
      let parsed = @strconv.parse_int(trimmed) catch { _ => return None }
      Some(parsed != 0)
    }
  }
}

///|
fn parse_pack_allow_reuse(value : String) -> Bool? {
  let trimmed = value.trim().to_string().to_lower()
  if trimmed.length() == 0 {
    return None
  }
  if trimmed == "single" || trimmed == "multi" {
    return Some(true)
  }
  parse_bool_value(trimmed)
}

///|
fn is_pack_reuse_config_enabled(git_dir : String) -> Bool {
  match get_config_override("pack.allowPackReuse") {
    Some(value) =>
      match parse_pack_allow_reuse(value) {
        Some(flag) => return flag
        None => return false
      }
    None => ()
  }
  match bit_config_get(git_dir, "pack", "allowPackReuse") {
    Some(value) =>
      match parse_pack_allow_reuse(value) {
        Some(flag) => return flag
        None => return false
      }
    None => ()
  }
  match get_config_override("feature.experimental") {
    Some(value) =>
      match parse_bool_value(value) {
        Some(flag) => return flag
        None => return false
      }
    None => ()
  }
  match bit_config_get(git_dir, "feature", "experimental") {
    Some(value) =>
      match parse_bool_value(value) {
        Some(flag) => return flag
        None => return false
      }
    None => ()
  }
  false
}

///|
/// Get pack.packSizeLimit from git config
fn get_pack_size_limit(git_dir : String) -> Int64? {
  match bit_config_get(git_dir, "pack", "packSizeLimit") {
    None => None
    Some(value) => parse_size_value(value)
  }
}

///|
fn parse_compression_level(value : String) -> Int? {
  let parsed = @strconv.parse_int(value) catch { _ => return None }
  let mut level = parsed
  if level < 0 {
    level = 0
  }
  if level > 9 {
    level = 9
  }
  Some(level)
}

///|
fn get_pack_compression_level(git_dir : String) -> Int? {
  if get_config_override("pack.compression") is Some(value) {
    return parse_compression_level(value)
  }
  if get_config_override("core.compression") is Some(value) {
    return parse_compression_level(value)
  }
  if bit_config_get(git_dir, "pack", "compression") is Some(value) {
    return parse_compression_level(value)
  }
  if bit_config_get(git_dir, "core", "compression") is Some(value) {
    return parse_compression_level(value)
  }
  None
}

///|
/// Check if repository uses SHA256 (returns true if SHA256, false if SHA1)
fn is_sha256_repo(git_dir : String) -> Bool {
  // Check extensions.objectFormat in config
  match bit_config_get(git_dir, "extensions", "objectFormat") {
    Some(format) => format.to_lower() == "sha256"
    None => false
  }
}

///|
fn is_sha256_repo_from_env() -> Bool {
  let fs = OsFs::new()
  let git_dir = find_git_dir(fs)
  if is_sha256_repo(git_dir) {
    return true
  }
  match @sys.get_env_var("GIT_SHIM_CWD") {
    Some(cwd) => {
      let alt_git_dir = cwd + "/.git"
      if alt_git_dir != git_dir && is_sha256_repo(alt_git_dir) {
        return true
      }
    }
    None => ()
  }
  match @sys.get_env_var("GIT_WORK_TREE") {
    Some(dir) => {
      let alt_git_dir = dir + "/.git"
      if alt_git_dir != git_dir && is_sha256_repo(alt_git_dir) {
        return true
      }
    }
    None => ()
  }
  let args = @sys.get_cli_args()
  let mut i = 1
  while i + 1 < args.length() {
    if args[i] == "-C" {
      let raw = args[i + 1]
      let base = @sys.get_env_var("GIT_SHIM_PWD").unwrap_or(".")
      let cwd = if raw.has_prefix("/") { raw } else { base + "/" + raw }
      if is_sha256_repo(cwd + "/.git") {
        return true
      }
      i += 2
      continue
    }
    i += 1
  }
  false
}
