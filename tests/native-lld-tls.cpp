#include <cstdint>
#include <thread>
#include <cerrno>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
alignas(65536) thread_local int initialized = 29;
alignas(65536) thread_local int zero;
static bool aligned() {
  return !(reinterpret_cast<uintptr_t>(&initialized) & 65535) &&
         !(reinterpret_cast<uintptr_t>(&zero) & 65535);
}
int main() {
  int fd = open("/tmp/lld-mmap-check", O_CREAT | O_TRUNC | O_RDWR, 0600);
  if (fd < 0 || write(fd, "ABCD", 4) != 4) return 93;
  errno = 0;
  if (mmap(nullptr, 4, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) != MAP_FAILED ||
      errno != EOPNOTSUPP) return 94;
  char *p = static_cast<char *>(mmap(nullptr, 4, PROT_READ | PROT_WRITE,
                                    MAP_PRIVATE, fd, 0));
  if (p == MAP_FAILED || p[0] != 'A' || p[3] != 'D') return 95;
  p[0] = 'Z';
  if (munmap(p, 4)) return 96;
  char value = 0;
  if (pread(fd, &value, 1, 0) != 1 || value != 'A') return 97;
  close(fd); unlink("/tmp/lld-mmap-check");
  if (!aligned() || initialized != 29 || zero != 0) return 91;
  initialized = 41; zero = 17;
  bool child = false;
  std::thread worker([&] {
    child = aligned() && initialized == 29 && zero == 0;
    initialized = 7; zero = 9;
  });
  worker.join();
  return child && initialized == 41 && zero == 17 ? 43 : 92;
}
