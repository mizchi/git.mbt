///| Benchmarks for repack command (pack-objects bottleneck investigation)
///
/// Run with:
/// - moon bench -p mizchi/bit/cmd/bit --target native -f bench_repack_wbtest.mbt

///|
let bench_repack_root : String = "/tmp/bit_bench_repack_v2"

///|
fn bench_repack_ensure_dir(path : String) -> Unit {
  if not(@fs.path_exists(path)) {
    @fs.create_dir(path) catch {
      _ => ()
    }
  }
}

///|
fn bench_repack_create_repo(
  repo_path : String,
  num_commits : Int,
  files_per_commit : Int,
) -> Unit {
  bench_repack_ensure_dir(repo_path)
  let fs = OsFs::new()
  ignore(try? @bitrepo.init_repo(fs, repo_path))
  for commit_idx in 0..<num_commits {
    for file_idx in 0..<files_per_commit {
      let dir = repo_path + "/dir_\{commit_idx}"
      bench_repack_ensure_dir(dir)
      @fs.write_string_to_file(
        repo_path + "/dir_\{commit_idx}/file_\{file_idx}.txt",
        "content \{commit_idx}-\{file_idx} " + "x".repeat(100) + "\n",
      ) catch {
        _ => ()
      }
    }
    @async.run_async_main(async fn() {
      ignore(try? @bitlib.add_paths_async(fs, fs, repo_path, ["."]))
    })
    ignore(
      try? @bitlib.commit(
        fs,
        fs,
        repo_path,
        "commit \{commit_idx}\n",
        "Bench <bench@example.com>",
        1700000000L + commit_idx.to_int64(),
      ),
    )
  }
  @async.run_async_main(async fn() {
    run_main_for_args(["bit", "-C", repo_path, "repack", "-a", "-d"])
  })
}

///|
fn bench_repack_ensure_repos() -> Unit {
  let marker = bench_repack_root + "/.ready"
  bench_repack_ensure_dir(bench_repack_root)
  if @fs.path_exists(marker) {
    return
  }
  // Small: 5 commits × 20 files ≈ 115 objects
  bench_repack_create_repo(bench_repack_root + "/small", 5, 20)
  // Large: 10 commits × 50 files ≈ 560 objects
  bench_repack_create_repo(bench_repack_root + "/large", 10, 50)
  @fs.write_string_to_file(marker, "ok\n") catch {
    _ => ()
  }
}

///|
fn bench_repack_reset_env() -> Unit {
  @sys.unset_env_var("GIT_DIR")
  @sys.unset_env_var("GIT_WORK_TREE")
  @sys.unset_env_var("GIT_SHIM_CWD")
}

///|
test "bench repack small (115 obj)" (b : @bench.T) {
  bench_repack_ensure_repos()
  bench_repack_reset_env()
  let repo = bench_repack_root + "/small"
  let args = ["bit", "-C", repo, "repack", "-a", "-d"]
  b.bench(fn() {
    bench_stdout_suppress()
    @async.run_async_main(async fn() { run_main_for_args(args) })
    bench_stdout_restore()
    b.keep(1)
  })
}

///|
test "bench repack large (560 obj)" (b : @bench.T) {
  bench_repack_ensure_repos()
  bench_repack_reset_env()
  let repo = bench_repack_root + "/large"
  let args = ["bit", "-C", repo, "repack", "-a", "-d"]
  b.bench(fn() {
    bench_stdout_suppress()
    @async.run_async_main(async fn() { run_main_for_args(args) })
    bench_stdout_restore()
    b.keep(1)
  })
}

///|
/// Micro-benchmark: zlib compress + decompress cycle
test "bench zlib round-trip 560×120B" (b : @bench.T) {
  // Simulate typical object sizes in pack
  let objects : Array[Bytes] = []
  for i in 0..<560 {
    let content = "content \{i} " + "x".repeat(100) + "\n"
    let bytes = @encoding.encode(@encoding.Encoding::UTF8, content)
    objects.push(bytes)
  }
  b.bench(fn() {
    for obj in objects {
      let compressed = @zlib.zlib_compress(obj)
      let _ = @zlib.zlib_decompress(compressed) catch { _ => b"" }
      ()
    }
    b.keep(objects.length())
  })
}

///|
/// Micro-benchmark: SHA-1 computation
test "bench sha1 560×120B" (b : @bench.T) {
  let objects : Array[Bytes] = []
  for i in 0..<560 {
    let content = "content \{i} " + "x".repeat(100) + "\n"
    let bytes = @encoding.encode(@encoding.Encoding::UTF8, content)
    objects.push(bytes)
  }
  b.bench(fn() {
    for obj in objects {
      let _ = @bitcore.hash_object_content(@bitcore.ObjectType::Blob, obj)
      ()
    }
    b.keep(objects.length())
  })
}
