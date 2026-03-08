///| Benchmarks for worktree_entry (native)

///|
/// Run with:
/// - moon bench -p mizchi/bit/lib --target native

///|
let bench_wt_root_base : String = "/tmp/bit_bench_worktree_entry"

///|
fn bench_wt_join_path(root : String, path : String) -> String {
  if root.length() == 0 || root == "/" {
    if path.has_prefix("/") {
      path
    } else {
      "/" + path
    }
  } else if root.has_suffix("/") {
    root + path
  } else {
    root + "/" + path
  }
}

///|
fn bench_wt_ensure_dir(path : String) -> Unit {
  if not(@fs.path_exists(path)) {
    @fs.create_dir(path) catch {
      _ => ()
    }
  }
}

///|
fn bench_wt_setup(root : String) -> Unit {
  let marker = bench_wt_join_path(root, ".bench_ready")
  if @fs.path_exists(marker) {
    return
  }
  bench_wt_ensure_dir(bench_wt_root_base)
  bench_wt_ensure_dir(root)
  let file_path = bench_wt_join_path(root, "file.txt")
  @fs.write_string_to_file(file_path, "content\n") catch {
    _ => ()
  }
  let link_path = bench_wt_join_path(root, "link.txt")
  if @fs.path_exists(link_path) {
    @fs.remove_file(link_path) catch {
      _ => ()
    }
  }
  @async.run_async_main(async fn() {
    @afs.symlink(target="file.txt", link_path) catch {
      _ => ()
    }
  })
  @fs.write_string_to_file(marker, "ok\n") catch {
    _ => ()
  }
}

///|
let bench_wt_root : String = bench_wt_join_path(bench_wt_root_base, "repo")

///|
let bench_wt_regular : String = bench_wt_join_path(bench_wt_root, "file.txt")

///|
let bench_wt_symlink : String = bench_wt_join_path(bench_wt_root, "link.txt")

///|
let bench_wt_missing : String = bench_wt_join_path(bench_wt_root, "missing.txt")

///|
test "bench worktree_entry regular" (b : @bench.T) {
  bench_wt_setup(bench_wt_root)
  let fs = @osfs.OsFs::new()
  b.bench(fn() {
    @async.run_async_main(async fn() {
      ignore(@bitio.worktree_entry(fs, bench_wt_regular))
    })
    b.keep(1)
  })
}

///|
test "bench worktree_entry symlink" (b : @bench.T) {
  bench_wt_setup(bench_wt_root)
  let fs = @osfs.OsFs::new()
  b.bench(fn() {
    @async.run_async_main(async fn() {
      ignore(@bitio.worktree_entry(fs, bench_wt_symlink))
    })
    b.keep(1)
  })
}

///|
test "bench worktree_entry missing" (b : @bench.T) {
  bench_wt_setup(bench_wt_root)
  let fs = @osfs.OsFs::new()
  b.bench(fn() {
    @async.run_async_main(async fn() {
      ignore(@bitio.worktree_entry(fs, bench_wt_missing))
    })
    b.keep(1)
  })
}
