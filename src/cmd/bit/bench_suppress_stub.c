/* Bench-only: redirect fd 1 to /dev/null to suppress stdout noise */
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>

static int saved_fd = -1;

int bench_suppress_stdout(void) {
  fflush(stdout);
  saved_fd = dup(1);
  int fd = open("/dev/null", O_WRONLY);
  if (fd >= 0) { dup2(fd, 1); close(fd); }
  return saved_fd;
}

int bench_restore_stdout(void) {
  if (saved_fd < 0) return -1;
  fflush(stdout);
  dup2(saved_fd, 1);
  close(saved_fd);
  saved_fd = -1;
  return 0;
}
