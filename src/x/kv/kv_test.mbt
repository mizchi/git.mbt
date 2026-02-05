///|
// Test adapter: WorkingTree wrapping @fs.Fs
priv struct TestWorkingTree {
  fs : @fs.Fs
  backing_fs : &@git.RepoFileSystem
  write_fs : &@git.FileSystem
}

///|
impl @lib.WorkingTree for TestWorkingTree with read_file(self, path) {
  self.fs.read_file(self.backing_fs, path)
}

///|
impl @lib.WorkingTree for TestWorkingTree with write_file(self, path, data) {
  self.fs.write_file(path, data)
}

///|
impl @lib.WorkingTree for TestWorkingTree with remove_file(self, path) {
  self.fs.remove_file(path)
}

///|
impl @lib.WorkingTree for TestWorkingTree with is_file(self, path) {
  self.fs.is_file(self.backing_fs, path)
}

///|
impl @lib.WorkingTree for TestWorkingTree with is_dir(self, path) {
  self.fs.is_dir(self.backing_fs, path)
}

///|
impl @lib.WorkingTree for TestWorkingTree with readdir(self, path) {
  self.fs.readdir(self.backing_fs, path)
}

///|
impl @lib.WorkingTree for TestWorkingTree with is_dirty(self) {
  self.fs.is_dirty()
}

///|
impl @lib.WorkingTree for TestWorkingTree with rollback(self) {
  self.fs.rollback()
}

///|
impl @lib.WorkingTree for TestWorkingTree with get_working_files(self) {
  self.fs.get_working_files()
}

///|
impl @lib.WorkingTree for TestWorkingTree with snapshot(self, message, author, timestamp) {
  let snapshot = self.fs.snapshot(self.write_fs, self.backing_fs, message, author, timestamp)
  snapshot.commit_id
}

///|
impl @lib.WorkingTree for TestWorkingTree with checkout(self, commit_id) {
  self.fs.checkout_snapshot(self.backing_fs, commit_id)
}

///|
// Test adapter: ObjectStore that reloads ObjectDb each time
priv struct TestObjectStore {
  backing_fs : &@git.RepoFileSystem
  write_fs : &@git.FileSystem
  git_dir : String
}

///|
impl @lib.ObjectStore for TestObjectStore with get(self, id) {
  let db = @lib.ObjectDb::load(self.backing_fs, self.git_dir)
  db.get(self.backing_fs, id)
}

///|
impl @lib.ObjectStore for TestObjectStore with put(self, obj_type, data) {
  @lib.write_loose_object(self.write_fs, self.git_dir, obj_type, data)
}

///|
impl @lib.ObjectStore for TestObjectStore with has(self, id) {
  let db = @lib.ObjectDb::load(self.backing_fs, self.git_dir) catch {
    _ => return false
  }
  let obj = db.get(self.backing_fs, id) catch { _ => return false }
  obj is Some(_)
}

///|
fn make_test_kv(
  node_id : String,
  git_dir : String,
) -> (Kv, @git.TestFs) raise @git.GitError {
  let fs = @git.TestFs::new()
  @lib.init_repo(fs, "/repo")
  let bitfs = @fs.Fs::empty(git_dir)
  let tree : TestWorkingTree = {
    fs: bitfs,
    backing_fs: fs,
    write_fs: fs,
  }
  let store : TestObjectStore = {
    backing_fs: fs,
    write_fs: fs,
    git_dir,
  }
  let kv = Kv::new(NodeId::new(node_id), tree, store, @git.ObjectId::zero())
  (kv, fs)
}

///|
fn make_test_kv_simple(node_id : String) -> Kv {
  let fs = @git.TestFs::new()
  let bitfs = @fs.Fs::empty("/repo/.git")
  let tree : TestWorkingTree = {
    fs: bitfs,
    backing_fs: fs,
    write_fs: fs,
  }
  let store : TestObjectStore = {
    backing_fs: fs,
    write_fs: fs,
    git_dir: "/repo/.git",
  }
  Kv::new(NodeId::new(node_id), tree, store, @git.ObjectId::zero())
}

///|
/// Tests for Kv
test "VectorClock: increment and merge" {
  let node1 = NodeId::new("node1")
  let node2 = NodeId::new("node2")
  let clock1 = VectorClock::new().increment(node1).increment(node1)
  let clock2 = VectorClock::new().increment(node2)
  // clock1 has node1=2, clock2 has node2=1
  assert_eq(clock1.clocks.get("node1"), Some(2L))
  assert_eq(clock2.clocks.get("node2"), Some(1L))
  // Merge
  let merged = clock1.merge(clock2)
  assert_eq(merged.clocks.get("node1"), Some(2L))
  assert_eq(merged.clocks.get("node2"), Some(1L))
}

