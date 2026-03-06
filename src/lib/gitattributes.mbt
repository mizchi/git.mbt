///| Gitattributes text/eol attribute processing

///|
pub enum TextAttr {
  Auto
  Set
  Unset
  Unspecified
}

///|
pub enum EolAttr {
  Lf
  Crlf
  Unspecified
}

///|
pub(all) struct FilterCmd {
  run : async (String, String, String, Bytes) -> Bytes raise @bit.GitError
}

///|
pub struct FileEolAttrs {
  text : TextAttr
  eol : EolAttr
  filter : String?
}

///|
/// Parse .gitattributes and resolve eol attributes for a given path.
pub fn resolve_eol_attrs(
  rfs : &@bit.RepoFileSystem,
  root : String,
  path : String,
) -> FileEolAttrs {
  let attr_path = join_path(root, ".gitattributes")
  if not(rfs.is_file(attr_path)) {
    return {
      text: TextAttr::Unspecified,
      eol: EolAttr::Unspecified,
      filter: None,
    }
  }
  let content = @utf8.decode_lossy(
    (rfs.read_file(attr_path) catch { _ => Bytes::default() })[:],
  )
  let normalized = if path.has_prefix("/") {
    String::unsafe_substring(path, start=1, end=path.length())
  } else if path.has_prefix("./") {
    String::unsafe_substring(path, start=2, end=path.length())
  } else {
    path
  }
  let mut text : TextAttr = TextAttr::Unspecified
  let mut eol : EolAttr = EolAttr::Unspecified
  let mut filter : String? = None
  for line_view in content.split("\n") {
    let line = line_view.to_string().trim().to_string()
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    let words : Array[String] = []
    for token_view in line.split(" ") {
      let token = token_view.to_string().trim().to_string()
      if token.length() > 0 {
        words.push(token)
      }
    }
    if words.length() < 2 {
      continue
    }
    if not(gitattr_pattern_matches(normalized, words[0])) {
      continue
    }
    let mut j = 1
    while j < words.length() {
      let token = words[j]
      if token == "text" {
        text = TextAttr::Set
      } else if token == "-text" {
        text = TextAttr::Unset
      } else if token.has_prefix("text=") {
        let value = String::unsafe_substring(token, start=5, end=token.length()).to_lower()
        if value == "auto" {
          text = TextAttr::Auto
        } else {
          text = TextAttr::Set
        }
      } else if token == "eol" || token.has_prefix("eol=") {
        if token.has_prefix("eol=") {
          let value = String::unsafe_substring(
            token,
            start=4,
            end=token.length(),
          ).to_lower()
          if value == "lf" {
            eol = EolAttr::Lf
          } else if value == "crlf" {
            eol = EolAttr::Crlf
          }
        }
      } else if token.has_prefix("filter=") {
        let value = String::unsafe_substring(token, start=7, end=token.length())
        if value.length() > 0 {
          filter = Some(value)
        }
      } else if token == "crlf" {
        // Legacy: crlf is equivalent to text
        text = TextAttr::Set
      } else if token == "-crlf" {
        // Legacy: -crlf is equivalent to -text
        text = TextAttr::Unset
      }
      j += 1
    }
  }
  // git: eol=lf/crlf implicitly sets text (like "text eol=lf")
  if text is Unspecified && not(eol is Unspecified) {
    text = Set
  }
  { text, eol, filter }
}

///|
/// Pattern matching for gitattributes (same as cat_file_attr_pattern_matches).
fn gitattr_pattern_matches(path : String, pattern : String) -> Bool {
  if pattern == path {
    return true
  }
  if pattern.has_prefix("*.") {
    return path.has_suffix(
      String::unsafe_substring(pattern, start=1, end=pattern.length()),
    )
  }
  match pattern.find("*") {
    Some(idx) => {
      let prefix = String::unsafe_substring(pattern, start=0, end=idx)
      let suffix = String::unsafe_substring(
        pattern,
        start=idx + 1,
        end=pattern.length(),
      )
      path.has_prefix(prefix) &&
      path.has_suffix(suffix) &&
      path.length() >= prefix.length() + suffix.length()
    }
    None => false
  }
}

///|
/// Clean: WT→blob normalization considering gitattributes text/eol.
pub fn clean_for_storage(
  content : Bytes,
  attrs : FileEolAttrs,
  autocrlf : AutoCrlf,
) -> Bytes {
  match attrs.text {
    Unset => content // -text: no conversion
    Set =>
      // text: always normalize CRLF→LF
      if is_binary_bytes(content) {
        content
      } else {
        normalize_crlf_to_lf(content)
      }
    Auto =>
      // text=auto: normalize only if not binary
      if is_binary_bytes(content) {
        content
      } else {
        normalize_crlf_to_lf(content)
      }
    Unspecified =>
      // No text attribute: fall back to core.autocrlf
      normalize_worktree_content(content, autocrlf)
  }
}

