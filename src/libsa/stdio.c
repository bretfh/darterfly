#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>

struct __FILE { int fd, eof, error, unget; };

static FILE files[3] = {{0, 0, 0, -1}, {1, 0, 0, -1}, {2, 0, 0, -1}};
FILE *stdin = &files[0], *stdout = &files[1], *stderr = &files[2];

typedef struct { char *buf; size_t cap, len; int fd; } sink;

static void emit(sink *s, char c) {
  if (s->fd >= 0) {
    write(s->fd, &c, 1);
  } else if (s->len + 1 < s->cap) {
    s->buf[s->len] = c;
  }
  s->len++;
}

static void emit_n(sink *s, const char *p, size_t n) {
  if (s->fd >= 0) {
    write(s->fd, p, n);
    s->len += n;
  } else
    while (n--) emit(s, *p++);
}

static void pad(sink *s, char c, int n) { while (n-- > 0) emit(s, c); }

static int format_unsigned(char *out, unsigned long long v, int base, int upper) {
  const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
  char tmp[64];
  int n = 0;
  do tmp[n++] = digits[v % base]; while (v /= base);
  for (int i = 0; i < n; i++) out[i] = tmp[n - 1 - i];
  return n;
}

static int format_double_masked(char *out, double v, int precision, char conv);

static int format_double(char *out, double v, int precision, char conv) {
  unsigned csr, masked;
  __asm__ volatile("stmxcsr %0" : "=m"(csr));
  masked = csr | 0x1f80;
  __asm__ volatile("ldmxcsr %0" : : "m"(masked));
  int n = format_double_masked(out, v, precision, conv);
  __asm__ volatile("ldmxcsr %0" : : "m"(csr));
  return n;
}

static int format_double_masked(char *out, double v, int precision, char conv) {
  int n = 0;
  if (v != v) return strcpy(out, "nan"), 3;
  if (v < 0 || (v == 0 && 1 / v < 0)) out[n++] = '-', v = -v;
  if (v > 1.7976931348623157e308) return strcpy(out + n, "inf"), n + 3;
  if (precision < 0) precision = 6;
  if (precision > 17) precision = 17;
  int exponent = 0;
  if (conv == 'e' || conv == 'g') {
    if (v != 0) {
      while (v >= 10) v /= 10, exponent++;
      while (v < 1) v *= 10, exponent--;
    }
    if (conv == 'g' && exponent >= -4 && exponent < (precision ? precision : 1)) {
      for (; exponent > 0; exponent--) v *= 10;
      for (; exponent < 0; exponent++) v /= 10;
      conv = 'f';
    } else
      conv = 'e';
  }
  if (conv == 'f' && v >= 1e18) {
    int e = 0;
    double m = v;
    while (m >= 10) m /= 10, e++;
    char digits[32];
    int k = format_unsigned(digits, (unsigned long long)(m * 1e16 + 0.5), 10, 0);
    memcpy(out + n, digits, k);
    n += k;
    for (int i = k - 1; i < e; i++) out[n++] = '0';
    if (precision) {
      out[n++] = '.';
      for (int i = 0; i < precision; i++) out[n++] = '0';
    }
    return n;
  }
  double scale = 1;
  for (int i = 0; i < precision; i++) scale *= 10;
  double rounded = v * scale + 0.5;
  unsigned long long whole = (unsigned long long)(rounded / scale);
  unsigned long long frac = (unsigned long long)(rounded - (double)whole * scale);
  if (conv == 'e' && whole >= 10) whole /= 10, exponent++;
  n += format_unsigned(out + n, whole, 10, 0);
  if (precision) {
    out[n++] = '.';
    char digits[32];
    int k = format_unsigned(digits, frac, 10, 0);
    for (int i = k; i < precision; i++) out[n++] = '0';
    memcpy(out + n, digits, k);
    n += k;
  }
  if (conv == 'e') {
    out[n++] = 'e';
    out[n++] = exponent < 0 ? '-' : '+';
    if (exponent < 0) exponent = -exponent;
    if (exponent < 10) out[n++] = '0';
    n += format_unsigned(out + n, exponent, 10, 0);
  }
  return n;
}

