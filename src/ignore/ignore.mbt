///| Gitignore-style pattern matching

///|
/// A single ignore rule parsed from a gitignore file.
pub struct Rule {
  /// Base directory where the rule was defined (relative path)
  base : String
  /// The pattern to match against
  pattern : String
  /// Pre-compiled pattern code units for match_glob (avoids repeated to_array allocation)
  pattern_chars : FixedArray[UInt16]
  /// Whether this is a negation rule (starts with !)
  negated : Bool
  /// Whether this rule only applies to directories (ends with /)
  dir_only : Bool
  /// Whether this rule is anchored to the base (starts with /)
  anchored : Bool
  /// Whether the pattern contains a slash (affects matching behavior)
  has_slash : Bool
}

///|
/// A collection of ignore rules that can check if paths are ignored.
pub struct Matcher {
  rules : Array[Rule]
  mut negation_count : Int
}

///|
/// Create a new empty matcher.
pub fn Matcher::new() -> Matcher {
  { rules: [], negation_count: 0 }
}

///|
/// Add rules from gitignore content.
/// `base` is the relative directory where the gitignore file is located.
pub fn Matcher::add_rules(
  self : Matcher,
  base : String,
  content : String,
) -> Unit {
  let parsed = parse(content, base)
  for rule in parsed {
    self.rules.push(rule)
    if rule.negated {
      self.negation_count = self.negation_count + 1
    }
  }
}

///|
/// Check if a path is ignored.
/// `rel_path` is the path relative to the root.
/// `is_dir` indicates whether the path is a directory.
pub fn Matcher::is_ignored(
  self : Matcher,
  rel_path : String,
  is_dir : Bool,
) -> Bool {
  let mut ignored = false
  for rule in self.rules {
    if rule_applies(rule, rel_path, is_dir) {
      ignored = not(rule.negated)
    }
  }
  ignored
}

///|
/// Remove rules added after a certain point (for backtracking during traversal).
pub fn Matcher::truncate(self : Matcher, len : Int) -> Unit {
  let mut i = len
  let total = self.rules.length()
  while i < total {
    if self.rules[i].negated {
      self.negation_count = self.negation_count - 1
    }
    i = i + 1
  }
  self.rules.truncate(len)
}

///|
/// Get current number of rules.
pub fn Matcher::len(self : Matcher) -> Int {
  self.rules.length()
}

///|
/// Whether any negation rules have been added.
pub fn Matcher::has_negation(self : Matcher) -> Bool {
  self.negation_count > 0
}

///|
/// Check if any negation rule could potentially un-ignore a child under `dir_rel`.
/// More precise than `has_negation()` — only returns true if a negation rule's
/// target path overlaps with the given directory.
pub fn Matcher::could_negate_under(self : Matcher, dir_rel : String) -> Bool {
  if self.negation_count == 0 {
    return false
  }
  for rule in self.rules {
    if not(rule.negated) {
      continue
    }
    // Non-path-specific rules (no slash, not anchored) could match anywhere
    if not(rule.has_slash) && not(rule.anchored) {
      return true
    }
    // Path-specific rule: compute target path and check prefix overlap
    let target = if rule.base.length() == 0 {
      rule.pattern
    } else {
      rule.base + "/" + rule.pattern
    }
    let prefix = negation_literal_prefix(target)
    if prefix.length() == 0 {
      return true
    }
    // Check if dir_rel is an ancestor of prefix or prefix is an ancestor of dir_rel
    if is_path_prefix(dir_rel, prefix) || is_path_prefix(prefix, dir_rel) {
      return true
    }
  }
  false
}

///|
/// Extract the literal directory prefix before any wildcard in a pattern.
fn negation_literal_prefix(pattern : String) -> String {
  let mut last_slash = -1
  for i in 0..<pattern.length() {
    let c = pattern.unsafe_get(i)
    if c == char_star || c == char_question || c == char_open_bracket {
      if last_slash < 0 {
        return ""
      }
      return String::unsafe_substring(pattern, start=0, end=last_slash)
    }
    if c == char_slash {
      last_slash = i
    }
  }
  pattern
}

