#include <dirent.h>
#include <stdint.h>
#include <string.h>

/*
 * bit_readdir: list directory entries with d_type (no stat needed).
 *
 * Buffer format per entry:
 *   bytes 0-1:  name_len  (uint16, little-endian)
 *   byte  2:    d_type    (DT_DIR=4, DT_REG=8, DT_LNK=10, DT_UNKNOWN=0)
 *   bytes 3..:  name      (UTF-8, NOT null-terminated)
 *
 * Returns total bytes written on success (>= 0), -1 on failure.
 * Only complete entries are written; partial entries are never included.
 */
int bit_readdir(const char *path, uint8_t *buf, int buf_size) {
  DIR *d = opendir(path);
  if (!d) {
    return -1;
  }

  int pos = 0;
  struct dirent *ent;
  while ((ent = readdir(d)) != NULL) {
    const char *name = ent->d_name;
    /* Skip . and .. */
    if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) {
      continue;
    }
    int name_len = (int)strlen(name);
    int entry_size = 2 + 1 + name_len; /* name_len(2) + d_type(1) + name */
    if (pos + entry_size > buf_size) {
      break;
    }
    /* name_len as uint16 LE */
    buf[pos]     = (uint8_t)(name_len & 0xFF);
    buf[pos + 1] = (uint8_t)((name_len >> 8) & 0xFF);
    /* d_type */
    buf[pos + 2] = ent->d_type;
    /* name bytes */
    memcpy(buf + pos + 3, name, name_len);
    pos += entry_size;
  }

  closedir(d);
  return pos;
}