///|
test "VectorClock: compare" {
  let node1 = NodeId::new("node1")
  let node2 = NodeId::new("node2")
  // clock1: {node1: 2}
  let clock1 = VectorClock::new().increment(node1).increment(node1)
  // clock2: {node1: 1}
  let clock2 = VectorClock::new().increment(node1)
  // clock1 is after clock2
  assert_eq(clock1.compare(clock2), 1)
  assert_eq(clock2.compare(clock1), -1)
  // Concurrent clocks
  let clock3 = VectorClock::new().increment(node2)
  assert_eq(clock1.compare(clock3), 0) // Concurrent
}

///|
test "normalize_key" {
  // Test internal function via public API
  let db = make_test_kv_simple("test")
  // Leading and trailing slashes should be removed
  db.set("/path/to/key/", b"value")
  // The key should be stored as "path/to/key"
  let files = db.tree.get_working_files()
  assert_true(files.contains("path/to/key"))
}

///|
test "Kv: basic KV operations" {
  let db = make_test_kv_simple("test")
  // Set and get
  db.set("key1", b"value1")
  db.set("nested/path/key2", b"value2")
  let v1 = db.get("key1")
  assert_eq(v1, Some(b"value1"))
  let v2 = db.get("nested/path/key2")
  assert_eq(v2, Some(b"value2"))
  // Non-existent key
  let v3 = db.get("nonexistent")
  assert_eq(v3, None)
  // Delete
  db.delete("key1")
  let v4 = db.get("key1")
  assert_eq(v4, None)
}

///|
test "Kv: list keys" {
  let db = make_test_kv_simple("test")
  db.set("users/alice/name", b"Alice")
  db.set("users/alice/email", b"alice@example.com")
  db.set("users/bob/name", b"Bob")
  db.set("config/version", b"1.0")
  // List users
  let users = db.list("users")
  assert_true(users.contains("alice"))
  assert_true(users.contains("bob"))
  // List alice's keys
  let alice_keys = db.list("users/alice")
  assert_true(alice_keys.contains("name"))
  assert_true(alice_keys.contains("email"))
}

///|
test "Kv: gossip state" {
  let db = make_test_kv_simple("node1")
  let state = db.get_gossip_state(1000L)
  assert_eq(state.node_id.id, "node1")
  assert_eq(state.head, @git.ObjectId::zero())
  assert_eq(state.timestamp, 1000L)
}

///|
test "Kv: peer management" {
  let db = make_test_kv_simple("node1")
  // Add peers
  let peer1 : PeerInfo = {
    node_id: NodeId::new("peer1"),
    last_seen: 1000L,
    head: @git.ObjectId::zero(),
    endpoint: "wss://peer1.example.com",
  }
  let peer2 : PeerInfo = {
    node_id: NodeId::new("peer2"),
    last_seen: 2000L,
    head: @git.ObjectId::zero(),
    endpoint: "wss://peer2.example.com",
  }
  db.add_peer(peer1)
  db.add_peer(peer2)
  let peers = db.get_peers()
  assert_eq(peers.length(), 2)
  // Remove peer
  let removed = db.remove_peer(NodeId::new("peer1"))
  assert_true(removed)
  let peers2 = db.get_peers()
  assert_eq(peers2.length(), 1)
}

///|
test "Kv: select gossip peers" {
  let db = make_test_kv_simple("node1")
  // Add several peers
  for i = 0; i < 10; i = i + 1 {
    let peer : PeerInfo = {
      node_id: NodeId::new("peer" + i.to_string()),
      last_seen: i.to_int64() * 1000L,
      head: @git.ObjectId::zero(),
      endpoint: "wss://peer" + i.to_string() + ".example.com",
    }
    db.add_peer(peer)
  }
  // Select 3 random peers
  let selected = db.select_gossip_peers(3, 12345L)
  assert_eq(selected.length(), 3)
  // Select with different seed should give different result
  let selected2 = db.select_gossip_peers(3, 67890L)
  // At least one should be different (probabilistically)
  let same_count = {
    let mut count = 0
    for p1 in selected {
      for p2 in selected2 {
        if p1.node_id.id == p2.node_id.id {
          count = count + 1
        }
      }
    }
    count
  }
  // Not all should be the same
  assert_true(same_count < 3 || selected.length() < 3)
}

///|
test "Kv: commit and rollback" {
  let (db, _fs) = make_test_kv("test", "/repo/.git")
  // Make some changes
  db.set("key1", b"value1")
  db.set("key2", b"value2")
  assert_true(db.is_dirty())
  // Commit
  let commit_id = db.commit("Initial commit", 1000L)
  assert_false(db.is_dirty())
  assert_true(commit_id != @git.ObjectId::zero())
  // Make more changes
  db.set("key3", b"value3")
  assert_true(db.is_dirty())
  // Rollback
  db.rollback()
  assert_false(db.is_dirty())
  // key3 should not exist
  let v3 = db.get("key3")
  assert_eq(v3, None)
  // key1 and key2 should still exist (from commit)
  let v1 = db.get("key1")
  assert_eq(v1, Some(b"value1"))
}