///|
let char_open_bracket : UInt16 = {
  let c : Int = '['.to_int()
  c.to_uint16()
}

///|
/// Check if `a` is a path prefix of `b` (a == b or b starts with a + "/").
fn is_path_prefix(a : String, b : String) -> Bool {
  let alen = a.length()
  let blen = b.length()
  if alen > blen {
    return false
  }
  for i in 0..<alen {
    if a.unsafe_get(i) != b.unsafe_get(i) {
      return false
    }
  }
  alen == blen || b.unsafe_get(alen) == char_slash
}

///|
/// Parse gitignore content into rules.
/// `base` is the relative directory where the gitignore file is located.
pub fn parse(content : String, base : String) -> Array[Rule] {
  let rules : Array[Rule] = []
  for line_view in content.split("\n") {
    let mut line = line_view.to_string()
    // Handle CRLF
    if line.has_suffix("\r") {
      line = String::unsafe_substring(line, start=0, end=line.length() - 1)
    }
    // Trim trailing whitespace (but not leading - significant for patterns)
    line = trim_trailing_whitespace(line)
    // Skip empty lines
    if line.length() == 0 {
      continue
    }
    // Skip comments
    if line.has_prefix("#") {
      continue
    }
    // Handle escaped characters
    let mut negated = false
    if line.has_prefix("\\!") {
      line = String::unsafe_substring(line, start=1, end=line.length())
    } else if line.has_prefix("!") {
      negated = true
      line = String::unsafe_substring(line, start=1, end=line.length())
    }
    if line.has_prefix("\\#") {
      line = String::unsafe_substring(line, start=1, end=line.length())
    }
    if line.length() == 0 {
      continue
    }
    // Check for directory-only rule
    let mut dir_only = false
    if line.has_suffix("/") {
      dir_only = true
      line = String::unsafe_substring(line, start=0, end=line.length() - 1)
    }
    if line.length() == 0 {
      continue
    }
    // Check for anchored rule
    let mut anchored = false
    if line.has_prefix("/") {
      anchored = true
      line = String::unsafe_substring(line, start=1, end=line.length())
    }
    if line.length() == 0 {
      continue
    }
    let has_slash = line.contains("/")
    let pattern_chars = string_to_uint16_array(line)
    rules.push({
      base,
      pattern: line,
      pattern_chars,
      negated,
      dir_only,
      anchored,
      has_slash,
    })
  }
  rules
}

///|
let char_star : UInt16 = {
  let c : Int = '*'.to_int()
  c.to_uint16()
}

///|
let char_question : UInt16 = {
  let c : Int = '?'.to_int()
  c.to_uint16()
}

///|
let char_slash : UInt16 = {
  let c : Int = '/'.to_int()
  c.to_uint16()
}

///|
fn string_to_uint16_array(s : String) -> FixedArray[UInt16] {
  let len = s.length()
  let arr = FixedArray::make(len, UInt16::default())
  for i in 0..<len {
    arr[i] = s.unsafe_get(i)
  }
  arr
}

///|
/// Check if a single pattern matches a path segment.
/// Supports * (any characters) and ? (single character) wildcards.
pub fn match_glob(pattern : String, text : String) -> Bool {
  let p = string_to_uint16_array(pattern)
  match_glob_precompiled(p, text)
}

///|
/// match_glob using pre-compiled pattern code units to avoid repeated allocation.
fn match_glob_precompiled(p : FixedArray[UInt16], text : String) -> Bool {
  let slen = text.length()
  let plen = p.length()
  let mut pi = 0
  let mut si = 0
  let mut star = -1
  let mut mark = 0
  while si < slen {
    if pi < plen && (p[pi] == char_question || p[pi] == text.unsafe_get(si)) {
      pi += 1
      si += 1
    } else if pi < plen && p[pi] == char_star {
      star = pi
      mark = si
      pi += 1
    } else if star != -1 {
      pi = star + 1
      mark += 1
      si = mark
    } else {
      return false
    }
  }
  while pi < plen && p[pi] == char_star {
    pi += 1
  }
  pi == plen
}

