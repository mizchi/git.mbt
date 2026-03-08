///| E2E benchmarks for log command
///  Measures commit traversal cost with varying commit counts
///  NOTE: bit log defaults to max_count=10, so -n must be explicit for scaling tests

///|
/// Run with:
/// - moon bench -p mizchi/bit/cmd/bit --target native -f bench_log_wbtest.mbt

///|
let bench_log_root : String = "/tmp/bit_bench_log_v1"

///|
let bench_log_small : String = bench_log_root + "/small"

///|
let bench_log_medium : String = bench_log_root + "/medium"

///|
let bench_log_large : String = bench_log_root + "/large"

///|
fn bench_log_ensure_dir(path : String) -> Unit {
  if not(@fs.path_exists(path)) {
    @fs.create_dir(path) catch {
      _ => ()
    }
  }
}

///|
fn bench_log_cleanup_tree(fs : OsFs, path : String) -> Unit {
  if fs.is_file(path) {
    fs.remove_file(path) catch {
      _ => ()
    }
    return
  }
  if not(fs.is_dir(path)) {
    return
  }
  let entries = fs.readdir(path) catch { _ => [] }
  for entry in entries {
    if entry == "." || entry == ".." {
      continue
    }
    bench_log_cleanup_tree(fs, path + "/" + entry)
  }
  fs.remove_dir(path) catch {
    _ => ()
  }
}

///|
fn bench_log_reset_env() -> Unit {
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  @sys.unset_env_var("GIT_SHIM_CWD")
  @sys.unset_env_var("GIT_SHIM_PWD")
  @sys.unset_env_var("GIT_SHIM_EXPLICIT_GIT_DIR")
  @sys.unset_env_var("GIT_CONFIG_OVERRIDES")
  @sys.unset_env_var("BIT_PROFILE")
}

///|
fn bench_log_init_probe() -> Unit {
  @bitnative.init_native_io()
}

///|
fn bench_log_ensure_repo(
  repo_root : String,
  file_count : Int,
  commit_count : Int,
) -> Unit {
  let marker = repo_root + "/.bench_ready"
  if @fs.path_exists(marker) {
    return
  }
  bench_log_init_probe()
  let fs = OsFs::new()
  bench_log_ensure_dir(bench_log_root)
  bench_log_cleanup_tree(fs, repo_root)
  bench_log_ensure_dir(repo_root)
  ignore(try? @bitrepo.init_repo(fs, repo_root))
  // Create initial files
  for i in 0..<file_count {
    @fs.write_string_to_file(
      repo_root + "/file_\{i}.txt",
      "initial content for file \{i}\n",
    ) catch {
      _ => ()
    }
  }
  @async.run_async_main(async fn() {
    ignore(try? @bitlib.add_paths_async(fs, fs, repo_root, ["."]))
  })
  ignore(
    try? @bitlib.commit(
      fs, fs, repo_root, "initial commit\n", "Bench <bench@example.com>", 1700000000L,
    ),
  )
  // Create remaining commits, each modifying one file
  for c in 1..<commit_count {
    let file_idx = c % file_count
    let path = repo_root + "/file_\{file_idx}.txt"
    @fs.write_string_to_file(path, "commit \{c} content\n") catch {
      _ => ()
    }
    @async.run_async_main(async fn() {
      ignore(try? @bitlib.add_paths_async(fs, fs, repo_root, [path]))
    })
    ignore(
      try? @bitlib.commit(
        fs,
        fs,
        repo_root,
        "commit \{c}\n",
        "Bench <bench@example.com>",
        1700000000L + c.to_int64(),
      ),
    )
  }
  @fs.write_string_to_file(marker, "ok\n") catch {
    _ => ()
  }
}

///|
fn bench_log_run(repo_root : String, args : Array[String]) -> Int {
  bench_log_init_probe()
  bench_log_reset_env()
  let full_args = ["bit", "-C", repo_root] + args
  bench_stdout_suppress()
  @async.run_async_main(async fn() { run_main_for_args(full_args) })
  bench_stdout_restore()
  1
}

///|
test "bench log oneline -n 10 (shallow)" (b : @bench.T) {
  bench_log_ensure_repo(bench_log_large, 10, 1000)
  bench_log_reset_env()
  b.bench(fn() {
    b.keep(bench_log_run(bench_log_large, ["log", "--oneline", "-n", "10"]))
  })
}

///|
test "bench log oneline -n 50" (b : @bench.T) {
  bench_log_ensure_repo(bench_log_small, 10, 50)
  bench_log_reset_env()
  b.bench(fn() {
    b.keep(bench_log_run(bench_log_small, ["log", "--oneline", "-n", "50"]))
  })
}

///|
test "bench log oneline -n 200" (b : @bench.T) {
  bench_log_ensure_repo(bench_log_medium, 10, 200)
  bench_log_reset_env()
  b.bench(fn() {
    b.keep(bench_log_run(bench_log_medium, ["log", "--oneline", "-n", "200"]))
  })
}

///|
test "bench log oneline -n 1000" (b : @bench.T) {
  bench_log_ensure_repo(bench_log_large, 10, 1000)
  bench_log_reset_env()
  b.bench(fn() {
    b.keep(bench_log_run(bench_log_large, ["log", "--oneline", "-n", "1000"]))
  })
}

///|
test "bench log full -n 50" (b : @bench.T) {
  bench_log_ensure_repo(bench_log_small, 10, 50)
  bench_log_reset_env()
  b.bench(fn() { b.keep(bench_log_run(bench_log_small, ["log", "-n", "50"])) })
}

///|
test "bench log stat -n 50" (b : @bench.T) {
  bench_log_ensure_repo(bench_log_small, 10, 50)
  bench_log_reset_env()
  b.bench(fn() {
    b.keep(bench_log_run(bench_log_small, ["log", "--stat", "-n", "50"]))
  })
}
