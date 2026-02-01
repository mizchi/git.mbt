///|
/// Execute hq get command
///
/// Clone a repository to the bhq root directory.
/// If subdir is specified, use sparse checkout.
pub fn hq_get(
  repo : RepoPath,
  config : HqConfig,
  options : HqGetOptions,
  /// Execute shell command and return (exit_code, stdout, stderr)
  exec : (String) -> (Int, String, String),
  /// Check if path exists
  path_exists : (String) -> Bool,
) -> HqGetResult {
  let local_path = repo.local_path(config.root)
  // Check if already exists
  if path_exists(local_path) {
    if options.update {
      // Update existing repository
      let cmd = "cd \{local_path} && git pull --ff-only"
      let (code, _stdout, stderr) = exec(cmd)
      if code == 0 {
        HqGetResult::Updated(local_path)
      } else {
        HqGetResult::Error("Failed to update: \{stderr}")
      }
    } else {
      HqGetResult::Skipped(local_path)
    }
  } else {
    // Clone new repository
    let clone_result = if repo.needs_sparse() {
      clone_sparse(repo, local_path, options, exec)
    } else {
      clone_normal(repo, local_path, options, exec)
    }
    match clone_result {
      Ok(_) => HqGetResult::Cloned(local_path)
      Err(msg) => HqGetResult::Error(msg)
    }
  }
}

///|
fn clone_normal(
  repo : RepoPath,
  local_path : String,
  options : HqGetOptions,
  exec : (String) -> (Int, String, String),
) -> Result[Unit, String] {
  let url = repo.clone_url(ssh=options.ssh)
  let args : Array[String] = ["git", "clone"]
  if options.shallow {
    args.push("--depth=1")
  }
  match options.branch {
    Some(branch) => {
      args.push("--branch")
      args.push(branch)
    }
    None => ()
  }
  args.push(url)
  args.push(local_path)
  let cmd = args.iter().map(fn(s) { s }).join(" ")
  let (code, _stdout, stderr) = exec(cmd)
  if code == 0 {
    Ok(())
  } else {
    Err("Clone failed: \{stderr}")
  }
}

///|
fn clone_sparse(
  repo : RepoPath,
  local_path : String,
  options : HqGetOptions,
  exec : (String) -> (Int, String, String),
) -> Result[Unit, String] {
  let url = repo.clone_url(ssh=options.ssh)
  let subdir = repo.subdir.unwrap_or("")
  // Step 1: Clone with filter and no checkout
  let clone_args : Array[String] = [
    "git", "clone", "--filter=blob:none", "--no-checkout",
  ]
  if options.shallow {
    clone_args.push("--depth=1")
  }
  match options.branch {
    Some(branch) => {
      clone_args.push("--branch")
      clone_args.push(branch)
    }
    None => ()
  }
  clone_args.push(url)
  clone_args.push(local_path)
  let clone_cmd = clone_args.iter().map(fn(s) { s }).join(" ")
  let (code1, _stdout1, stderr1) = exec(clone_cmd)
  if code1 != 0 {
    return Err("Clone failed: \{stderr1}")
  }
  // Step 2: Initialize sparse checkout
  let sparse_init_cmd = "cd \{local_path} && git sparse-checkout init --cone"
  let (code2, _stdout2, stderr2) = exec(sparse_init_cmd)
  if code2 != 0 {
    return Err("Sparse checkout init failed: \{stderr2}")
  }
  // Step 3: Set sparse checkout paths
  let sparse_set_cmd = "cd \{local_path} && git sparse-checkout set \{subdir}"
  let (code3, _stdout3, stderr3) = exec(sparse_set_cmd)
  if code3 != 0 {
    return Err("Sparse checkout set failed: \{stderr3}")
  }
  // Step 4: Checkout
  let checkout_cmd = "cd \{local_path} && git checkout"
  let (code4, _stdout4, stderr4) = exec(checkout_cmd)
  if code4 != 0 {
    return Err("Checkout failed: \{stderr4}")
  }
  Ok(())
}

///|
/// Build the git clone command string (for display/logging)
pub fn build_clone_command(
  repo : RepoPath,
  local_path : String,
  options : HqGetOptions,
) -> String {
  let url = repo.clone_url(ssh=options.ssh)
  if repo.needs_sparse() {
    let subdir = repo.subdir.unwrap_or("")
    "git clone --filter=blob:none --no-checkout \{url} \{local_path} && cd \{local_path} && git sparse-checkout init --cone && git sparse-checkout set \{subdir} && git checkout"
  } else {
    let args : Array[String] = ["git", "clone"]
    if options.shallow {
      args.push("--depth=1")
    }
    match options.branch {
      Some(branch) => {
        args.push("--branch")
        args.push(branch)
      }
      None => ()
    }
    args.push(url)
    args.push(local_path)
    args.iter().map(fn(s) { s }).join(" ")
  }
}
