#include <stdio.h>
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>
typedef struct { double x, y; } point;
typedef struct { double x, y, w, h; } rect;
extern int SLSMainConnectionID(void);
extern void *SLSTransactionCreate(int);
extern void SLSTransactionOrderWindow(void *, uint32_t, int, uint32_t);
extern void SLSTransactionOrderWindowGroup(void *, uint32_t, int, uint32_t);
extern void SLSTransactionSetWindowLevel(void *, uint32_t, int);
extern void SLSTransactionSetWindowSubLevel(void *, uint32_t, int);
extern void SLSTransactionMoveWindowWithGroup(void *, uint32_t, point);
extern void SLSTransactionSetWindowAlpha(void *, uint32_t, float);
extern void SLSTransactionSetWindowResolution(void *, uint32_t, double);
extern void SLSTransactionAddWindowToSpace(void *, uint32_t, uint64_t);
extern void SLSTransactionSetWindowProperty(void *, uint32_t, CFStringRef, CFTypeRef);
extern void SLSTransactionSetWindowShape(void *, uint32_t, double, double, void *);
extern void SLSTransactionResetWindow(void *, uint32_t);
extern int CGSNewRegionWithRect(const rect *, void **);

static void *fresh(void) { return SLSTransactionCreate(SLSMainConnectionID()); }

static void dump(const char *name, void *t) {
  uint8_t *buf = *(uint8_t **)((char *)t + 0x20);
  uint64_t len = *(uint64_t *)((char *)t + 0x28);
  printf("%s", name);
  for (uint64_t i = 0; i < len; i++) printf(" %02x", buf[i]);
  printf("\n");
}

int main(void) {
  void *t;
  t = fresh(); SLSTransactionOrderWindow(t, 0x3c, 1, 0); dump("order-above", t);
  t = fresh(); SLSTransactionOrderWindow(t, 0x1234, -1, 0x3d); dump("order-below", t);
  t = fresh(); SLSTransactionOrderWindowGroup(t, 0x3c, 0, 0); dump("order-group-out", t);
  t = fresh(); SLSTransactionSetWindowLevel(t, 0x3c, -2147483623); dump("level", t);
  t = fresh(); SLSTransactionSetWindowSubLevel(t, 0x3c, -1); dump("sub-level", t);
  t = fresh(); SLSTransactionMoveWindowWithGroup(t, 0x3c, (point){100, -20}); dump("move", t);
  t = fresh(); SLSTransactionMoveWindowWithGroup(t, 0x3c, (point){10.5, 0.25}); dump("move-fraction", t);
  t = fresh(); SLSTransactionSetWindowAlpha(t, 0x3c, 0.5f); dump("alpha", t);
  t = fresh(); SLSTransactionSetWindowResolution(t, 0x3c, 2.0); dump("resolution", t);
  t = fresh(); SLSTransactionAddWindowToSpace(t, 0x3c, 0x100000001ULL); dump("space", t);
  t = fresh(); SLSTransactionSetWindowProperty(t, 0x3c, CFSTR("finch"), CFSTR("bird")); dump("property", t);
  t = fresh(); SLSTransactionSetWindowProperty(t, 0x3c, CFSTR("on"), kCFBooleanTrue); dump("property-bool", t);
  t = fresh(); SLSTransactionSetWindowProperty(t, 0x3c, CFSTR("gone"), NULL); dump("property-null", t);
  void *r; rect box = {0, 0, 640, 480}; CGSNewRegionWithRect(&box, &r);
  t = fresh(); SLSTransactionSetWindowShape(t, 0x3d, 0, 0, r); dump("shape", t);
  t = fresh(); SLSTransactionResetWindow(t, 0x3c); SLSTransactionOrderWindow(t, 0x3c, 2, 0); dump("two", t);
  return 0;
}
