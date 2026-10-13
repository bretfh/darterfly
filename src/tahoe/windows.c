#include <stdio.h>
#include <ApplicationServices/ApplicationServices.h>

int main(void) {
  CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
  for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
    CFDictionaryRef w = CFArrayGetValueAtIndex(list, i);
    int number = 0, pid = 0, layer = 0;
    char owner[256] = "";
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowNumber), kCFNumberIntType, &number);
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowOwnerPID), kCFNumberIntType, &pid);
    CFNumberGetValue(CFDictionaryGetValue(w, kCGWindowLayer), kCFNumberIntType, &layer);
    CFStringRef name = CFDictionaryGetValue(w, kCGWindowOwnerName);
    if (name) CFStringGetCString(name, owner, sizeof owner, kCFStringEncodingUTF8);
    printf("%d %d %d %s\n", pid, number, layer, owner);
  }
  return 0;
}
