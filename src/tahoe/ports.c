#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>
extern mach_port_name_t mach_reply_port(void);
#include <unistd.h>
#include <sys/wait.h>

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

static const struct { const char *name; mach_msg_id_t id; } notifications[] = {
  {"port-deleted", MACH_NOTIFY_PORT_DELETED}, {"send-possible", MACH_NOTIFY_SEND_POSSIBLE},
  {"port-destroyed", MACH_NOTIFY_PORT_DESTROYED}, {"no-senders", MACH_NOTIFY_NO_SENDERS},
  {"send-once", MACH_NOTIFY_SEND_ONCE}, {"dead-name", MACH_NOTIFY_DEAD_NAME},
};

static mach_msg_id_t notification(const char *s) {
  for (int i = 0; i < 6; i++) if (!strcmp(s, notifications[i].name)) return notifications[i].id;
  return 0;
}

static const char *key(mach_port_name_t name) {
  for (int i = nvars - 1; i >= 0; i--) if (vars[i].name == name && strcmp(vars[i].key, "x")) return vars[i].key;
  return "?";
}

static int special(const char *s) {
  if (!strcmp(s, "kernel")) return TASK_KERNEL_PORT;
  if (!strcmp(s, "bootstrap")) return TASK_BOOTSTRAP_PORT;
  return -1;
}

static int compare(const void *a, const void *b) { return strcmp(*(const char **)a, *(const char **)b); }

