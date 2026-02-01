///|
/// Default bhq root directory
let default_bhq_root : String = "~/bhq"

///|
/// Load hq configuration from environment and git config
///
/// Priority:
/// 1. BHQ_ROOT environment variable
/// 2. ghq.root from git config (if ghq_compat mode)
/// 3. ~/bhq (default)
pub fn load_config(
  env_get : (String) -> String?,
  git_config_get : (String) -> String?,
  ghq_compat? : Bool = false,
) -> HqConfig {
  let home = env_get("HOME").unwrap_or("/home/user")
  // Check BHQ_ROOT environment variable first
  match env_get("BHQ_ROOT") {
    Some(root) if not(root.is_empty()) =>
      HqConfig::new(expand_home_with(root, home))
    _ =>
      // If ghq_compat mode, check ghq.root
      if ghq_compat {
        match git_config_get("ghq.root") {
          Some(root) if not(root.is_empty()) =>
            HqConfig::new(expand_home_with(root, home), ghq_compat=true)
          _ => HqConfig::new(expand_home_with(default_bhq_root, home))
        }
      } else {
        HqConfig::new(expand_home_with(default_bhq_root, home))
      }
  }
}

///|
/// Expand ~ to home directory using provided home path
pub fn expand_home_with(path : String, home : String) -> String {
  if path.has_prefix("~/") {
    home + slice_from(path, 1)
  } else if path == "~" {
    home
  } else {
    path
  }
}

///|
/// Expand ~ to home directory (uses placeholder, prefer expand_home_with)
pub fn expand_home(path : String) -> String {
  expand_home_with(path, "/home/user")
}

///|
/// Contract home directory back to ~
pub fn contract_home(path : String, home : String) -> String {
  if path.has_prefix(home) {
    "~" + slice_from(path, home.length())
  } else {
    path
  }
}

///|
/// Safe string slice from start index to end
fn slice_from(s : String, start : Int) -> String {
  let buf = StringBuilder::new()
  for i = start; i < s.length(); i = i + 1 {
    match s.get_char(i) {
      Some(c) => buf.write_char(c)
      None => ()
    }
  }
  buf.to_string()
}

///|
/// Safe string slice from 0 to end index
fn slice_to(s : String, end : Int) -> String {
  let buf = StringBuilder::new()
  for i = 0; i < end && i < s.length(); i = i + 1 {
    match s.get_char(i) {
      Some(c) => buf.write_char(c)
      None => ()
    }
  }
  buf.to_string()
}
