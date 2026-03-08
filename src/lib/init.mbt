///| Git repository initialization

///|
pub(all) struct InitOptions {
  default_branch : String
  bare : Bool
  separate_git_dir : String?
  template_dir : String?
  ref_format : String
  object_format : String
  is_reinit : Bool
  git_dir : String? // explicit GIT_DIR override (no .git file created)
  work_tree : String? // explicit core.worktree to write to config
  shared : String? // --shared value for directory permissions
}

///|
pub fn InitOptions::new() -> InitOptions {
  {
    default_branch: "main",
    bare: false,
    separate_git_dir: None,
    template_dir: None,
    ref_format: "files",
    object_format: "sha1",
    is_reinit: false,
    git_dir: None,
    work_tree: None,
    shared: None,
  }
}

///|
/// Initialize a repository at `root` with a default branch.
/// If `bare` is true, creates a bare repository (no working tree).
/// If the repository already exists, this is a reinit and preserves existing HEAD.
pub fn init_repo(
  fs : &@bit.FileSystem,
  root : String,
  default_branch? : String = "main",
  bare? : Bool = false,
) -> Unit raise @bit.GitError {
  init_repo_with_options(fs, root, {
    default_branch,
    bare,
    separate_git_dir: None,
    template_dir: None,
    ref_format: "files",
    object_format: "sha1",
    is_reinit: false,
    git_dir: None,
    work_tree: None,
    shared: None,
  })
}

///|
/// Initialize a repository with full options. If `separate_git_dir` is set, this
/// version does not inspect the existing `.git` target and only updates `.git` atomically.
pub fn init_repo_with_options(
  fs : &@bit.FileSystem,
  root : String,
  opts : InitOptions,
) -> Unit raise @bit.GitError {
  let bare = opts.bare
  let git_dir = match (opts.git_dir, opts.separate_git_dir) {
    (Some(explicit_dir), _) => explicit_dir
    (None, Some(sep_dir)) => sep_dir
    (None, None) => if bare { root } else { join_path(root, ".git") }
  }
  let use_default_template_files = opts.template_dir is None
  let head_path = join_path(git_dir, "HEAD")
  if opts.separate_git_dir is Some(_) && not(bare) {
    fs.mkdir_p(root)
  }
  fs.mkdir_p(git_dir)
  fs.mkdir_p(join_path(git_dir, "objects"))
  fs.mkdir_p(join_path(git_dir, "objects/info"))
  fs.mkdir_p(join_path(git_dir, "objects/pack"))
  fs.mkdir_p(join_path(git_dir, "refs/heads"))
  fs.mkdir_p(join_path(git_dir, "refs/tags"))
  if use_default_template_files {
    fs.mkdir_p(join_path(git_dir, "hooks"))
    fs.mkdir_p(join_path(git_dir, "info"))
  }
  if opts.separate_git_dir is Some(_) && not(bare) {
    let gitfile_path = join_path(root, ".git")
    fs.remove_dir(gitfile_path) catch {
      _ => ()
    }
    fs.remove_file(gitfile_path) catch {
      _ => ()
    }
    fs.write_string(gitfile_path, "gitdir: " + git_dir + "\n")
  }
  if not(opts.is_reinit) {
    fs.write_string(head_path, "ref: refs/heads/" + opts.default_branch + "\n")
  }
  let bare_str = if bare { "true" } else { "false" }
  let mut repository_format_version = "0"
  if opts.ref_format == "reftable" || opts.object_format != "sha1" {
    repository_format_version = "1"
  }
  let mut config = "[core]\n\trepositoryformatversion = " +
    repository_format_version +
    "\n\tfilemode = true\n\tbare = " +
    bare_str +
    "\n"
  match opts.work_tree {
    Some(wt) => config = config + "\tworktree = " + wt + "\n"
    None => ()
  }
  if not(bare) {
    config = config + "\tlogallrefupdates = true\n"
  }
  if opts.ref_format == "reftable" {
    fs.mkdir_p(join_path(git_dir, "reftable"))
    fs.write_string(join_path(git_dir, "reftable/tables.list"), "")
  }
  let extension_lines : Array[String] = []
  if opts.ref_format == "reftable" {
    extension_lines.push("\trefStorage = reftable")
  }
  if opts.object_format != "sha1" {
    extension_lines.push("\tobjectFormat = " + opts.object_format)
  }
  if extension_lines.length() > 0 {
    config += "[extensions]\n" + extension_lines.join("\n") + "\n"
  }
  match opts.shared {
    Some(shared_val) =>
      config = config + "\tsharedRepository = " + shared_val + "\n"
    None => ()
  }
  fs.write_string(join_path(git_dir, "config"), config)
  if use_default_template_files {
    fs.write_string(
      join_path(git_dir, "description"),
      "Unnamed repository; edit this file 'description' to name the repository.\n",
    )
    fs.write_string(join_path(git_dir, "info/exclude"), "")
  }
}

