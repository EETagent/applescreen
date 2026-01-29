// MetalVideoView.h
// Metal-based YUV420P video renderer with aspect ratio preservation

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

@interface MetalVideoView : NSView

@property (nonatomic, strong, readonly) id<MTLDevice> device;
@property (nonatomic, assign, readonly) int videoWidth;
@property (nonatomic, assign, readonly) int videoHeight;

- (void)updateTexturesWithYPlane:(const uint8_t*)yPlane
                       yLineSize:(int)yLineSize
                          uPlane:(const uint8_t*)uPlane
                       uLineSize:(int)uLineSize
                          vPlane:(const uint8_t*)vPlane
                       vLineSize:(int)vLineSize
                           width:(int)width
                          height:(int)height;

- (void)render;

@end
