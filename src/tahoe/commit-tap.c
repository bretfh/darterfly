#include <stdio.h>
#include <stdint.h>
#include <mach/mach.h>

static void hex(const char *tag, const uint8_t *p, size_t n) {
  printf("%s", tag);
  for (size_t i = 0; i < n; i++) printf(" %02x", p[i]);
  printf("\n");
}

static mach_msg_return_t tap(mach_msg_header_t *m, mach_msg_option_t option, mach_msg_size_t send_size,
                             mach_msg_size_t rcv_size, mach_port_name_t rcv_name, mach_msg_timeout_t timeout,
                             mach_port_name_t notify) {
  if ((option & MACH_SEND_MSG) && m->msgh_id >= 40002 && m->msgh_id <= 40005) {
    printf("message %d bits %x size %u\n", m->msgh_id, m->msgh_bits, m->msgh_size);
    hex("bytes", (const uint8_t *)m, m->msgh_size);
    if (m->msgh_bits & MACH_MSGH_BITS_COMPLEX) {
      mach_msg_body_t *body = (mach_msg_body_t *)(m + 1);
      uint8_t *d = (uint8_t *)(body + 1);
      for (mach_msg_size_t i = 0; i < body->msgh_descriptor_count; i++) {
        mach_msg_type_descriptor_t *t = (mach_msg_type_descriptor_t *)d;
        if (t->type == MACH_MSG_OOL_DESCRIPTOR || t->type == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) {
          mach_msg_ool_descriptor_t *o = (mach_msg_ool_descriptor_t *)d;
          hex("ool", o->address, o->size);
          d += sizeof *o;
        } else if (t->type == MACH_MSG_PORT_DESCRIPTOR) {
          printf("port\n");
          d += sizeof(mach_msg_port_descriptor_t);
        } else {
          printf("descriptor %u\n", t->type);
          break;
        }
      }
    }
    fflush(stdout);
  }
  return mach_msg(m, option, send_size, rcv_size, rcv_name, timeout, notify);
}

__attribute__((used, section("__DATA,__interpose")))
static struct { const void *replacement, *replacee; } interpose[] = {{(const void *)tap, (const void *)mach_msg}};
