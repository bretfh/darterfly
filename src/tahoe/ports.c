#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>

static struct { char key[32]; mach_port_name_t name; } vars[64];
static int nvars;

static mach_port_name_t *var(const char *key) {
  for (int i = 0; i < nvars; i++) if (!strcmp(vars[i].key, key)) return &vars[i].name;
  strcpy(vars[nvars].key, key);
  vars[nvars].name = MACH_PORT_NULL;
  return &vars[nvars++].name;
}

static mach_port_name_t get(const char *key) { return strcmp(key, "none") ? *var(key) : MACH_PORT_NULL; }

static const char *dispositions[] = {"move-receive", "move-send", "move-send-once", "copy-send", "make-send", "make-send-once"};

static int disposition(const char *s) {
  for (int i = 0; i < 6; i++) if (!strcmp(s, dispositions[i])) return MACH_MSG_TYPE_MOVE_RECEIVE + i;
  return 0;
}

static const char *disposition_name(int d) {
  return d >= MACH_MSG_TYPE_MOVE_RECEIVE && d <= MACH_MSG_TYPE_MAKE_SEND_ONCE ? dispositions[d - MACH_MSG_TYPE_MOVE_RECEIVE] : "none";
}

static const struct { const char *name; mach_port_right_t right; mach_port_type_t type; } rights[] = {
  {"receive", MACH_PORT_RIGHT_RECEIVE, MACH_PORT_TYPE_RECEIVE},
  {"send", MACH_PORT_RIGHT_SEND, MACH_PORT_TYPE_SEND},
  {"send-once", MACH_PORT_RIGHT_SEND_ONCE, MACH_PORT_TYPE_SEND_ONCE},
  {"port-set", MACH_PORT_RIGHT_PORT_SET, MACH_PORT_TYPE_PORT_SET},
  {"dead-name", MACH_PORT_RIGHT_DEAD_NAME, MACH_PORT_TYPE_DEAD_NAME},
};

static mach_port_right_t right(const char *s) {
  for (int i = 0; i < 5; i++) if (!strcmp(s, rights[i].name)) return rights[i].right;
  return MACH_PORT_RIGHT_NUMBER;
}

typedef struct {
  mach_msg_header_t header;
  mach_msg_body_t body;
  mach_msg_port_descriptor_t ports[8];
  mach_msg_trailer_t trailer;
} message;

int main(int argc, char **argv) {
  FILE *in = fopen(argv[1], "r");
  char line[256];
  mach_port_t self = mach_task_self();
  while (fgets(line, sizeof line, in)) {
    line[strcspn(line, "\n")] = 0;
    char *w[16];
    int n = 0;
    char copy[256];
    strcpy(copy, line);
    for (char *t = strtok(copy, " "); t && n < 16; t = strtok(NULL, " ")) w[n++] = t;
    if (!n) continue;
    printf("%s |", line);
    kern_return_t kr = KERN_SUCCESS;
    if (!strcmp(w[0], "allocate")) {
      mach_port_name_t name;
      kr = mach_port_allocate(self, right(w[2]), &name);
      if (!kr) *var(w[1]) = name;
      printf(" %x", kr);
    } else if (!strcmp(w[0], "insert")) {
      printf(" %x", mach_port_insert_right(self, get(w[1]), get(w[2]), disposition(w[3])));
    } else if (!strcmp(w[0], "deallocate")) {
      printf(" %x", mach_port_deallocate(self, get(w[1])));
    } else if (!strcmp(w[0], "mod-refs")) {
      printf(" %x", mach_port_mod_refs(self, get(w[1]), right(w[2]), atoi(w[3])));
    } else if (!strcmp(w[0], "destroy")) {
      printf(" %x", mach_port_destroy(self, get(w[1])));
    } else if (!strcmp(w[0], "move-member")) {
      printf(" %x", mach_port_move_member(self, get(w[1]), get(w[2])));
    } else if (!strcmp(w[0], "type")) {
      mach_port_type_t type;
      kr = mach_port_type(self, get(w[1]), &type);
      printf(" %x", kr);
      if (!kr) for (int i = 0; i < 5; i++) if (type & rights[i].type) printf(" %s", rights[i].name);
    } else if (!strcmp(w[0], "refs")) {
      mach_port_urefs_t refs;
      kr = mach_port_get_refs(self, get(w[1]), right(w[2]), &refs);
      printf(" %x", kr);
      if (!kr) printf(" %u", refs);
    } else if (!strcmp(w[0], "send")) {
      message m = {0};
      int carried = (n - 6) / 2;
      m.header.msgh_bits = MACH_MSGH_BITS(disposition(w[2]), disposition(w[4])) | (carried ? MACH_MSGH_BITS_COMPLEX : 0);
      m.header.msgh_remote_port = get(w[1]);
      m.header.msgh_local_port = get(w[3]);
      m.header.msgh_id = atoi(w[5]);
      m.body.msgh_descriptor_count = carried;
      for (int i = 0; i < carried; i++) {
        m.ports[i].name = get(w[6 + 2 * i]);
        m.ports[i].disposition = disposition(w[7 + 2 * i]);
        m.ports[i].type = MACH_MSG_PORT_DESCRIPTOR;
      }
      m.header.msgh_size = carried ? sizeof m.header + sizeof m.body + carried * sizeof m.ports[0] : sizeof m.header;
      printf(" %x", mach_msg(&m.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, m.header.msgh_size, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL));
    } else if (!strcmp(w[0], "receive")) {
      message m = {0};
      kr = mach_msg(&m.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, get(w[1]), 0, MACH_PORT_NULL);
      printf(" %x", kr);
      if (!kr) {
        printf(" %d %s %s", m.header.msgh_id,
               disposition_name(MACH_MSGH_BITS_LOCAL(m.header.msgh_bits)),
               disposition_name(MACH_MSGH_BITS_REMOTE(m.header.msgh_bits)));
        *var(w[2]) = m.header.msgh_remote_port;
        if (m.header.msgh_bits & MACH_MSGH_BITS_COMPLEX)
          for (unsigned i = 0; i < m.body.msgh_descriptor_count; i++) {
            printf(" %s", disposition_name(m.ports[i].disposition));
            if (3 + (int)i < n) *var(w[3 + i]) = m.ports[i].name;
          }
      }
    } else {
      printf(" ?");
    }
    printf("\n");
  }
  return 0;
}