///|
/// Smudge: blob→WT expansion considering gitattributes text/eol.
pub fn smudge_for_checkout(
  content : Bytes,
  attrs : FileEolAttrs,
  autocrlf : AutoCrlf,
  core_eol? : EolAttr = Unspecified,
) -> Bytes {
  match attrs.text {
    Unset => content // -text: no conversion
    Set | Auto => {
      let is_bin = is_binary_bytes(content)
      if is_bin && attrs.text is Auto {
        return content
      }
      if is_bin {
        return content
      }
      match attrs.eol {
        Lf => content // eol=lf: keep LF
        Crlf => convert_lf_to_crlf(content) // eol=crlf: expand
        Unspecified =>
          // No eol attribute: check autocrlf, then core.eol
          if autocrlf is On {
            convert_lf_to_crlf(content)
          } else {
            match core_eol {
              Crlf => convert_lf_to_crlf(content)
              _ => content // Lf or Unspecified: keep LF (native on Linux/macOS)
            }
          }
      }
    }
    Unspecified =>
      // No text attribute: fall back to core.autocrlf
      smudge_worktree_content(content, autocrlf)
  }
}

///|
/// Check if .gitattributes has unsupported attributes (filter=lfs, working-tree-encoding).
/// Generic filter= (other than lfs) is now handled natively.
pub fn check_unsupported_gitattributes(
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> String? {
  let attr_path = join_path(root, ".gitattributes")
  if not(rfs.is_file(attr_path)) {
    return None
  }
  let content = @utf8.decode_lossy(
    (rfs.read_file(attr_path) catch { _ => Bytes::default() })[:],
  )
  for line_view in content.split("\n") {
    let line = line_view.to_string().trim().to_string()
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    for token_view in line.split(" ") {
      let token = token_view.to_string().trim().to_string()
      if token.length() == 0 {
        continue
      }
      if token == "filter=lfs" || token.has_prefix("filter=lfs ") {
        return Some("fatal: filter 'lfs' is not supported in standalone mode")
      }
      if token.has_prefix("working-tree-encoding=") {
        return Some(
          "fatal: working-tree-encoding is not supported in standalone mode",
        )
      }
    }
  }
  None
}

///|
/// Read filter clean/smudge commands from git config.
pub fn read_filter_commands(
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  filter_name : String,
) -> (String?, String?) {
  let section = "filter \"" + filter_name + "\""
  let mut clean : String? = None
  let mut smudge : String? = None
  // Check global config first (lower priority)
  match @bitio.env_get("HOME") {
    None => ()
    Some(home) => {
      let candidates : Array[String] = []
      if @bitio.env_get("XDG_CONFIG_HOME") is Some(base) {
        candidates.push(base + "/git/config")
      }
      candidates.push(home + "/.gitconfig")
      for path in candidates {
        if rfs.is_file(path) {
          match read_config_value(rfs, path, section, "clean") {
            Some(v) => clean = Some(v)
            None => ()
          }
          match read_config_value(rfs, path, section, "smudge") {
            Some(v) => smudge = Some(v)
            None => ()
          }
          break
        }
      }
    }
  }
  // Local config overrides global
  let local_path = join_path(git_dir, "config")
  if rfs.is_file(local_path) {
    match read_config_value(rfs, local_path, section, "clean") {
      Some(v) => clean = Some(v)
      None => ()
    }
    match read_config_value(rfs, local_path, section, "smudge") {
      Some(v) => smudge = Some(v)
      None => ()
    }
  }
  (clean, smudge)
}

///|
/// Check if .gitattributes has any filter= attributes (for storage runtime bypass).
pub fn has_any_filter_attributes(
  rfs : &@bit.RepoFileSystem,
  root : String,
) -> Bool {
  let attr_path = join_path(root, ".gitattributes")
  if not(rfs.is_file(attr_path)) {
    return false
  }
  let content = @utf8.decode_lossy(
    (rfs.read_file(attr_path) catch { _ => Bytes::default() })[:],
  )
  for line_view in content.split("\n") {
    let line = line_view.to_string().trim().to_string()
    if line.length() == 0 || line.has_prefix("#") {
      continue
    }
    for token_view in line.split(" ") {
      let token = token_view.to_string().trim().to_string()
      if token.length() == 0 {
        continue
      }
      if token.has_prefix("filter=") {
        return true
      }
    }
  }
  false
}
