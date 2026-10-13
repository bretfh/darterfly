#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

@interface CAContext : NSObject
+ (instancetype)remoteContextWithOptions:(NSDictionary *)options;
@property (retain) CALayer *layer;
@property (readonly) uint32_t contextId;
@end

int main(void) {
  @autoreleasepool {
    CAContext *context = [CAContext remoteContextWithOptions:@{}];
    printf("context %u\n", context.contextId);
    fflush(stdout);
    CALayer *root = [CALayer layer];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    root.bounds = CGRectMake(0, 0, 640, 480);
    root.position = CGPointMake(320, 240);
    context.layer = root;
    [CATransaction commit];
    [CATransaction flush];
    printf("step bare\n");
    fflush(stdout);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    root.opacity = 0.5;
    root.backgroundColor = CGColorCreateSRGB(1, 0, 0, 1);
    CALayer *child = [CALayer layer];
    child.frame = CGRectMake(10, 20, 100, 50);
    child.masksToBounds = YES;
    [root addSublayer:child];
    [CATransaction commit];
    [CATransaction flush];
    printf("step child\n");
    fflush(stdout);
    [NSThread sleepForTimeInterval:0.5];
  }
  return 0;
}
