///| Benchmarks for cat-file command
///
/// Run with:
/// - moon bench -p mizchi/bit/cmd/bit --target native -f bench_cat_file_wbtest.mbt

///|
let bench_catfile_root : String = "/tmp/bit_bench_catfile_v2"

///|
let bench_catfile_repo : String = bench_catfile_root + "/repo"

///|
let bench_catfile_repeat : Int = 10

///|
let bench_catfile_oids : Ref[Array[String]] = Ref::new([])

///|
fn ensure_catfile_bench_repo() -> Array[String] {
  if bench_catfile_oids.val.length() > 0 {
    return bench_catfile_oids.val
  }
  let marker = bench_catfile_root + "/.bench_ready"
  if not(@fs.path_exists(bench_catfile_root)) {
    @fs.create_dir(bench_catfile_root) catch {
      _ => ()
    }
  }
  if not(@fs.path_exists(bench_catfile_repo)) {
    @fs.create_dir(bench_catfile_repo) catch {
      _ => ()
    }
  }
  if not(@fs.path_exists(marker)) {
    let fs = OsFs::new()
    ignore(try? @bitrepo.init_repo(fs, bench_catfile_repo))
    for i in 0..<50 {
      @fs.write_string_to_file(
        bench_catfile_repo + "/file_\{i}.txt",
        "content \{i}\n",
      ) catch {
        _ => ()
      }
    }
    @async.run_async_main(async fn() {
      ignore(try? @bitlib.add_paths_async(fs, fs, bench_catfile_repo, ["."]))
    })
    ignore(
      try? @bitlib.commit(
        fs, fs, bench_catfile_repo, "bench commit\n", "Bench <bench@example.com>",
        1700000000L,
      ),
    )
    @fs.write_string_to_file(marker, "ok\n") catch {
      _ => ()
    }
  }
  // Read HEAD ref to get commit OID
  let head_content = @fs.read_file_to_string(
    bench_catfile_repo + "/.git/refs/heads/main",
  ) catch {
    _ => ""
  }
  let commit_oid = head_content.trim().to_string()
  // Use rev-parse via run_main to get tree OID
  // For simplicity, just use the commit OID for benchmarks
  bench_catfile_oids.val = [commit_oid]
  bench_catfile_oids.val
}

///|
test "bench cat-file -t commit (×10)" (b : @bench.T) {
  let oids = ensure_catfile_bench_repo()
  let oid = oids[0]
  let args = ["bit", "-C", bench_catfile_repo, "cat-file", "-t", oid]
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  @sys.unset_env_var("GIT_SHIM_CWD")
  b.bench(fn() {
    bench_stdout_suppress()
    for _ in 0..<bench_catfile_repeat {
      @async.run_async_main(async fn() { run_main_for_args(args) })
    }
    bench_stdout_restore()
    b.keep(bench_catfile_repeat)
  })
}

///|
test "bench cat-file -p commit (×10)" (b : @bench.T) {
  let oids = ensure_catfile_bench_repo()
  let oid = oids[0]
  let args = ["bit", "-C", bench_catfile_repo, "cat-file", "-p", oid]
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  @sys.unset_env_var("GIT_SHIM_CWD")
  b.bench(fn() {
    bench_stdout_suppress()
    for _ in 0..<bench_catfile_repeat {
      @async.run_async_main(async fn() { run_main_for_args(args) })
    }
    bench_stdout_restore()
    b.keep(bench_catfile_repeat)
  })
}

///|
test "bench cat-file -s commit (×10)" (b : @bench.T) {
  let oids = ensure_catfile_bench_repo()
  let oid = oids[0]
  let args = ["bit", "-C", bench_catfile_repo, "cat-file", "-s", oid]
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  @sys.unset_env_var("GIT_SHIM_CWD")
  b.bench(fn() {
    bench_stdout_suppress()
    for _ in 0..<bench_catfile_repeat {
      @async.run_async_main(async fn() { run_main_for_args(args) })
    }
    bench_stdout_restore()
    b.keep(bench_catfile_repeat)
  })
}

///|
test "bench cat-file -e commit (×10)" (b : @bench.T) {
  let oids = ensure_catfile_bench_repo()
  let oid = oids[0]
  let args = ["bit", "-C", bench_catfile_repo, "cat-file", "-e", oid]
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  @sys.unset_env_var("GIT_SHIM_CWD")
  b.bench(fn() {
    bench_stdout_suppress()
    for _ in 0..<bench_catfile_repeat {
      @async.run_async_main(async fn() { run_main_for_args(args) })
    }
    bench_stdout_restore()
    b.keep(bench_catfile_repeat)
  })
}
