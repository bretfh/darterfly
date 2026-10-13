#include <stdio.h>
#include <string.h>
#include <servers/bootstrap.h>

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    mach_port_t port = MACH_PORT_NULL;
    int checkin = !strncmp(argv[i], "check-in:", 9);
    const char *name = checkin ? argv[i] + 9 : argv[i];
    fprintf(stderr, "%s %s\n", checkin ? "check-in" : "look-up", name);
    kern_return_t kr = checkin ? bootstrap_check_in(bootstrap_port, name, &port)
                               : bootstrap_look_up(bootstrap_port, name, &port);
    fprintf(stderr, "result %s %x %s\n", name, kr, port ? "port" : "none");
  }
  return 0;
}
