///|
/// Get the primary bhq root directory
pub fn hq_root(config : HqConfig) -> String {
  config.root
}

///|
/// Get all configured roots (for ghq compatibility)
pub fn hq_roots(
  env_get : (String) -> String?,
  git_config_get_all : (String) -> Array[String],
) -> Array[String] {
  let roots : Array[String] = []
  // Check BHQ_ROOT first
  match env_get("BHQ_ROOT") {
    Some(root) if not(root.is_empty()) => roots.push(expand_home(root))
    _ => ()
  }
  // Add ghq.root values
  let ghq_roots = git_config_get_all("ghq.root")
  for root in ghq_roots {
    let expanded = expand_home(root)
    if not(roots.contains(expanded)) {
      roots.push(expanded)
    }
  }
  // Add default if empty
  if roots.is_empty() {
    roots.push(expand_home(default_bhq_root))
  }
  roots
}
