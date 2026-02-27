///|
test "fallback: need_real_git_for_autocrlf detects non-false values" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-fallback-autocrlf-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root + "/.git")
  let cleanup = fn() {
    fs.remove_file(root + "/.git/config") catch {
      _ => ()
    }
    fs.remove_dir(root + "/.git") catch {
      _ => ()
    }
    fs.remove_dir(root) catch {
      _ => ()
    }
  }

  fs.write_file(
    root + "/.git/config",
    string_to_bytes("[core]\nautocrlf = true\n"),
  )
  assert_true(need_real_git_for_autocrlf(root))

  fs.write_file(
    root + "/.git/config",
    string_to_bytes("[core]\nautocrlf = input\n"),
  )
  assert_true(need_real_git_for_autocrlf(root))

  fs.write_file(
    root + "/.git/config",
    string_to_bytes("[core]\nautocrlf = false\n"),
  )
  assert_false(need_real_git_for_autocrlf(root))

  fs.write_file(
    root + "/.git/config",
    string_to_bytes("[core]\nautocrlf = mixed\n"),
  )
  assert_true(need_real_git_for_autocrlf(root))
  cleanup()
}

///|
test "fallback: need_real_git_for_gitattributes detects filter/text/eol attributes" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-fallback-gitattr-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root + "/.git")
  let cleanup = fn() {
    fs.remove_file(root + "/.gitattributes") catch {
      _ => ()
    }
    fs.remove_file(root + "/.git/config") catch {
      _ => ()
    }
    fs.remove_dir(root + "/.git") catch {
      _ => ()
    }
    fs.remove_dir(root) catch {
      _ => ()
    }
  }

  fs.write_file(root + "/.gitattributes", string_to_bytes("*.txt -text\n"))
  assert_true(need_real_git_for_gitattributes(root))

  fs.write_file(root + "/.gitattributes", string_to_bytes("*.txt text\n"))
  assert_true(need_real_git_for_gitattributes(root))

  fs.write_file(root + "/.gitattributes", string_to_bytes("*.txt eol=crlf\n"))
  assert_true(need_real_git_for_gitattributes(root))

  fs.write_file(
    root + "/.gitattributes",
    string_to_bytes("*.txt filter=foo diff=bar\n"),
  )
  assert_true(need_real_git_for_gitattributes(root))

  fs.write_file(
    root + "/.gitattributes",
    string_to_bytes("# comment only\n   \n"),
  )
  assert_false(need_real_git_for_gitattributes(root))
  cleanup()
}

///|
test "fallback: need_real_git_for_filtering combines autocrlf and gitattributes" {
  let fs = OsFs::new()
  let root = "/tmp/bit-test-fallback-filtering-" +
    get_current_timestamp().to_string()
  fs.mkdir_p(root + "/.git")
  let cleanup = fn() {
    fs.remove_file(root + "/.gitattributes") catch {
      _ => ()
    }
    fs.remove_file(root + "/.git/config") catch {
      _ => ()
    }
    fs.remove_dir(root + "/.git") catch {
      _ => ()
    }
    fs.remove_dir(root) catch {
      _ => ()
    }
  }

  // neither autocrlf nor gitattributes
  fs.write_file(
    root + "/.git/config",
    string_to_bytes("[core]\nautocrlf = false\n"),
  )
  assert_false(need_real_git_for_filtering(root))

  // autocrlf triggers
  fs.write_file(
    root + "/.git/config",
    string_to_bytes("[core]\nautocrlf = true\n"),
  )
  assert_true(need_real_git_for_filtering(root))

  // gitattributes triggers (with autocrlf=false)
  fs.write_file(
    root + "/.git/config",
    string_to_bytes("[core]\nautocrlf = false\n"),
  )
  fs.write_file(root + "/.gitattributes", string_to_bytes("*.txt text\n"))
  assert_true(need_real_git_for_filtering(root))
  cleanup()
}
