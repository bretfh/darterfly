#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static struct { char key[32]; long value; } vars[64];
static int nvars;

static long *var(const char *key) {
  for (int i = 0; i < nvars; i++) if (!strcmp(vars[i].key, key)) return &vars[i].value;
  strcpy(vars[nvars].key, key);
  vars[nvars].value = 0;
  return &vars[nvars++].value;
}

static long get(const char *key) {
  if (!strcmp(key, "any")) return -1;
  if (key[0] >= '0' && key[0] <= '9') return atol(key);
  return *var(key);
}

static const char *key(long value) {
  for (int i = nvars - 1; i >= 0; i--) if (vars[i].value == value) return vars[i].key;
  return "?";
}

static const char *signals[] = {0, "hup", "int", "quit", "ill", "trap", "abrt", "emt", "fpe", "kill", "bus", "segv",
  "sys", "pipe", "alrm", "term", "urg", "stop", "tstp", "cont", "chld", "ttin", "ttou", "io", "xcpu", "xfsz",
  "vtalrm", "prof", "winch", "info", "usr1", "usr2"};

static int signo(const char *s) {
  for (int i = 1; i < 32; i++) if (!strcmp(s, signals[i])) return i;
  return atoi(s);
}

static void caught(int sig) { _exit(100 + sig); }

static void status(int st) {
  if (WIFEXITED(st)) printf(" exited %d", WEXITSTATUS(st));
  else if (WIFSIGNALED(st)) printf(" signaled %s", signals[WTERMSIG(st)]);
  else if (WIFSTOPPED(st)) printf(" stopped %s", signals[WSTOPSIG(st)]);
  else if (WIFCONTINUED(st)) printf(" continued");
}

static int ready = -1;

int main(int argc, char **argv) {
  FILE *in = fopen(argv[1], "r");
  static char lines[1024][256];
  int count = 0, at = 0;
  while (count < 1024 && fgets(lines[count], 256, in)) {
    lines[count][strcspn(lines[count], "\n")] = 0;
    count++;
  }
  setvbuf(stdout, NULL, _IONBF, 0);
  signal(SIGPIPE, SIG_DFL);
  while (at < count) {
    char *line = lines[at++];
    char *w[16];
    int n = 0;
    char copy[256];
    strcpy(copy, line);
    for (char *t = strtok(copy, " "); t && n < 16; t = strtok(NULL, " ")) w[n++] = t;
    if (!n) continue;
    printf("%s |", line);
    long r = 0;
    errno = 0;
    if (!strcmp(w[0], "self")) {
      *var(w[1]) = getpid();
      printf(" 0");
    } else if (!strcmp(w[0], "ppid-is")) {
      printf(" 0 %s", getppid() == get(w[1]) ? "yes" : "no");
    } else if (!strcmp(w[0], "fork")) {
      int sync[2];
      pipe(sync);
      printf(" 0\n");
      pid_t pid = fork();
      if (pid) {
        *var(w[1]) = pid;
        close(sync[1]);
        int depth = 1;
        while (depth && at < count) {
          if (!strncmp(lines[at], "fork", 4)) depth++;
          if (!strncmp(lines[at], "end", 3)) depth--;
          at++;
        }
        char c;
        while (read(sync[0], &c, 1) > 0) {}
        close(sync[0]);
        continue;
      }
      close(sync[0]);
      if (ready >= 0) close(ready);
      ready = sync[1];
      continue;
    } else if (!strcmp(w[0], "exit")) {
      printf(" 0\n");
      _exit(atoi(w[1]));
    } else if (!strcmp(w[0], "hold")) {
      printf(" 0\n");
      close(ready);
      for (;;) pause();
    } else if (!strcmp(w[0], "end")) {
      printf(" 0\n");
      continue;
    } else if (!strcmp(w[0], "wait")) {
      int st;
      int options = WUNTRACED | WCONTINUED | (n > 2 && !strcmp(w[2], "nohang") ? WNOHANG : 0);
      r = waitpid(get(w[1]), &st, options);
      if (r < 0) printf(" %d", errno);
      else if (r == 0) printf(" 0 none");
      else { printf(" 0 %s", key(r)); status(st); }
    } else if (!strcmp(w[0], "kill")) {
      r = kill(get(w[1]), signo(w[2]));
      printf(" %d", r < 0 ? errno : 0);
    } else if (!strcmp(w[0], "signal")) {
      struct sigaction sa = {0};
      sa.sa_handler = !strcmp(w[2], "ignore") ? SIG_IGN : !strcmp(w[2], "default") ? SIG_DFL : caught;
      r = sigaction(signo(w[1]), &sa, NULL);
      printf(" %d", r < 0 ? errno : 0);
    } else if (!strcmp(w[0], "mask") || !strcmp(w[0], "unmask")) {
      sigset_t set;
      sigemptyset(&set);
      sigaddset(&set, signo(w[1]));
      r = sigprocmask(!strcmp(w[0], "mask") ? SIG_BLOCK : SIG_UNBLOCK, &set, NULL);
      printf(" %d", r < 0 ? errno : 0);
    } else if (!strcmp(w[0], "pipe")) {
      int fds[2];
      r = pipe(fds);
      if (r < 0) printf(" %d", errno);
      else { *var(w[1]) = fds[0]; *var(w[2]) = fds[1]; printf(" 0"); }
    } else if (!strcmp(w[0], "write")) {
      r = write(get(w[1]), w[2], strlen(w[2]));
      if (r < 0) printf(" %d", errno); else printf(" 0 %ld", r);
    } else if (!strcmp(w[0], "fill")) {
      static char block[4096];
      long total = 0;
      int fd = get(w[1]);
      int flags = fcntl(fd, F_GETFL);
      fcntl(fd, F_SETFL, flags | O_NONBLOCK);
      while ((r = write(fd, block, sizeof block)) > 0) total += r;
      fcntl(fd, F_SETFL, flags);
      printf(" 0 %ld %d", total, errno);
    } else if (!strcmp(w[0], "read")) {
      char buf[256] = {0};
      r = read(get(w[1]), buf, atoi(w[2]));
      if (r < 0) printf(" %d", errno); else printf(" 0 %ld %s", r, buf);
    } else if (!strcmp(w[0], "drain")) {
      static char block[4096];
      long total = 0;
      int fd = get(w[1]);
      int flags = fcntl(fd, F_GETFL);
      fcntl(fd, F_SETFL, flags | O_NONBLOCK);
      while ((r = read(fd, block, sizeof block)) > 0) total += r;
      fcntl(fd, F_SETFL, flags);
      printf(" 0 %ld %d", total, errno);
    } else if (!strcmp(w[0], "close")) {
      r = close(get(w[1]));
      printf(" %d", r < 0 ? errno : 0);
    } else if (!strcmp(w[0], "dup")) {
      r = dup(get(w[1]));
      if (r < 0) printf(" %d", errno); else { *var(w[2]) = r; printf(" 0"); }
    } else if (!strcmp(w[0], "same")) {
      printf(" 0 %s", get(w[1]) == get(w[2]) ? "yes" : "no");
    } else {
      printf(" ?");
    }
    printf("\n");
  }
  return 0;
}
