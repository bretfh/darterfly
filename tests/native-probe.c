/* No host libc: this same source is compiled again by TCC in Darterfly. */
typedef unsigned long word;
extern long native_call(word, const void *, word, void *, word);
extern void _start(void);
static volatile unsigned char zeroes[16385];
static volatile int initialized = 123;
static int equal(const char *a, const char *b) {
    while (*a && *a == *b) { ++a; ++b; }
    return *a == *b;
}
int main(int argc, char **argv, char **envp) {
    word i;
    word *aux;
    if (argc != 3 || argv[3] || !equal(argv[2], "tail") ||
        !envp[0] || !equal(envp[0], "NATIVE=yes") || envp[1]) return 91;
    aux = (word *)(envp + 2);
    if (((word)argv & 15) != 8 || aux[0] != 6 || aux[1] != 4096 ||
        aux[2] || aux[3]) return 97;
    if (argv[1][0] == 'z') return 0;
    if (argv[1][0] == 'i') __asm__ volatile("ud2");
    for (i = 0; i < sizeof zeroes; ++i) if (zeroes[i]) return 92;
    if (initialized != 123) return 93;
    initialized = 456;
    zeroes[16384] = 17;
    if (argv[1][0] == 'f') *(volatile int *)0x1000 = 1;
    if (argv[1][0] == 'x') *(volatile unsigned char *)_start = 0;
    if (argv[1][0] == 'n') {
        unsigned char code[1];
        code[0] = 0xc3;
        ((void (*)(void))code)();
        return 94;
    }
    if (argv[1][0] == 'l') for (;;) __asm__ volatile("pause");
    if (argv[1][0] == 'p') {
        char reply[4];
        if (native_call(1, "ping", 4, reply, sizeof reply) != 4) return 95;
        if (reply[0] != 'p' || reply[1] != 'o' || reply[2] != 'n' ||
            reply[3] != 'g') return 96;
    }
    return 37;
}
