///| Benchmarks for diff operations

///|
/// Run with:
/// - moon bench -p mizchi/bit/diff --target native -f bench_test.mbt

///|
let bench_diff_root : String = "/bench_diff"

///|
fn setup_diff_repo(
  file_count : Int,
  changed_pct : Int,
) -> (@bit.TestFs, @bit.ObjectId, @bit.ObjectId) raise @bit.GitError {
  let fs = @bit.TestFs::new()
  ignore(try? @bitlib.init_repo(fs, bench_diff_root))
  let git_dir = bench_diff_root + "/.git"
  for i in 0..<file_count {
    fs.write_string(
      bench_diff_root + "/file_\{i}.txt",
      "original content line 1\nline 2\nline 3\nline 4\nline 5\n",
    )
  }
  @bitlib.add_paths(fs, fs, bench_diff_root, ["."])
  let commit1 = @bitlib.commit(
    fs, fs, bench_diff_root, "first commit\n", "Bench <bench@example.com>", 1700000000L,
  )
  let db1 = @bitlib.ObjectDb::load(fs, git_dir)
  let obj1 = db1.get(fs, commit1).unwrap()
  let tree1 = @bit.parse_commit(obj1.data).tree
  let changed_count = file_count * changed_pct / 100
  for i in 0..<changed_count {
    fs.write_string(
      bench_diff_root + "/file_\{i}.txt",
      "modified content line 1\nline 2\nline 3 changed\nline 4\nline 5 new\n",
    )
  }
  if changed_count > 0 {
    @bitlib.add_paths(fs, fs, bench_diff_root, ["."])
    let commit2 = @bitlib.commit(
      fs, fs, bench_diff_root, "second commit\n", "Bench <bench@example.com>", 1700000001L,
    )
    let db2 = @bitlib.ObjectDb::load(fs, git_dir)
    let obj2 = db2.get(fs, commit2).unwrap()
    let tree2 = @bit.parse_commit(obj2.data).tree
    (fs, tree1, tree2)
  } else {
    (fs, tree1, tree1)
  }
}

///|
let bench_diff_identical : (@bit.TestFs, @bit.ObjectId, @bit.ObjectId) = try! setup_diff_repo(
  100, 0,
)

///|
let bench_diff_10pct : (@bit.TestFs, @bit.ObjectId, @bit.ObjectId) = try! setup_diff_repo(
  100, 10,
)

///|
test "bench diff_trees identical 100 files" (b : @bench.T) {
  let (fs, tree1, _) = bench_diff_identical
  let git_dir = bench_diff_root + "/.git"
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  b.bench(fn() {
    let diffs = try! diff_trees(fs, git_dir, Some(tree1), tree1, db~)
    b.keep(diffs.length())
  })
}

///|
test "bench diff_trees 10pct changed 100 files" (b : @bench.T) {
  let (fs, tree1, tree2) = bench_diff_10pct
  let git_dir = bench_diff_root + "/.git"
  let db = @bitlib.ObjectDb::load(fs, git_dir)
  b.bench(fn() {
    let diffs = try! diff_trees(fs, git_dir, Some(tree1), tree2, db~)
    b.keep(diffs.length())
  })
}

///|
fn setup_diff_text_data() -> Array[DiffFile] {
  let (fs, tree1, tree2) = try! setup_diff_repo(10, 100)
  let git_dir = bench_diff_root + "/.git"
  try! diff_trees(fs, git_dir, Some(tree1), tree2)
}

///|
let bench_diff_files : Array[DiffFile] = setup_diff_text_data()

///|
test "bench diff_text 10 files" (b : @bench.T) {
  b.bench(fn() {
    let lines = diff_text(bench_diff_files)
    b.keep(lines.length())
  })
}

///|
test "bench diff_stat 10 files" (b : @bench.T) {
  b.bench(fn() {
    let lines = diff_stat(bench_diff_files)
    b.keep(lines.length())
  })
}
