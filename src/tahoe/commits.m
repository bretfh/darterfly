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
    CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    uint8_t small[4 * 2 * 4];
    for (int i = 0; i < 8; i++) {
      small[i * 4 + 0] = i * 30;
      small[i * 4 + 1] = 255 - i * 30;
      small[i * 4 + 2] = i * 10;
      small[i * 4 + 3] = 255;
    }
    CGContextRef bitmap = CGBitmapContextCreate(small, 4, 2, 8, 16, rgb, kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    child.contents = (__bridge id)image;
    [CATransaction commit];
    [CATransaction flush];
    printf("step contents\n");
    fflush(stdout);
    static uint8_t big[128 * 128 * 4];
    for (int i = 0; i < 128 * 128; i++) {
      big[i * 4 + 0] = i & 255;
      big[i * 4 + 1] = (i >> 7) & 255;
      big[i * 4 + 2] = 77;
      big[i * 4 + 3] = 255;
    }
    CGContextRef large = CGBitmapContextCreate(big, 128, 128, 8, 512, rgb, kCGImageAlphaPremultipliedLast);
    CGImageRef largeImage = CGBitmapContextCreateImage(large);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    root.contents = (__bridge id)largeImage;
    [CATransaction commit];
    [CATransaction flush];
    printf("step large\n");
    fflush(stdout);
    [NSThread sleepForTimeInterval:0.5];
  }
  return 0;
}
