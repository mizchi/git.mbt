///| Benchmarks for add, commit, checkout operations

///|
/// Run with:
/// - moon bench -p mizchi/bit/lib --target native -f bench_ops_test.mbt

///|
let bench_ops_root : String = "/bench_ops"

///|
fn setup_add_repo(file_count : Int) -> @bit.TestFs {
  let fs = @bit.TestFs::new()
  ignore(try? init_repo(fs, bench_ops_root))
  for i in 0..<file_count {
    fs.write_string(bench_ops_root + "/file_\{i}.txt", "content \{i}\n")
  }
  fs
}

///|
fn setup_commit_repo(file_count : Int) -> @bit.TestFs raise @bit.GitError {
  let fs = @bit.TestFs::new()
  ignore(try? init_repo(fs, bench_ops_root))
  for i in 0..<file_count {
    fs.write_string(bench_ops_root + "/file_\{i}.txt", "content \{i}\n")
  }
  add_paths(fs, fs, bench_ops_root, ["."])
  fs
}

///|
fn setup_checkout_repo(file_count : Int) -> @bit.TestFs raise @bit.GitError {
  let fs = @bit.TestFs::new()
  ignore(try? init_repo(fs, bench_ops_root))
  for i in 0..<file_count {
    fs.write_string(bench_ops_root + "/file_\{i}.txt", "content \{i}\n")
  }
  add_paths(fs, fs, bench_ops_root, ["."])
  ignore(
    commit(
      fs, fs, bench_ops_root, "initial\n", "Bench <bench@example.com>", 1700000000L,
    ),
  )
  create_branch(fs, fs, bench_ops_root, "other")
  for i in 0..<file_count {
    fs.write_string(bench_ops_root + "/file_\{i}.txt", "changed \{i}\n")
  }
  add_paths(fs, fs, bench_ops_root, ["."])
  ignore(
    commit(
      fs, fs, bench_ops_root, "other branch\n", "Bench <bench@example.com>", 1700000001L,
    ),
  )
  ignore(checkout(fs, fs, bench_ops_root, "main"))
  fs
}

///|
test "bench add_paths 100 files" (b : @bench.T) {
  let fs = setup_add_repo(100)
  b.bench(fn() {
    try! add_paths(fs, fs, bench_ops_root, ["."])
    b.keep(0)
  })
}

///|
test "bench add_paths 500 files" (b : @bench.T) {
  let fs = setup_add_repo(500)
  b.bench(fn() {
    try! add_paths(fs, fs, bench_ops_root, ["."])
    b.keep(0)
  })
}

///|
test "bench commit 100 files" (b : @bench.T) {
  let fs = try! setup_commit_repo(100)
  b.bench(fn() {
    let id = try! commit(
      fs, fs, bench_ops_root, "bench commit\n", "Bench <bench@example.com>", 1700000000L,
    )
    b.keep(id.to_hex().length())
  })
}

///|
test "bench checkout" (b : @bench.T) {
  let fs = try! setup_checkout_repo(100)
  b.bench(fn() {
    let id = try! checkout(fs, fs, bench_ops_root, "other")
    b.keep(id.to_hex().length())
  })
}
