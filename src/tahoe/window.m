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
    NSMenu *bar = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"probe"];
    [appMenu addItemWithTitle:@"About finch probe" action:nil keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit finch probe" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];
    NSMenuItem *fileItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenu addItemWithTitle:@"New Probe" action:nil keyEquivalent:@"n"];
    [fileMenu addItemWithTitle:@"Open..." action:nil keyEquivalent:@"o"];
    fileItem.submenu = fileMenu;
    [bar addItem:fileItem];
    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Copy" action:nil keyEquivalent:@"c"];
    editItem.submenu = editMenu;
    [bar addItem:editItem];
    NSApp.mainMenu = bar;
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