///|
/// Initialize a repository with full options and full `.git` resolution via RepoFileSystem.
/// This is used when reinitializing with --separate-git-dir to migrate existing data.
pub fn init_repo_with_options_with_repo_fs(
  fs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  root : String,
  opts : InitOptions,
) -> Unit raise @bit.GitError {
  let bare = opts.bare
  // Determine git directory location
  let git_dir = match (opts.git_dir, opts.separate_git_dir) {
    (Some(explicit_dir), _) => explicit_dir
    (None, Some(sep_dir)) => sep_dir
    (None, None) => if bare { root } else { join_path(root, ".git") }
  }
  let use_default_template_files = opts.template_dir is None
  let head_path = join_path(git_dir, "HEAD")
  // Create work tree directory if needed (for --separate-git-dir)
  if opts.separate_git_dir is Some(_) && not(bare) {
    fs.mkdir_p(root)
  }
  // Create git directory structure
  fs.mkdir_p(git_dir)
  fs.mkdir_p(join_path(git_dir, "objects"))
  fs.mkdir_p(join_path(git_dir, "objects/info"))
  fs.mkdir_p(join_path(git_dir, "objects/pack"))
  fs.mkdir_p(join_path(git_dir, "refs/heads"))
  fs.mkdir_p(join_path(git_dir, "refs/tags"))
  if use_default_template_files {
    fs.mkdir_p(join_path(git_dir, "hooks"))
    fs.mkdir_p(join_path(git_dir, "info"))
  }
  // If separate-git-dir, create .git file pointing to actual git dir
  if opts.separate_git_dir is Some(_) && not(bare) {
    let gitfile_path = join_path(root, ".git")
    let existing_git_dir = if rfs.is_dir(gitfile_path) {
      Some(gitfile_path)
    } else if rfs.is_file(gitfile_path) {
      let existing = resolve_gitdir(rfs, gitfile_path)
      if existing == gitfile_path {
        None
      } else {
        Some(existing)
      }
    } else {
      None
    }
    match existing_git_dir {
      Some(old_git_dir) =>
        if old_git_dir != git_dir && rfs.is_dir(old_git_dir) {
          if rfs.is_dir(git_dir) || rfs.is_file(git_dir) {
            remove_tree(fs, rfs, git_dir)
          }
          move_tree(fs, rfs, old_git_dir, git_dir)
        }
      None => ()
    }
    fs.write_string(gitfile_path, "gitdir: " + git_dir + "\n")
  }
  // Write HEAD only on fresh init (not re-init)
  if not(opts.is_reinit) {
    fs.write_string(head_path, "ref: refs/heads/" + opts.default_branch + "\n")
  }
  // Create/update config file with appropriate bare setting
  let bare_str = if bare { "true" } else { "false" }
  let mut repository_format_version = "0"
  if opts.ref_format == "reftable" || opts.object_format != "sha1" {
    repository_format_version = "1"
  }
  let mut config = "[core]\n\trepositoryformatversion = " +
    repository_format_version +
    "\n\tfilemode = true\n\tbare = " +
    bare_str +
    "\n"
  // Write core.worktree if explicitly set
  match opts.work_tree {
    Some(wt) => config = config + "\tworktree = " + wt + "\n"
    None => ()
  }
  // Write core.logallrefupdates for non-bare repos
  if not(bare) {
    config = config + "\tlogallrefupdates = true\n"
  }
  if opts.ref_format == "reftable" {
    fs.mkdir_p(join_path(git_dir, "reftable"))
    let tables_list_path = join_path(git_dir, "reftable/tables.list")
    fs.write_string(tables_list_path, "")
  }
  let extension_lines : Array[String] = []
  if opts.ref_format == "reftable" {
    extension_lines.push("\trefStorage = reftable")
  }
  if opts.object_format != "sha1" {
    extension_lines.push("\tobjectFormat = " + opts.object_format)
  }
  if extension_lines.length() > 0 {
    config += "[extensions]\n" + extension_lines.join("\n") + "\n"
  }
  // Write --shared config
  match opts.shared {
    Some(shared_val) =>
      config = config + "\tsharedRepository = " + shared_val + "\n"
    None => ()
  }
  fs.write_string(join_path(git_dir, "config"), config)
  if use_default_template_files {
    // Create description file
    fs.write_string(
      join_path(git_dir, "description"),
      "Unnamed repository; edit this file 'description' to name the repository.\n",
    )
    // Create info/exclude
    fs.write_string(join_path(git_dir, "info/exclude"), "")
  }
}

///|
/// Copy template directory contents to git directory.
/// This should be called after init_repo_with_options if template_dir is specified.
pub fn apply_template(
  wfs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  git_dir : String,
  template_dir : String,
) -> Unit raise @bit.GitError {
  copy_dir_recursive(wfs, rfs, template_dir, git_dir)
}

///|
fn copy_dir_recursive(
  wfs : &@bit.FileSystem,
  rfs : &@bit.RepoFileSystem,
  src : String,
  dst : String,
) -> Unit raise @bit.GitError {
  if not(rfs.is_dir(src)) {
    return
  }
  wfs.mkdir_p(dst)
  let entries = rfs.readdir(src)
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    let src_path = join_path(src, entry)
    let dst_path = join_path(dst, entry)
    if rfs.is_dir(src_path) {
      copy_dir_recursive(wfs, rfs, src_path, dst_path)
    } else if rfs.is_file(src_path) {
      // Don't overwrite existing files
      if not(rfs.is_file(dst_path)) {
        let content = rfs.read_file(src_path)
        wfs.write_file(dst_path, content)
      }
    }
  }
}
