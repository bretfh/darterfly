#import <AppKit/AppKit.h>

@interface Probe : NSView
@end

@implementation Probe
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {
  fprintf(stderr, "keyDown %s code %d\n", event.characters.UTF8String, event.keyCode);
  if ([event.characters isEqualToString:@"q"]) [NSApp terminate:nil];
}
- (void)mouseDown:(NSEvent *)event {
  NSPoint p = event.locationInWindow;
  fprintf(stderr, "mouseDown %.0f %.0f\n", p.x, p.y);
}
@end

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 400, 300)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered defer:NO];
    window.title = @"finch probe";
    Probe *probe = [[Probe alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    window.contentView = probe;
    [window makeFirstResponder:probe];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    fprintf(stderr, "window %ld\n", (long)window.windowNumber);
    [NSApp run];
  }
  return 0;
}