static mach_port_right_t right(const char *s) {
  for (int i = 0; i < 5; i++) if (!strcmp(s, rights[i].name)) return rights[i].right;
  return MACH_PORT_RIGHT_NUMBER;
}

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
    } else if (!strcmp(w[0], "request")) {
      mach_port_t previous = MACH_PORT_NULL;
      kr = mach_port_request_notification(self, get(w[1]), notification(w[2]), atoi(w[3]), get(w[4]), disposition(w[5]), &previous);
      printf(" %x", kr);
      if (!kr && previous) { *var(w[6]) = previous; printf(" previous"); }
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
      union { mach_msg_header_t header; char bytes[1024]; } m = {0};
      char *at = m.bytes + sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t);
      mach_msg_body_t *body = (mach_msg_body_t *)(m.bytes + sizeof(mach_msg_header_t));
      int count = 0;
      static mach_port_t arrays[8][8];
      for (int i = 6; i < n; count++) {
        if (!strcmp(w[i], "ool")) {
          mach_msg_ool_descriptor_t *d = (mach_msg_ool_descriptor_t *)at;
          int size = atoi(w[i + 1]);
          unsigned char *data = malloc(size);
          for (int j = 0; j < size; j++) data[j] = j * 7;
          d->address = data;
          d->size = size;
          d->deallocate = 0;
          d->copy = MACH_MSG_VIRTUAL_COPY;
          d->type = MACH_MSG_OOL_DESCRIPTOR;
          at += sizeof *d;
          i += 2;
        } else if (!strcmp(w[i], "ports")) {
          mach_msg_ool_ports_descriptor_t *d = (mach_msg_ool_ports_descriptor_t *)at;
          char names[64];
          int k = 0;
          strcpy(names, w[i + 2]);
          for (char *t = strtok(names, "+"); t; t = strtok(NULL, "+")) arrays[count][k++] = get(t);
          d->address = arrays[count];
          d->count = k;
          d->deallocate = 0;
          d->copy = MACH_MSG_PHYSICAL_COPY;
          d->disposition = disposition(w[i + 1]);
          d->type = MACH_MSG_OOL_PORTS_DESCRIPTOR;
          at += sizeof *d;
          i += 3;
        } else {
          mach_msg_port_descriptor_t *d = (mach_msg_port_descriptor_t *)at;
          d->name = get(w[i]);
          d->disposition = disposition(w[i + 1]);
          d->type = MACH_MSG_PORT_DESCRIPTOR;
          at += sizeof *d;
          i += 2;
        }
      }
      body->msgh_descriptor_count = count;
      m.header.msgh_bits = MACH_MSGH_BITS(disposition(w[2]), disposition(w[4])) | (count ? MACH_MSGH_BITS_COMPLEX : 0);
      m.header.msgh_remote_port = get(w[1]);
      m.header.msgh_local_port = get(w[3]);
      m.header.msgh_id = atoi(w[5]);
      m.header.msgh_size = count ? at - m.bytes : sizeof m.header;
      printf(" %x", mach_msg(&m.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, m.header.msgh_size, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL));
    } else if (!strcmp(w[0], "receive")) {
      union { mach_msg_header_t header; char bytes[2048]; } m = {0};
      kr = mach_msg(&m.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, get(w[1]), 0, MACH_PORT_NULL);
      printf(" %x", kr);
      if (!kr) {
        printf(" %d %s %s", m.header.msgh_id,
               disposition_name(MACH_MSGH_BITS_LOCAL(m.header.msgh_bits)),
               disposition_name(MACH_MSGH_BITS_REMOTE(m.header.msgh_bits)));
        uint32_t word = *(uint32_t *)(m.bytes + sizeof m.header + 8);
        if (m.header.msgh_id == MACH_NOTIFY_NO_SENDERS) printf(" %u", word);
        if (m.header.msgh_id == MACH_NOTIFY_DEAD_NAME || m.header.msgh_id == MACH_NOTIFY_PORT_DELETED ||
            m.header.msgh_id == MACH_NOTIFY_SEND_POSSIBLE) printf(" %s", key(word));
        *var(w[2]) = m.header.msgh_remote_port;
        if (m.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) {
          mach_msg_body_t *body = (mach_msg_body_t *)(m.bytes + sizeof m.header);
          char *at = (char *)(body + 1);
          for (unsigned i = 0; i < body->msgh_descriptor_count; i++) {
            mach_msg_type_descriptor_t *t = (mach_msg_type_descriptor_t *)at;
            mach_port_name_t bound = MACH_PORT_NULL;
            if (t->type == MACH_MSG_PORT_DESCRIPTOR) {
              mach_msg_port_descriptor_t *d = (mach_msg_port_descriptor_t *)at;
              printf(" %s", disposition_name(d->disposition));
              bound = d->name;
              at += sizeof *d;
            } else if (t->type == MACH_MSG_OOL_DESCRIPTOR) {
              mach_msg_ool_descriptor_t *d = (mach_msg_ool_descriptor_t *)at;
              unsigned sum = 0;
              for (unsigned j = 0; j < d->size; j++) sum += ((unsigned char *)d->address)[j];
              printf(" ool %u %u", d->size, sum);
              at += sizeof *d;
            } else if (t->type == MACH_MSG_OOL_PORTS_DESCRIPTOR) {
              mach_msg_ool_ports_descriptor_t *d = (mach_msg_ool_ports_descriptor_t *)at;
              printf(" ports %s %u", disposition_name(d->disposition), d->count);
              if (d->count) bound = ((mach_port_name_t *)d->address)[0];
              at += sizeof *d;
            }
            if (3 + (int)i < n) *var(w[3 + i]) = bound;
          }
        }
      }
    } else if (!strcmp(w[0], "self")) {
      *var(w[1]) = mach_task_self();
      printf(" 0");
    } else if (!strcmp(w[0], "thread-self")) {
      *var(w[1]) = mach_thread_self();
      printf(" 0");
    } else if (!strcmp(w[0], "reply-port")) {
      *var(w[1]) = mach_reply_port();
      printf(" 0");
    } else if (!strcmp(w[0], "same")) {
      printf(" 0 %s", get(w[1]) == get(w[2]) ? "yes" : "no");
    } else if (!strcmp(w[0], "special-get")) {
      mach_port_t port;
      kr = task_get_special_port(self, special(w[2]), &port);
      printf(" %x", kr);
      if (!kr) *var(w[1]) = port;
    } else if (!strcmp(w[0], "special-set")) {
      printf(" %x", task_set_special_port(self, special(w[1]), get(w[2])));
    } else if (!strcmp(w[0], "register")) {
      mach_port_t ports[3];
      for (int i = 1; i < n; i++) ports[i - 1] = get(w[i]);
      printf(" %x", mach_ports_register(self, ports, n - 1));
    } else if (!strcmp(w[0], "lookup")) {
      mach_port_array_t ports;
      mach_msg_type_number_t count;
      kr = mach_ports_lookup(self, &ports, &count);
      printf(" %x", kr);
      if (!kr) {
        printf(" %u", count);
        for (unsigned i = 0; i < count && 1 + (int)i < n; i++) *var(w[1 + i]) = ports[i];
      }
    } else if (!strcmp(w[0], "fork")) {
      printf(" 0\n");
      fflush(stdout);
      pid_t pid = fork();
      if (pid) {
        while (fgets(line, sizeof line, in) && strncmp(line, "exit", 4)) {}
        waitpid(pid, NULL, 0);
        self = mach_task_self();
        continue;
      }
      self = mach_task_self();
      continue;
    } else if (!strcmp(w[0], "exit")) {
      printf(" 0\n");
      fflush(stdout);
      _exit(0);
    } else if (!strcmp(w[0], "allocate-name")) {
      kr = mach_port_allocate_name(self, right(w[2]), strtoul(w[3], NULL, 0));
      if (!kr) *var(w[1]) = strtoul(w[3], NULL, 0);
      printf(" %x", kr);
    } else if (!strcmp(w[0], "attributes")) {
      mach_port_status_t st;
      mach_msg_type_number_t cnt = MACH_PORT_RECEIVE_STATUS_COUNT;
      kr = mach_port_get_attributes(self, get(w[1]), MACH_PORT_RECEIVE_STATUS, (mach_port_info_t)&st, &cnt);
      printf(" %x", kr);
      if (!kr) printf(" seqno %u mscount %u qlimit %u msgcount %u sorights %u srights %d pdrequest %d nsrequest %d flags %x",
                      st.mps_seqno, st.mps_mscount, st.mps_qlimit, st.mps_msgcount, st.mps_sorights,
                      st.mps_srights, st.mps_pdrequest, st.mps_nsrequest, st.mps_flags);
    } else if (!strcmp(w[0], "qlimit")) {
      mach_port_limits_t limits = { atoi(w[2]) };
      printf(" %x", mach_port_set_attributes(self, get(w[1]), MACH_PORT_LIMITS_INFO, (mach_port_info_t)&limits, MACH_PORT_LIMITS_INFO_COUNT));
    } else if (!strcmp(w[0], "mscount")) {
      printf(" %x", mach_port_set_mscount(self, get(w[1]), atoi(w[2])));
    } else if (!strcmp(w[0], "seqno")) {
      printf(" %x", mach_port_set_seqno(self, get(w[1]), atoi(w[2])));
    } else if (!strcmp(w[0], "extract")) {
      mach_port_t name;
      mach_msg_type_name_t type;
      kr = mach_port_extract_right(self, get(w[1]), disposition(w[3]), &name, &type);
      printf(" %x", kr);
      if (!kr) { *var(w[2]) = name; printf(" %s", disposition_name(type)); }
    } else if (!strcmp(w[0], "members")) {
      mach_port_name_array_t members;
      mach_msg_type_number_t count;
      kr = mach_port_get_set_status(self, get(w[1]), &members, &count);
      printf(" %x", kr);
      const char *keys[64];
      if (!kr) {
        for (unsigned i = 0; i < count; i++) keys[i] = key(members[i]);
        qsort(keys, count, sizeof keys[0], compare);
        for (unsigned i = 0; i < count; i++) printf(" %s", keys[i]);
      }
    } else if (!strcmp(w[0], "context")) {
      printf(" %x", mach_port_set_context(self, get(w[1]), strtoull(w[2], NULL, 0)));
    } else if (!strcmp(w[0], "get-context")) {
      mach_port_context_t context;
      kr = mach_port_get_context(self, get(w[1]), &context);
      printf(" %x", kr);
      if (!kr) printf(" %llu", (unsigned long long)context);
    } else {
      printf(" ?");
    }
    printf("\n");
  }
  return 0;
}
