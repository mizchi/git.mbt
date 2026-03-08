///| Suppress stdout during benchmarks (native-only, test-only)

///|
extern "c" fn bench_suppress_stdout_ffi() -> Int = "bench_suppress_stdout"

///|
extern "c" fn bench_restore_stdout_ffi() -> Int = "bench_restore_stdout"

///|
fn bench_stdout_suppress() -> Unit {
  ignore(bench_suppress_stdout_ffi())
}

///|
fn bench_stdout_restore() -> Unit {
  ignore(bench_restore_stdout_ffi())
}
