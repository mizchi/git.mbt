///| Helper functions and utilities for git-shim (native-only)

///|
fn bytes_from_array(arr : Array[Byte]) -> Bytes {
  Bytes::from_array(FixedArray::makei(arr.length(), i => arr[i]))
}

///|
fn str_to_bytes(s : String) -> Bytes {
  let arr : Array[Byte] = []
  for c in s {
    arr.push(c.to_int().to_byte())
  }
  bytes_from_array(arr)
}

///|
async fn warn_unimplemented_arg(cmd : String, arg : String) -> Unit {
  if arg == "--" {
    return
  }
  let msg = "warning: " + cmd + ": unsupported option '" + arg + "'\n"
  @stdio.stderr.write(str_to_bytes(msg))
}

///|
async fn print_line(s : String) -> Unit {
  @stdio.stdout.write(str_to_bytes(s + "\n"))
}

///|
async fn print_str(s : String) -> Unit {
  @stdio.stdout.write(str_to_bytes(s))
}

///|
async fn eprint_line(s : String) -> Unit {
  @stdio.stderr.write(str_to_bytes(s + "\n"))
}

///|
struct RunGitCommandInvocation {
  cwd : String?
  git_dir : String?
  cmd : String
  rest : Array[String]
}

///|
struct RunGitEnvSnapshot {
  shim_cwd : String?
  git_dir : String?
  bit_work_tree : String?
}

///|
fn resolve_run_git_path(path : String, cwd : String?) -> String {
  if path.has_prefix("/") {
    return path
  }
  match cwd {
    Some(base) => normalize_path(base + "/" + path)
    None =>
      @sys.get_env_var("GIT_SHIM_PWD")
      .map(base => normalize_path(base + "/" + path))
      .unwrap_or(path)
  }
}

///|
fn parse_run_git_invocation(
  args : Array[String],
  cwd : String?,
) -> RunGitCommandInvocation? {
  let mut i = 0
  let mut resolved_cwd = cwd
  let mut resolved_git_dir : String? = None
  while i < args.length() {
    let arg = args[i]
    if arg == "-C" && i + 1 < args.length() {
      resolved_cwd = Some(resolve_run_git_path(args[i + 1], resolved_cwd))
      i += 2
      continue
    }
    if arg == "--git-dir" && i + 1 < args.length() {
      resolved_git_dir = Some(resolve_run_git_path(args[i + 1], resolved_cwd))
      i += 2
      continue
    }
    if arg.has_prefix("--git-dir=") {
      let raw = String::unsafe_substring(arg, start=10, end=arg.length())
      resolved_git_dir = Some(resolve_run_git_path(raw, resolved_cwd))
      i += 1
      continue
    }
    if arg == "-c" && i + 1 < args.length() {
      i += 2
      continue
    }
    if arg == "--version" || arg == "-v" {
      return Some({
        cwd: resolved_cwd,
        git_dir: resolved_git_dir,
        cmd: "version",
        rest: collect_args(args, i + 1),
      })
    }
    if arg.has_prefix("-") {
      i += 1
      continue
    }
    return Some({
      cwd: resolved_cwd,
      git_dir: resolved_git_dir,
      cmd: arg,
      rest: collect_args(args, i + 1),
    })
  }
  None
}

///|
fn restore_env_var(name : String, value : String?) -> Unit {
  match value {
    Some(v) => @sys.set_env_var(name, v)
    None => @sys.unset_env_var(name)
  }
}

