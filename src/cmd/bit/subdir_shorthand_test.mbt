///| Tests for clone shorthand parsing

///| Supports: user/repo, user/repo:path, host/user/repo, and GitHub browser URLs

// ============================================================================
// Tests for GitHub browser URLs (tree/blob)
// ============================================================================

///|
test "github URL: /tree/ directory" {
  let result = parse_github_shorthand(
    "https://github.com/mizchi/crater/tree/main/js",
  )
  assert_eq(result, Some(Subdir("https://github.com/mizchi/crater", "js")))
}

///|
test "github URL: /tree/ nested directory" {
  let result = parse_github_shorthand(
    "https://github.com/user/repo/tree/main/src/lib/core",
  )
  assert_eq(
    result,
    Some(Subdir("https://github.com/user/repo", "src/lib/core")),
  )
}

///|
test "github URL: /tree/ with branch name" {
  let result = parse_github_shorthand(
    "https://github.com/user/repo/tree/feature/auth/src",
  )
  // branch is "feature", path starts from "auth/src" - this is a limitation
  // For now, we treat everything after tree/X as path where X is branch
  assert_eq(result, Some(Subdir("https://github.com/user/repo", "auth/src")))
}

///|
test "github URL: /blob/ file" {
  let result = parse_github_shorthand(
    "https://github.com/mizchi/crater/blob/main/README.md",
  )
  assert_eq(
    result,
    Some(
      File(
        "https://raw.githubusercontent.com/mizchi/crater/main/README.md", "README.md",
      ),
    ),
  )
}

///|
test "github URL: /blob/ nested file" {
  let result = parse_github_shorthand(
    "https://github.com/user/repo/blob/main/src/lib/index.ts",
  )
  assert_eq(
    result,
    Some(
      File(
        "https://raw.githubusercontent.com/user/repo/main/src/lib/index.ts", "index.ts",
      ),
    ),
  )
}

///|
test "github URL: repo root (no tree/blob)" {
  // https://github.com/user/repo without tree/blob should not match
  let result = parse_github_shorthand("https://github.com/user/repo")
  assert_eq(result, None)
}

// ============================================================================
// Tests for user/repo (full repo clone)
// ============================================================================

///|
test "shorthand: user/repo" {
  let result = parse_github_shorthand("user/repo")
  assert_eq(result, Some(Repo("https://github.com/user/repo")))
}

///|
test "shorthand: mizchi/bit" {
  let result = parse_github_shorthand("mizchi/bit")
  assert_eq(result, Some(Repo("https://github.com/mizchi/bit")))
}

// ============================================================================
// Tests for user/repo:path (subdir clone with colon separator)
// ============================================================================

///|
test "shorthand: user/repo:src" {
  let result = parse_github_shorthand("user/repo:src")
  assert_eq(result, Some(Subdir("https://github.com/user/repo", "src")))
}

///|
test "shorthand: user/repo:src/lib/core (deep path)" {
  let result = parse_github_shorthand("user/repo:src/lib/core")
  assert_eq(
    result,
    Some(Subdir("https://github.com/user/repo", "src/lib/core")),
  )
}

///|
test "shorthand: mizchi/bit:src/x/bitfs" {
  let result = parse_github_shorthand("mizchi/bit:src/x/bitfs")
  assert_eq(
    result,
    Some(Subdir("https://github.com/mizchi/bit", "src/x/bitfs")),
  )
}

// ============================================================================
// Tests for host/user/repo (other Git hosts)
// ============================================================================

///|
test "shorthand: gitlab.com/user/repo" {
  let result = parse_github_shorthand("gitlab.com/user/repo")
  assert_eq(result, Some(Repo("https://gitlab.com/user/repo")))
}

///|
test "shorthand: gitlab.com/user/repo:src" {
  let result = parse_github_shorthand("gitlab.com/user/repo:src")
  assert_eq(result, Some(Subdir("https://gitlab.com/user/repo", "src")))
}

///|
test "shorthand: bitbucket.org/user/repo" {
  let result = parse_github_shorthand("bitbucket.org/user/repo")
  assert_eq(result, Some(Repo("https://bitbucket.org/user/repo")))
}

// ============================================================================
// Tests for patterns that should NOT trigger shorthand
// ============================================================================

///|
test "NOT shorthand: full HTTPS URL" {
  let result = parse_github_shorthand("https://gitlab.com/user/repo")
  assert_eq(result, None)
}

///|
test "NOT shorthand: SSH URL" {
  let result = parse_github_shorthand("git@github.com:user/repo.git")
  assert_eq(result, None)
}

///|
test "NOT shorthand: local path ./" {
  let result = parse_github_shorthand("./local/repo/path")
  assert_eq(result, None)
}

///|
test "NOT shorthand: absolute path" {
  let result = parse_github_shorthand("/home/user/repo")
  assert_eq(result, None)
}

///|
test "NOT shorthand: URL with .git suffix" {
  let result = parse_github_shorthand("user/repo.git")
  assert_eq(result, None)
}

///|
test "NOT shorthand: parent path ../" {
  let result = parse_github_shorthand("../other/repo")
  assert_eq(result, None)
}

// ============================================================================
// Edge cases
// ============================================================================

///|
test "NOT shorthand: single component" {
  let result = parse_github_shorthand("user")
  assert_eq(result, None)
}

///|
test "NOT shorthand: empty string" {
  let result = parse_github_shorthand("")
  assert_eq(result, None)
}

///|
test "shorthand: trailing slash user/repo/" {
  let result = parse_github_shorthand("user/repo/")
  // Trailing slash means 3 parts but third is empty, so only 2 valid parts
  assert_eq(result, Some(Repo("https://github.com/user/repo")))
}

///|
test "shorthand: colon with empty subdir user/repo:" {
  let result = parse_github_shorthand("user/repo:")
  // Empty subdir after colon → treated as full repo
  assert_eq(result, Some(Repo("https://github.com/user/repo")))
}

// ============================================================================
// Ambiguity check tests
// ============================================================================

///|
test "ambiguity: no conflict" {
  fn no_dirs(_path : String) -> Bool {
    false
  }

  let result = check_shorthand_ambiguity("user/repo", no_dirs)
  assert_eq(result, None)
}

///|
test "ambiguity: first component exists" {
  fn user_exists(path : String) -> Bool {
    path == "user"
  }

  let result = check_shorthand_ambiguity("user/repo", user_exists)
  assert_eq(result, Some("user"))
}

///|
test "ambiguity: full path exists" {
  fn path_exists(path : String) -> Bool {
    path == "user/repo"
  }

  let result = check_shorthand_ambiguity("user/repo", path_exists)
  assert_eq(result, Some("user/repo"))
}

///|
test "ambiguity: not checked for full URL" {
  fn always_exists(_path : String) -> Bool {
    true
  }

  let result = check_shorthand_ambiguity(
    "https://github.com/user/repo", always_exists,
  )
  assert_eq(result, None)
}

///|
test "ambiguity: not checked for .git suffix" {
  fn always_exists(_path : String) -> Bool {
    true
  }

  let result = check_shorthand_ambiguity("user/repo.git", always_exists)
  assert_eq(result, None)
}

///|
test "ambiguity: checked for subdir shorthand" {
  fn user_exists(path : String) -> Bool {
    path == "user"
  }

  let result = check_shorthand_ambiguity("user/repo:src/lib", user_exists)
  assert_eq(result, Some("user"))
}

///|
test "ambiguity: not checked for local path" {
  fn always_exists(_path : String) -> Bool {
    true
  }

  let result = check_shorthand_ambiguity("./user/repo", always_exists)
  assert_eq(result, None)
}
