#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    char *p = calloc(128, 1);
    FILE *out;
    if (!p || argc != 2) return 1;
    strcpy(p, "built by isolated TCC\n");
    out = fopen(argv[1], "w");
    if (!out || fwrite(p, 1, strlen(p), out) != strlen(p)) return 2;
    free(p);
    if (fclose(out)) return 3;
    puts("native artifact ran");
    return 23;
}
