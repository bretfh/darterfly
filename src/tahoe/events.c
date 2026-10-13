#include <stdio.h>
#include <ApplicationServices/ApplicationServices.h>

static void dump(const char *name, CGEventRef event) {
  CGEventSetTimestamp(event, 1234567);
  CFDataRef data = CGEventCreateData(NULL, event);
  const UInt8 *b = CFDataGetBytePtr(data);
  printf("%s", name);
  for (CFIndex i = 0; i < CFDataGetLength(data); i++) printf(" %02x", b[i]);
  printf("\n");
  CFRelease(data);
  CFRelease(event);
}

int main(void) {
  CGEventRef e;
  e = CGEventCreateKeyboardEvent(NULL, 0, true);
  UniChar a = 'a';
  CGEventSetIntegerValueField(e, kCGKeyboardEventKeycode, 0);
  CGEventKeyboardSetUnicodeString(e, 1, &a);
  dump("key-down-a", e);
  e = CGEventCreateKeyboardEvent(NULL, 0, false);
  CGEventKeyboardSetUnicodeString(e, 1, &a);
  dump("key-up-a", e);
  e = CGEventCreateKeyboardEvent(NULL, 0x24, true);
  UniChar ret = '\r';
  CGEventKeyboardSetUnicodeString(e, 1, &ret);
  dump("key-down-return", e);
  e = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, CGPointMake(300, 145), kCGMouseButtonLeft);
  dump("mouse-down", e);
  e = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, CGPointMake(10.5, 20.25), kCGMouseButtonLeft);
  dump("mouse-moved", e);
  return 0;
}