static int vformat(sink *s, const char *f, va_list ap) {
  for (; *f; f++) {
    if (*f != '%') {
      emit(s, *f);
      continue;
    }
    f++;
    int left = 0, plus = 0, space = 0, alt = 0, zero = 0;
    for (;; f++) {
      if (*f == '-') left = 1;
      else if (*f == '+') plus = 1;
      else if (*f == ' ') space = 1;
      else if (*f == '#') alt = 1;
      else if (*f == '0') zero = 1;
      else break;
    }
    int width = 0, precision = -1;
    if (*f == '*') width = va_arg(ap, int), f++;
    else while (*f >= '0' && *f <= '9') width = width * 10 + (*f++ - '0');
    if (width < 0) left = 1, width = -width;
    if (*f == '.') {
      f++;
      precision = 0;
      if (*f == '*') precision = va_arg(ap, int), f++;
      else while (*f >= '0' && *f <= '9') precision = precision * 10 + (*f++ - '0');
    }
    int length = 0;
    for (;; f++) {
      if (*f == 'h') length = length == -1 ? -2 : -1;
      else if (*f == 'l') length++;
      else if (*f == 'z' || *f == 'j' || *f == 't') length = 2;
      else if (*f == 'L') length = 3;
      else break;
    }
    char buf[128];
    const char *body = buf;
    int n = 0;
    char sign = 0;
    const char *prefix = "";
    switch (*f) {
    case 'd':
    case 'i': {
      long long v = length >= 1 ? (length == 1 ? va_arg(ap, long) : va_arg(ap, long long)) : va_arg(ap, int);
      if (length == -1) v = (short)v;
      if (length == -2) v = (signed char)v;
      unsigned long long u = v < 0 ? -(unsigned long long)v : (unsigned long long)v;
      sign = v < 0 ? '-' : plus ? '+' : space ? ' ' : 0;
      n = (precision == 0 && u == 0) ? 0 : format_unsigned(buf, u, 10, 0);
      break;
    }
    case 'u':
    case 'x':
    case 'X':
    case 'o': {
      unsigned long long u = length >= 1 ? (length == 1 ? va_arg(ap, unsigned long) : va_arg(ap, unsigned long long))
                                         : va_arg(ap, unsigned);
      if (length == -1) u = (unsigned short)u;
      if (length == -2) u = (unsigned char)u;
      int base = *f == 'o' ? 8 : *f == 'u' ? 10 : 16;
      n = (precision == 0 && u == 0) ? 0 : format_unsigned(buf, u, base, *f == 'X');
      if (alt && u && base == 16) prefix = *f == 'X' ? "0X" : "0x";
      if (alt && base == 8) prefix = "0";
      break;
    }
    case 'p': {
      uintptr_t u = (uintptr_t)va_arg(ap, void *);
      n = format_unsigned(buf, u, 16, 0);
      prefix = "0x";
      break;
    }
    case 'c':
      buf[0] = (char)va_arg(ap, int);
      n = 1;
      precision = -1;
      break;
    case 's':
      body = va_arg(ap, const char *);
      if (!body) body = "(null)";
      n = (int)(precision >= 0 ? strnlen(body, precision) : strlen(body));
      precision = -1;
      break;
    case 'f':
    case 'F':
    case 'e':
    case 'E':
    case 'g':
    case 'G': {
      double v = length == 3 ? (double)va_arg(ap, long double) : va_arg(ap, double);
      n = format_double(buf, v, precision, *f | 0x20);
      if (buf[0] != '-' && (plus || space)) sign = plus ? '+' : ' ';
      precision = -1;
      break;
    }
    case 'n':
      *va_arg(ap, int *) = (int)s->len;
      continue;
    case '%':
      emit(s, '%');
      continue;
    default:
      emit(s, '%');
      emit(s, *f);
      continue;
    }
    int zeros = precision > n ? precision - n : 0;
    int total = n + zeros + (sign ? 1 : 0) + (int)strlen(prefix);
    if (!left && !(zero && precision < 0)) pad(s, ' ', width - total);
    if (sign) emit(s, sign);
    emit_n(s, prefix, strlen(prefix));
    if (!left && zero && precision < 0) pad(s, '0', width - total);
    pad(s, '0', zeros);
    emit_n(s, body, n);
    if (left) pad(s, ' ', width - total);
  }
  return (int)s->len;
}

int vsnprintf(char *buf, size_t cap, const char *f, va_list ap) {
  sink s = {buf, cap, 0, -1};
  vformat(&s, f, ap);
  if (cap) buf[s.len < cap ? s.len : cap - 1] = 0;
  return (int)s.len;
}

int vsprintf(char *buf, const char *f, va_list ap) { return vsnprintf(buf, (size_t)-1 >> 1, f, ap); }

int snprintf(char *buf, size_t cap, const char *f, ...) {
  va_list ap;
  va_start(ap, f);
  int n = vsnprintf(buf, cap, f, ap);
  va_end(ap);
  return n;
}

int sprintf(char *buf, const char *f, ...) {
  va_list ap;
  va_start(ap, f);
  int n = vsprintf(buf, f, ap);
  va_end(ap);
  return n;
}

int vdprintf(int fd, const char *f, va_list ap) {
  char buf[1024];
  int n = vsnprintf(buf, sizeof buf, f, ap);
  if (n < (int)sizeof buf) return (int)write(fd, buf, n);
  sink s = {0, 0, 0, fd};
  return vformat(&s, f, ap);
}

int dprintf(int fd, const char *f, ...) {
  va_list ap;
  va_start(ap, f);
  int n = vdprintf(fd, f, ap);
  va_end(ap);
  return n;
}

int vfprintf(FILE *fp, const char *f, va_list ap) { return vdprintf(fp->fd, f, ap); }

int fprintf(FILE *fp, const char *f, ...) {
  va_list ap;
  va_start(ap, f);
  int n = vfprintf(fp, f, ap);
  va_end(ap);
  return n;
}

int vprintf(const char *f, va_list ap) { return vfprintf(stdout, f, ap); }