///|
fn rule_applies(rule : Rule, path : String, is_dir : Bool) -> Bool {
  match relative_to_base(path, rule.base) {
    None => false
    Some(rel) =>
      if rule.dir_only {
        match_dir_rule(rule, rel, is_dir)
      } else {
        match_rule_path(rule, rel)
      }
  }
}

///|
fn match_dir_rule(rule : Rule, rel : String, is_dir : Bool) -> Bool {
  let segs = split_path(rel)
  let max_len = if is_dir { segs.length() } else { segs.length() - 1 }
  if max_len <= 0 {
    return false
  }
  for len in 1..<=max_len {
    let prefix = join_segments(segs, len)
    if match_rule_path(rule, prefix) {
      return true
    }
  }
  false
}

///|
fn match_rule_path(rule : Rule, rel : String) -> Bool {
  if rule.has_slash || rule.anchored {
    match_path(rule.pattern, rel)
  } else {
    // Use pre-compiled pattern_chars to avoid allocation per segment
    for_each_segment(rel, fn(seg) {
      if match_glob_precompiled(rule.pattern_chars, seg) {
        return true
      }
      false
    })
  }
}

///|
/// Iterate over "/" separated segments without allocating an Array.
/// Returns true if callback returns true for any segment.
fn for_each_segment(path : String, f : (String) -> Bool) -> Bool {
  let len = path.length()
  let mut start = 0
  while start < len {
    let mut end = start
    while end < len && path.unsafe_get(end) != char_slash {
      end += 1
    }
    if end > start {
      let seg = String::unsafe_substring(path, start~, end~)
      if f(seg) {
        return true
      }
    }
    start = end + 1
  }
  false
}

///|
fn match_path(pattern : String, path : String) -> Bool {
  let pats = split_path(pattern)
  let segs = split_path(path)
  match_segments(pats, 0, segs, 0)
}

///|
fn match_segments(
  pats : Array[String],
  pi : Int,
  segs : Array[String],
  si : Int,
) -> Bool {
  if pi >= pats.length() {
    return si >= segs.length()
  }
  let pat = pats[pi]
  if pat == "**" {
    let mut k = si
    while true {
      if match_segments(pats, pi + 1, segs, k) {
        return true
      }
      if k >= segs.length() {
        break
      }
      k += 1
    }
    false
  } else {
    if si >= segs.length() {
      return false
    }
    if match_glob(pat, segs[si]) {
      match_segments(pats, pi + 1, segs, si + 1)
    } else {
      false
    }
  }
}

///|
fn relative_to_base(path : String, base : String) -> String? {
  let blen = base.length()
  if blen == 0 {
    return Some(path)
  }
  let plen = path.length()
  if plen < blen {
    return None
  }
  // Check character-by-character that path starts with base
  for i in 0..<blen {
    if path.unsafe_get(i) != base.unsafe_get(i) {
      return None
    }
  }
  if plen == blen {
    return Some("")
  }
  // path must have '/' right after base
  if path.unsafe_get(blen) == char_slash {
    Some(String::unsafe_substring(path, start=blen + 1, end=plen))
  } else {
    None
  }
}

///|
fn split_path(path : String) -> Array[String] {
  let out : Array[String] = []
  if path.length() == 0 {
    return out
  }
  for part_view in path.split("/") {
    let part = part_view.to_string()
    if part.length() == 0 {
      continue
    }
    out.push(part)
  }
  out
}

///|
fn join_segments(segs : Array[String], len : Int) -> String {
  if len <= 0 {
    return ""
  }
  let sb = StringBuilder::new()
  for i in 0..<len {
    if i > 0 {
      sb.write_char('/')
    }
    sb.write_string(segs[i])
  }
  sb.to_string()
}

///|
fn trim_trailing_whitespace(s : String) -> String {
  let mut end = s.length()
  while end > 0 {
    let c = s.unsafe_get(end - 1)
    if c == ' ' || c == '\t' {
      end -= 1
    } else {
      break
    }
  }
  if end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start=0, end~)
  }
}
