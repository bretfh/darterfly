#include <stdio.h>
#include <stdint.h>
#include <mach/mach.h>

extern mach_msg_return_t mach_msg2_internal(void *data, uint64_t option64, uint64_t bits_and_send_size,
                                            uint64_t remote_and_local, uint64_t voucher_and_id,
                                            uint64_t desc_count_and_rcv_name, uint64_t rcv_size_and_priority,
                                            uint64_t timeout);

static void dump(const char *tag, const void *data, uint32_t size) {
  const uint8_t *b = data;
  fprintf(stderr, "%s %u", tag, size);
  for (uint32_t i = 0; i < size && i < 4096; i++) fprintf(stderr, " %02x", b[i]);
  fprintf(stderr, "\n");
}

static void dump_ool(const void *data) {
  const mach_msg_header_t *h = data;
  if (!(h->msgh_bits & MACH_MSGH_BITS_COMPLEX)) return;
  const uint8_t *at = (const uint8_t *)data + sizeof *h;
  uint32_t count = *(const uint32_t *)at;
  at += 4;
  for (uint32_t i = 0; i < count && i < 16; i++) {
    uint8_t type = at[11];
    if (type == MACH_MSG_OOL_DESCRIPTOR || type == MACH_MSG_OOL_VOLATILE_DESCRIPTOR) {
      const void *address = *(void *const *)at;
      uint32_t size = *(const uint32_t *)(at + 12);
      dump("ool", address, size);
      at += 16;
    } else if (type == MACH_MSG_OOL_PORTS_DESCRIPTOR) {
      at += 16;
    } else {
      at += 12;
    }
  }
}

static mach_msg_return_t tap_msg(mach_msg_header_t *msg, mach_msg_option_t option, mach_msg_size_t send_size,
                                 mach_msg_size_t rcv_size, mach_port_name_t rcv_name, mach_msg_timeout_t timeout,
                                 mach_port_name_t notify) {
  if (option & MACH_SEND_MSG) { dump("send", msg, send_size); dump_ool(msg); }
  mach_msg_return_t r = mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, notify);
  if ((option & MACH_RCV_MSG) && r == 0) dump("recv", msg, msg->msgh_size);
  return r;
}

static mach_msg_return_t tap_msg2(void *data, uint64_t option64, uint64_t bits_and_send_size,
                                  uint64_t remote_and_local, uint64_t voucher_and_id,
                                  uint64_t desc_count_and_rcv_name, uint64_t rcv_size_and_priority,
                                  uint64_t timeout) {
  if (option64 & MACH_SEND_MSG) { dump("send2", data, (uint32_t)(bits_and_send_size >> 32)); if (!(option64 & 0x100000000ULL)) dump_ool(data); }
  mach_msg_return_t r = mach_msg2_internal(data, option64, bits_and_send_size, remote_and_local, voucher_and_id,
                                           desc_count_and_rcv_name, rcv_size_and_priority, timeout);
  if ((option64 & MACH_RCV_MSG) && r == 0) dump("recv2", data, ((mach_msg_header_t *)data)->msgh_size);
  return r;
}

__attribute__((used, section("__DATA,__interpose"))) static struct { const void *a, *b; } interposers[] = {
  {(const void *)tap_msg, (const void *)mach_msg},
  {(const void *)tap_msg2, (const void *)mach_msg2_internal},
};