int printf(const char *f, ...) {
  va_list ap;
  va_start(ap, f);
  int n = vfprintf(stdout, f, ap);
  va_end(ap);
  return n;
}

int fputs(const char *str, FILE *fp) { return write(fp->fd, str, strlen(str)) < 0 ? EOF : 0; }

int puts(const char *str) {
  if (fputs(str, stdout) == EOF) return EOF;
  return fputc('\n', stdout);
}

int fputc(int c, FILE *fp) {
  unsigned char b = (unsigned char)c;
  return write(fp->fd, &b, 1) == 1 ? b : EOF;
}

int putc(int c, FILE *fp) { return fputc(c, fp); }
int putchar(int c) { return fputc(c, stdout); }

int fgetc(FILE *fp) {
  if (fp->unget >= 0) {
    int c = fp->unget;
    fp->unget = -1;
    return c;
  }
  unsigned char b;
  ssize_t n = read(fp->fd, &b, 1);
  if (n <= 0) {
    if (n == 0) fp->eof = 1;
    else fp->error = 1;
    return EOF;
  }
  return b;
}

int getc(FILE *fp) { return fgetc(fp); }
int getchar(void) { return fgetc(stdin); }

int ungetc(int c, FILE *fp) {
  if (c == EOF) return EOF;
  fp->unget = (unsigned char)c;
  fp->eof = 0;
  return c;
}

char *fgets(char *buf, int n, FILE *fp) {
  int i = 0;
  while (i < n - 1) {
    int c = fgetc(fp);
    if (c == EOF) break;
    buf[i++] = (char)c;
    if (c == '\n') break;
  }
  if (i == 0) return 0;
  buf[i] = 0;
  return buf;
}

size_t fread(void *buf, size_t size, size_t count, FILE *fp) {
  size_t want = size * count, got = 0;
  while (got < want) {
    ssize_t n = read(fp->fd, (char *)buf + got, want - got);
    if (n <= 0) {
      if (n == 0) fp->eof = 1;
      else fp->error = 1;
      break;
    }
    got += (size_t)n;
  }
  return size ? got / size : 0;
}

size_t fwrite(const void *buf, size_t size, size_t count, FILE *fp) {
  ssize_t n = write(fp->fd, buf, size * count);
  return n < 0 || !size ? 0 : (size_t)n / size;
}

int fflush(FILE *fp) { (void)fp; return 0; }

static int mode_flags(const char *mode) {
  int flags = mode[0] == 'r' ? O_RDONLY : (O_WRONLY | O_CREAT | (mode[0] == 'a' ? O_APPEND : O_TRUNC));
  if (strchr(mode, '+')) flags = (flags & ~(O_RDONLY | O_WRONLY)) | O_RDWR;
  return flags;
}

FILE *fdopen(int fd, const char *mode) {
  (void)mode;
  FILE *fp = malloc(sizeof *fp);
  if (!fp) return 0;
  *fp = (FILE){fd, 0, 0, -1};
  return fp;
}

FILE *fopen(const char *path, const char *mode) {
  int fd = open(path, mode_flags(mode), 0666);
  if (fd < 0) return 0;
  return fdopen(fd, mode);
}

FILE *freopen(const char *path, const char *mode, FILE *fp) {
  int fd = open(path, mode_flags(mode), 0666);
  if (fd < 0) return 0;
  if (fp->fd > 2) close(fp->fd);
  *fp = (FILE){fd, 0, 0, -1};
  return fp;
}

int __libsa_redirect_stdout(const char *path) {
  if (stdout->fd > 2) close(stdout->fd);
  *stdout = (FILE){1, 0, 0, -1};
  if (!path) return 0;
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0666);
  if (fd < 0) return -1;
  stdout->fd = fd;
  return 0;
}

FILE *tmpfile(void) {
  errno = ENOSYS;
  return 0;
}

int fclose(FILE *fp) {
  int r = close(fp->fd);
  if (fp != stdin && fp != stdout && fp != stderr) free(fp);
  return r;
}

int fseeko(FILE *fp, off_t off, int whence) {
  fp->unget = -1;
  fp->eof = 0;
  return lseek(fp->fd, off, whence) < 0 ? -1 : 0;
}

int fseek(FILE *fp, long off, int whence) { return fseeko(fp, off, whence); }
off_t ftello(FILE *fp) { return lseek(fp->fd, 0, SEEK_CUR); }
long ftell(FILE *fp) { return ftello(fp); }
void rewind(FILE *fp) { fseek(fp, 0, SEEK_SET); fp->error = 0; }
int feof(FILE *fp) { return fp->eof; }
int ferror(FILE *fp) { return fp->error; }
void clearerr(FILE *fp) { fp->eof = fp->error = 0; }
int fileno(FILE *fp) { return fp->fd; }
int setvbuf(FILE *fp, char *buf, int mode, size_t size) { (void)fp; (void)buf; (void)mode; (void)size; return 0; }
void setbuf(FILE *fp, char *buf) { (void)fp; (void)buf; }

void perror(const char *s) {
  if (s && *s) fprintf(stderr, "%s: %s\n", s, strerror(errno));
  else fprintf(stderr, "%s\n", strerror(errno));
}