///|
fn enter_run_git_env(cwd : String?, git_dir : String?) -> RunGitEnvSnapshot {
  let snapshot = {
    shim_cwd: @sys.get_env_var("GIT_SHIM_CWD"),
    git_dir: @sys.get_env_var("GIT_DIR"),
    bit_work_tree: @sys.get_env_var("GIT_WORK_TREE"),
  }
  let fs = OsFs::new()
  match git_dir {
    Some(dir) => @sys.set_env_var("GIT_DIR", dir)
    None => ()
  }
  match cwd {
    Some(dir) => {
      @sys.set_env_var("GIT_SHIM_CWD", dir)
      if @sys.get_env_var("GIT_DIR") is None {
        @sys.set_env_var("GIT_DIR", default_repo_marker_path(fs, dir))
      }
      if @sys.get_env_var("GIT_WORK_TREE") is None {
        @sys.set_env_var("GIT_WORK_TREE", dir)
      }
    }
    None => ()
  }
  snapshot
}

///|
fn restore_run_git_env(snapshot : RunGitEnvSnapshot) -> Unit {
  restore_env_var("GIT_SHIM_CWD", snapshot.shim_cwd)
  restore_env_var("GIT_DIR", snapshot.git_dir)
  restore_env_var("GIT_WORK_TREE", snapshot.bit_work_tree)
}

///|
async fn run_git_internal_command(
  cmd : String,
  rest : Array[String],
) -> Int raise Error {
  match cmd {
    "version" => {
      print_line("git version \{bit_version_tag}")
      0
    }
    "clone" => {
      handle_clone(rest)
      0
    }
    "pull" => {
      handle_pull(rest)
      0
    }
    "fetch" => {
      handle_fetch(rest)
      0
    }
    "sparse-checkout" => {
      handle_sparse_checkout(rest)
      0
    }
    "checkout" => {
      handle_checkout(rest)
      0
    }
    "reset" => {
      handle_reset(rest)
      0
    }
    "config" => {
      handle_config(rest)
      0
    }
    "maintenance" => {
      handle_maintenance(rest)
      0
    }
    "fsmonitor--daemon" => 0
    _ => {
      eprint_line("fatal: unsupported internal git command '\{cmd}'")
      1
    }
  }
}

///|
async fn run_git_command(
  args : Array[String],
  cwd~ : String?,
  inherit_env? : Bool = true,
) -> Int {
  ignore(inherit_env)
  guard parse_run_git_invocation(args, cwd) is Some(invocation) else {
    eprint_line("fatal: missing subcommand")
    return 1
  }
  let snapshot = enter_run_git_env(invocation.cwd, invocation.git_dir)
  let code = run_git_internal_command(invocation.cmd, invocation.rest) catch {
    err => {
      if @async.is_being_cancelled() || @async.is_cancellation_error(err) {
        restore_run_git_env(snapshot)
        raise err
      }
      eprint_line("\{invocation.cmd} failed: \{err}")
      1
    }
  }
  restore_run_git_env(snapshot)
  code
}

///|
async fn read_all_stdin() -> Bytes {
  let out : Array[Byte] = []
  while true {
    match @stdio.stdin.read_some(max_len=8192) {
      None => break
      Some(bytes) =>
        for b in bytes {
          out.push(b)
        }
    }
  }
  bytes_from_array(out)
}

///|
fn prepend_arg(first : String, rest : Array[String]) -> Array[String] {
  let out : Array[String] = [first]
  out.append(rest)
  out
}

///|
fn decode_bytes(data : Bytes) -> String {
  @encoding.decoder(@encoding.Encoding::UTF8).decode_lossy(data[:])
}

