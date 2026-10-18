#include <stdlib.h>
#include <string.h>
#include <errno.h>

static char *env_storage[64] = {"HOME=/Users/darterfly", "PATH=/bin:/usr/bin", "TERM=dumb", "SBCL_HOME=/usr/lib/sbcl", 0};
char **environ = env_storage;

char *getenv(const char *name) {
  size_t n = strlen(name);
  for (char **e = environ; *e; e++)
    if (!strncmp(*e, name, n) && (*e)[n] == '=') return *e + n + 1;
  return 0;
}

int unsetenv(const char *name) {
  size_t n = strlen(name);
  char **w = environ;
  for (char **e = environ; *e; e++)
    if (strncmp(*e, name, n) || (*e)[n] != '=') *w++ = *e;
  *w = 0;
  return 0;
}

int setenv(const char *name, const char *value, int overwrite) {
  if (getenv(name) && !overwrite) return 0;
  unsetenv(name);
  int i = 0;
  while (environ[i]) i++;
  if (i >= 63) { errno = ENOMEM; return -1; }
  size_t n = strlen(name), v = strlen(value);
  char *s = malloc(n + v + 2);
  memcpy(s, name, n);
  s[n] = '=';
  memcpy(s + n + 1, value, v + 1);
  environ[i] = s;
  environ[i + 1] = 0;
  return 0;
}

int putenv(char *s) {
  char *eq = strchr(s, '=');
  if (!eq) return unsetenv(s);
  char name[256];
  size_t n = (size_t)(eq - s) < sizeof name - 1 ? (size_t)(eq - s) : sizeof name - 1;
  memcpy(name, s, n);
  name[n] = 0;
  return setenv(name, eq + 1, 1);
}
