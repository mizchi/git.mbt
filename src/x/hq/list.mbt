///|
/// List repositories under bhq root
pub fn hq_list(
  config : HqConfig,
  query : String?,
  /// List directories at path, returns (name, is_dir)
  list_dir : (String) -> Array[(String, Bool)],
  /// Check if path is a git repository
  is_git_repo : (String) -> Bool,
) -> Array[String] {
  let repos : Array[String] = []
  scan_repos(config.root, "", list_dir, is_git_repo, repos)
  // Filter by query if provided
  match query {
    Some(q) => repos.filter(fn(path) { path.contains(q) })
    None => repos
  }
}

///|
fn scan_repos(
  root : String,
  rel_path : String,
  list_dir : (String) -> Array[(String, Bool)],
  is_git_repo : (String) -> Bool,
  repos : Array[String],
) -> Unit {
  let current_path = if rel_path.is_empty() {
    root
  } else {
    "\{root}/\{rel_path}"
  }
  // Check if current path is a git repo
  if is_git_repo(current_path) {
    repos.push(rel_path)
    return // Don't descend into git repos
  }
  // List and recurse into subdirectories
  let entries = list_dir(current_path)
  for entry in entries {
    let (name, is_dir) = entry
    if is_dir && not(name.has_prefix(".")) {
      let new_rel = if rel_path.is_empty() {
        name
      } else {
        "\{rel_path}/\{name}"
      }
      scan_repos(root, new_rel, list_dir, is_git_repo, repos)
    }
  }
}

///|
/// List repositories with full paths
pub fn hq_list_full_paths(
  config : HqConfig,
  query : String?,
  list_dir : (String) -> Array[(String, Bool)],
  is_git_repo : (String) -> Bool,
) -> Array[String] {
  hq_list(config, query, list_dir, is_git_repo).map(fn(rel) {
    "\{config.root}/\{rel}"
  })
}

///|
/// Parse a repository path back to RepoPath
pub fn parse_repo_path(rel_path : String) -> RepoPath? {
  let parts = rel_path.split("/").collect()
  // Check if first part looks like a host
  if parts.length() >= 3 && parts[0].to_string().contains(".") {
    // host/user/repo
    let host = parts[0].to_string()
    let normalized_host : String? = if host == "github.com" {
      None
    } else {
      Some(host)
    }
    Some(
      RepoPath::new(
        parts[1].to_string(),
        parts[2].to_string(),
        host=normalized_host,
      ),
    )
  } else if parts.length() >= 2 {
    // user/repo (github.com implicit)
    Some(RepoPath::new(parts[0].to_string(), parts[1].to_string()))
  } else {
    None
  }
}