///|
fn trim_string(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let c = s.unsafe_get(start)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let c = s.unsafe_get(end - 1)
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if start == 0 && end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

///|
fn is_hex_char(c : Char) -> Bool {
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

///|
fn is_hex_string(s : String) -> Bool {
  if s.length() == 0 {
    return false
  }
  for c in s {
    if (c |> is_hex_char |> not) {
      return false
    }
  }
  true
}

///|
fn detect_repo_marker_path(
  fs : &@bitcore.RepoFileSystem,
  root : String,
) -> String? {
  let git_path = join_repo_marker(root, ".git")
  if fs.is_dir(git_path) || fs.is_file(git_path) {
    return Some(git_path)
  }
  let bit_path = join_repo_marker(root, ".bit")
  if fs.is_dir(bit_path) || fs.is_file(bit_path) {
    return Some(bit_path)
  }
  None
}

///|
fn default_repo_marker_path(
  fs : &@bitcore.RepoFileSystem,
  root : String,
) -> String {
  match detect_repo_marker_path(fs, root) {
    Some(path) => path
    None => join_repo_marker(root, ".git")
  }
}

///|
fn resolve_git_dir(fs : &@bitcore.RepoFileSystem, root : String) -> String {
  let default_git_dir = default_repo_marker_path(fs, root)
  match @sys.get_env_var("GIT_DIR") {
    Some(dir) => {
      let resolved = if dir.has_prefix("/") {
        dir
      } else {
        match @sys.get_env_var("GIT_SHIM_CWD") {
          Some(base) => normalize_path(base + "/" + dir)
          None =>
            @sys.get_env_var("GIT_SHIM_PWD")
            .map(base => normalize_path(base + "/" + dir))
            .unwrap_or(dir)
        }
      }
      if fs.is_file(resolved) {
        @bitlib.resolve_gitdir(fs, resolved)
      } else if fs.is_dir(resolved) {
        resolved
      } else if is_bare_repo_dir(root) {
        root
      } else {
        resolved
      }
    }
    None =>
      if fs.is_file(default_git_dir) {
        @bitlib.resolve_gitdir(fs, default_git_dir)
      } else if fs.is_dir(default_git_dir) {
        default_git_dir
      } else if is_bare_repo_dir(root) {
        root
      } else {
        default_git_dir
      }
  }
}

///|
fn is_reftable_repo(fs : &@bitcore.RepoFileSystem, git_dir : String) -> Bool {
  if fs.is_dir(git_dir + "/reftable") {
    return true
  }
  match
    @bitlib.read_config_value(
      fs,
      git_dir + "/config",
      "extensions",
      "refstorage",
    ) {
    Some(value) => value.to_lower() == "reftable"
    None => false
  }
}

///|
fn repo_object_format(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> String {
  match
    @bitlib.read_config_value(
      fs,
      git_dir + "/config",
      "extensions",
      "objectformat",
    ) {
    Some(value) => if value.to_lower() == "sha256" { "sha256" } else { "sha1" }
    None => "sha1"
  }
}

///|
fn repo_compat_object_format(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> String? {
  match
    @bitlib.read_config_value(
      fs,
      git_dir + "/config",
      "extensions",
      "compatobjectformat",
    ) {
    Some(value) => {
      let normalized = @bitlib.config_strip_quotes(value).to_lower()
      if normalized == "sha1" || normalized == "sha256" {
        Some(normalized)
      } else {
        None
      }
    }
    None => None
  }
}

///|
fn repository_format_error(
  fs : &@bitcore.RepoFileSystem,
  git_dir : String,
) -> String? {
  let config_path = git_dir + "/config"
  let mut version = 0
  match
    @bitlib.read_config_value(
      fs, config_path, "core", "repositoryformatversion",
    ) {
    Some(raw_version) => {
      let normalized = @bitlib.config_strip_quotes(trim_string(raw_version))
      version = @strconv.parse_int(normalized) catch {
        _ => return Some("fatal: invalid core.repositoryformatversion")
      }
    }
    None => ()
  }
  if version < 0 || version > 1 {
    return Some(
      "fatal: unsupported repository format version: " + version.to_string(),
    )
  }
  let config_content = @bitlib.read_config_content(fs, git_dir)
  if config_content.length() == 0 {
    return None
  }
  let mut in_extensions = false
  for line in repository_config_split_lines(config_content) {
    let trimmed = trim_string(line)
    if trimmed.length() == 0 {
      continue
    }
    if trimmed[0] == '#' || trimmed[0] == ';' {
      continue
    }
    match parse_section_header_line(trimmed) {
      Some((section, subsection, _, _)) => {
        in_extensions = section.to_lower() == "extensions" && subsection is None
        continue
      }
      None => ()
    }
    if not(in_extensions) {
      continue
    }
    match repository_extension_key(trimmed) {
      Some(extension_name) => {
        let min_version = repository_extension_min_version(extension_name)
        if min_version >= 0 {
          if version < min_version {
            return Some(
              "error: repo version is \{version}, but v1-only extension found:\n\{extension_name}",
            )
          }
          // Validate known extension values
          let ext_value = repository_extension_value(trimmed)
          match repository_validate_extension(extension_name, ext_value) {
            Some(err) => return Some(err)
            None => ()
          }
        } else if version >= 1 {
          return Some("fatal: unknown repository extension: " + extension_name)
        } else if extension_name.has_suffix("-v1") {
          return Some(
            "error: repo version is \{version}, but v1-only extension found:\n\{extension_name}",
          )
        }
      }
      None => ()
    }
  }
  None
}

///|
fn repository_config_split_lines(content : String) -> Array[String] {
  let lines : Array[String] = []
  let mut start = 0
  for i in 0..<content.length() {
    if content[i] == '\n' {
      lines.push(String::unsafe_substring(content, start~, end=i))
      start = i + 1
    }
  }
  if start < content.length() {
    lines.push(String::unsafe_substring(content, start~, end=content.length()))
  }
  lines
}

///|
fn repository_extension_key(line : String) -> String? {
  let mut end = 0
  while end < line.length() {
    let c = line[end]
    if c == ' ' || c == '\t' || c == '=' || c == '#' || c == ';' {
      break
    }
    end += 1
  }
  if end == 0 {
    None
  } else {
    Some(String::unsafe_substring(line, start=0, end~).to_lower())
  }
}

///|
fn repository_extension_min_version(extension_name : String) -> Int {
  match extension_name {
    "noop" => 0
    "noop-v1" => 1
    "preciousobjects" => 1
    "objectformat" => 1
    "compatobjectformat" => 1
    "partialclone" => 1
    "worktreeconfig" => 1
    "relativeworktrees" => 1
    "refstorage" => 1
    _ => -1
  }
}

///|
/// Extract the value part from a config line like "key = value"
fn repository_extension_value(line : String) -> String {
  match line.find("=") {
    Some(idx) =>
      String::unsafe_substring(line, start=idx + 1, end=line.length())
      .trim()
      .to_string()
    None => ""
  }
}

///|
/// Validate a known extension's value. Returns Some(error) if invalid.
fn repository_validate_extension(name : String, value : String) -> String? {
  match name {
    "refstorage" => {
      let v = value.to_lower()
      if v != "files" && v != "reftable" && v != "" {
        Some("error: invalid value for 'extensions.refstorage': '\{v}'")
      } else {
        None
      }
    }
    _ => None
  }
}

///|
fn get_author_string() -> String {
  match @sys.get_env_var("GIT_AUTHOR_NAME") {
    Some(name) => {
      let email = @sys.get_env_var("GIT_AUTHOR_EMAIL").unwrap_or("unknown")
      name + " <" + email + ">"
    }
    None =>
      match @sys.get_env_var("USER") {
        Some(u) => u + " <" + u + "@localhost>"
        None => "Unknown <unknown@localhost>"
      }
  }
}

///|
fn get_committer_string() -> String {
  match @sys.get_env_var("GIT_COMMITTER_NAME") {
    Some(name) => {
      let email = @sys.get_env_var("GIT_COMMITTER_EMAIL").unwrap_or("unknown")
      name + " <" + email + ">"
    }
    None => get_author_string()
  }
}

///|
fn get_hub_signing_key() -> String? {
  match @sys.get_env_var("BIT_COLLAB_SIGN_KEY") {
    Some(value) => if value.length() > 0 { Some(value) } else { None }
    None => None
  }
}

///|
fn get_hub_require_signed() -> Bool {
  match @sys.get_env_var("BIT_COLLAB_REQUIRE_SIGNED") {
    Some(value) => {
      let normalized = value.to_lower()
      normalized == "1" || normalized == "true" || normalized == "yes"
    }
    None => false
  }
}

///|
fn get_commit_timestamp() -> Int64 {
  match @sys.get_env_var("GIT_COMMITTER_DATE") {
    Some(s) =>
      match parse_git_env_timestamp(s) {
        Some(ts) => ts
        None => get_current_timestamp()
      }
    None => get_current_timestamp()
  }
}

///|
fn parse_git_env_timestamp(raw : String) -> Int64? {
  let mut token : String? = None
  for part_view in raw.split(" ") {
    let part = part_view.to_string()
    if part.length() > 0 {
      token = Some(part)
      break
    }
  }
  match token {
    Some(part) =>
      if part.has_prefix("@") {
        let numeric = String::unsafe_substring(part, start=1, end=part.length())
        let parsed = @strconv.parse_int64(numeric) catch { _ => return None }
        Some(parsed)
      } else {
        // Try plain integer first
        let parsed = @strconv.parse_int64(part) catch { _ => -1L }
        if parsed >= 0L {
          return Some(parsed)
        }
        // Try ISO date format: YYYY-MM-DD[T ]HH:MM[:SS]
        parse_iso_date_timestamp(raw)
      }
    None => None
  }
}

///|
fn parse_iso_date_timestamp(raw : String) -> Int64? {
  // Extract date and time parts from ISO format
  // Formats: "2005-05-26 23:00", "2005-05-26T23:00", "2005-05-26 23:00:30"
  let s = raw.trim().to_string()
  // Need at least "YYYY-MM-DD HH:MM" = 16 chars
  if s.length() < 16 {
    return None
  }
  // Validate date separators
  if s[4] != '-' || s[7] != '-' {
    return None
  }
  let sep = s[10]
  if sep != ' ' && sep != 'T' {
    return None
  }
  let year = @strconv.parse_int64(String::unsafe_substring(s, start=0, end=4)) catch {
    _ => return None
  }
  let month = @strconv.parse_int64(String::unsafe_substring(s, start=5, end=7)) catch {
    _ => return None
  }
  let day = @strconv.parse_int64(String::unsafe_substring(s, start=8, end=10)) catch {
    _ => return None
  }
  // Parse time - find the time portion after the separator
  let time_str = String::unsafe_substring(s, start=11, end=s.length())
  // Extract HH:MM[:SS] - stop at space or +/- (timezone)
  let mut time_end = time_str.length()
  for i = 0; i < time_str.length(); i = i + 1 {
    let c = time_str[i]
    if c == ' ' || c == '+' || c == '-' {
      time_end = i
      break
    }
  }
  let time_part = String::unsafe_substring(time_str, start=0, end=time_end)
  if time_part.length() < 5 || time_part[2] != ':' {
    return None
  }
  let hour = @strconv.parse_int64(
    String::unsafe_substring(time_part, start=0, end=2),
  ) catch {
    _ => return None
  }
  let minute = @strconv.parse_int64(
    String::unsafe_substring(time_part, start=3, end=5),
  ) catch {
    _ => return None
  }
  let second = if time_part.length() >= 8 && time_part[5] == ':' {
    @strconv.parse_int64(String::unsafe_substring(time_part, start=6, end=8)) catch {
      _ => 0L
    }
  } else {
    0L
  }
  // Convert to Unix timestamp (UTC)
  // Days from epoch (1970-01-01) to the given date
  let days = days_from_epoch(year, month, day)
  Some(days * 86400L + hour * 3600L + minute * 60L + second)
}

///|
fn days_from_epoch(year : Int64, month : Int64, day : Int64) -> Int64 {
  let month_days : Array[Int64] = [
    0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334,
  ]
  let y = year
  let m = month
  // Days in complete years since 1970
  let mut days = 365L * (y - 1970L)
  // Add leap days for complete years
  // Leap year if divisible by 4, not by 100, or by 400
  if y > 1970L {
    days = days + (y - 1969L) / 4L - (y - 1901L) / 100L + (y - 1601L) / 400L
  } else {
    days = days - (1970L - y) / 4L + (1970L - y) / 100L - (1970L - y) / 400L
  }
  // Add days for complete months
  days = days + month_days[(m - 1L).to_int()]
  // Add leap day if after February in a leap year
  if m > 2L {
    let is_leap = (y % 4L == 0L && y % 100L != 0L) || y % 400L == 0L
    if is_leap {
      days = days + 1L
    }
  }
  // Add days within the month
  days + day - 1L
}

///|
fn get_commit_timezone() -> String {
  match @sys.get_env_var("GIT_COMMITTER_DATE") {
    Some(raw) =>
      match parse_git_env_timezone(raw) {
        Some(tz) => tz
        None => "+0000"
      }
    None => "+0000"
  }
}

///|
fn parse_git_env_timezone(raw : String) -> String? {
  let fields : Array[String] = []
  for part_view in raw.split(" ") {
    let part = part_view.to_string()
    if part.length() > 0 {
      fields.push(part)
    }
  }
  if fields.length() < 2 {
    return None
  }
  let tz = fields[fields.length() - 1]
  if is_valid_timezone_token(tz) {
    Some(tz)
  } else {
    None
  }
}

///|
fn is_valid_timezone_token(token : String) -> Bool {
  if token.length() != 5 {
    return false
  }
  let chars = token.to_array()
  if not(chars[0] == '+' || chars[0] == '-') {
    return false
  }
  for i = 1; i < chars.length(); i = i + 1 {
    let c = chars[i]
    if c < '0' || c > '9' {
      return false
    }
  }
  true
}

///|
async fn run_checkout_with_sensitive_hooks(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  spec : String,
  detach? : Bool = false,
  update_worktree? : Bool = true,
  update_index? : Bool = true,
) -> @bitcore.ObjectId raise Error {
  hooks_ensure_sensitive_hook_approval(fs, rfs, root, "post-checkout")
  @bitlib.checkout(
    fs,
    rfs,
    root,
    spec,
    detach~,
    update_worktree~,
    update_index~,
  )
}

///|
async fn run_merge_with_sensitive_hooks(
  fs : &@bitcore.FileSystem,
  rfs : &@bitcore.RepoFileSystem,
  root : String,
  target : @bitcore.ObjectId,
  message : String,
  author : String,
  timestamp : Int64,
) -> @bitlib.MergeResult raise Error {
  hooks_ensure_sensitive_hook_approval(fs, rfs, root, "post-merge")
  @bitlib.merge(fs, rfs, root, target, message, author, timestamp)
}

///|
fn make_relative_to_cwd(path : String) -> String {
  if not(path.has_prefix("/")) {
    return path
  }
  let cwd = match @sys.get_env_var("GIT_SHIM_PWD") {
    Some(d) => d
    None =>
      match @env.current_dir() {
        Some(d) => d
        None => return path
      }
  }
  if cwd.length() == 0 {
    return path
  }
  let prefix = if cwd.has_suffix("/") { cwd } else { cwd + "/" }
  if path.has_prefix(prefix) {
    let rel = (try! path[prefix.length():]).to_string()
    if rel.length() == 0 {
      "."
    } else {
      rel
    }
  } else {
    path
  }
}

///|
fn quote_origin_path(path : String) -> String {
  let mut needs_quote = false
  for ch in path {
    if ch == '"' || ch == '\t' || ch == '\\' || ch == '\n' {
      needs_quote = true
      break
    }
  }
  if not(needs_quote) {
    return path
  }
  let buf = StringBuilder::new()
  buf.write_char('"')
  for ch in path {
    if ch == '"' || ch == '\\' {
      buf.write_char('\\')
    }
    buf.write_char(ch)
  }
  buf.write_char('"')
  buf.to_string()
}
