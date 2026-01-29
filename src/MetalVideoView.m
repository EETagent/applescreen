// MetalVideoView.m
// Metal-based YUV420P video renderer with aspect ratio preservation

#import "MetalVideoView.h"

@interface MetalVideoView ()
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, strong) id<MTLTexture> yTexture;
@property (nonatomic, strong) id<MTLTexture> uTexture;
@property (nonatomic, strong) id<MTLTexture> vTexture;
@property (nonatomic, strong) id<MTLBuffer> vertexBuffer;
@property (nonatomic, assign) int videoWidth;
@property (nonatomic, assign) int videoHeight;
@property (nonatomic, strong) CAMetalLayer* metalLayer;
@property (nonatomic, assign) BOOL needsVertexUpdate;
@end

@implementation MetalVideoView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setupMetal];
    }
    return self;
}

- (CALayer*)makeBackingLayer {
    CAMetalLayer* layer = [CAMetalLayer layer];
    layer.device = MTLCreateSystemDefaultDevice();
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    self.metalLayer = layer;
    return layer;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)setupMetal {
    self.wantsLayer = YES;
    self.layer = [self makeBackingLayer];

    self.device = self.metalLayer.device;
    self.commandQueue = [self.device newCommandQueue];

    NSError* error = nil;
    NSString* shaderSource = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct VertexOut {\n"
    "    float4 position [[position]];\n"
    "    float2 texCoord;\n"
    "};\n"
    "\n"
    "vertex VertexOut vertexShader(uint vertexID [[vertex_id]],\n"
    "                              constant float4* vertices [[buffer(0)]]) {\n"
    "    VertexOut out;\n"
    "    out.position = float4(vertices[vertexID].xy, 0.0, 1.0);\n"
    "    out.texCoord = vertices[vertexID].zw;\n"
    "    return out;\n"
    "}\n"
    "\n"
    "fragment float4 fragmentShader(VertexOut in [[stage_in]],\n"
    "                               texture2d<float> yTexture [[texture(0)]],\n"
    "                               texture2d<float> uTexture [[texture(1)]],\n"
    "                               texture2d<float> vTexture [[texture(2)]]) {\n"
    "    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);\n"
    "    float y = yTexture.sample(textureSampler, in.texCoord).r;\n"
    "    float u = uTexture.sample(textureSampler, in.texCoord).r - 0.5;\n"
    "    float v = vTexture.sample(textureSampler, in.texCoord).r - 0.5;\n"
    "    \n"
    "    // BT.709 YUV to RGB conversion\n"
    "    float r = y + 1.5748 * v;\n"
    "    float g = y - 0.1873 * u - 0.4681 * v;\n"
    "    float b = y + 1.8556 * u;\n"
    "    \n"
    "    return float4(r, g, b, 1.0);\n"
    "}\n";

    id<MTLLibrary> library = [self.device newLibraryWithSource:shaderSource
                                                       options:nil
                                                         error:&error];
    if (error) {
        NSLog(@"Failed to compile shaders: %@", error);
        return;
    }

    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"vertexShader"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"fragmentShader"];

    MTLRenderPipelineDescriptor* pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    self.pipelineState = [self.device newRenderPipelineStateWithDescriptor:pipelineDescriptor
                                                                     error:&error];
    if (error) {
        NSLog(@"Failed to create pipeline state: %@", error);
        return;
    }

    float vertices[] = {
        // x, y, u, v
        -1.0, -1.0, 0.0, 1.0,
         1.0, -1.0, 1.0, 1.0,
        -1.0,  1.0, 0.0, 0.0,
         1.0,  1.0, 1.0, 0.0,
    };
    self.vertexBuffer = [self.device newBufferWithBytes:vertices
                                                 length:sizeof(vertices)
                                                options:MTLResourceStorageModeShared];
    self.needsVertexUpdate = YES;
}

- (void)updateVertexBufferForAspectRatio {
    if (self.videoWidth <= 0 || self.videoHeight <= 0) {
        return;
    }

    CGSize viewSize = self.bounds.size;
    if (viewSize.width <= 0 || viewSize.height <= 0) {
        return;
    }

    CGFloat videoAspect = (CGFloat)self.videoWidth / (CGFloat)self.videoHeight;
    CGFloat viewAspect = viewSize.width / viewSize.height;

    float scaleX = 1.0f;
    float scaleY = 1.0f;

    if (videoAspect > viewAspect) {
        // Video is wider than view - letterbox (black bars top/bottom)
        scaleY = viewAspect / videoAspect;
    } else {
        // Video is taller than view - pillarbox (black bars left/right)
        scaleX = videoAspect / viewAspect;
    }

    // Update vertex buffer with aspect-corrected coordinates
    float vertices[] = {
        // x, y, u, v
        -scaleX, -scaleY, 0.0, 1.0,
         scaleX, -scaleY, 1.0, 1.0,
        -scaleX,  scaleY, 0.0, 0.0,
         scaleX,  scaleY, 1.0, 0.0,
    };

    memcpy(self.vertexBuffer.contents, vertices, sizeof(vertices));
    self.needsVertexUpdate = NO;
}

- (void)updateTexturesWithYPlane:(const uint8_t*)yPlane
                       yLineSize:(int)yLineSize
                          uPlane:(const uint8_t*)uPlane
                       uLineSize:(int)uLineSize
                          vPlane:(const uint8_t*)vPlane
                       vLineSize:(int)vLineSize
                           width:(int)width
                          height:(int)height {

    // Create or recreate textures if size changed
    if (self.videoWidth != width || self.videoHeight != height) {
        self.videoWidth = width;
        self.videoHeight = height;
        self.needsVertexUpdate = YES;  // Trigger aspect ratio recalculation

        MTLTextureDescriptor* yDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                                         width:width
                                                                                        height:height
                                                                                     mipmapped:NO];
        yDesc.usage = MTLTextureUsageShaderRead;
        self.yTexture = [self.device newTextureWithDescriptor:yDesc];

        MTLTextureDescriptor* uvDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                                          width:width/2
                                                                                         height:height/2
                                                                                      mipmapped:NO];
        uvDesc.usage = MTLTextureUsageShaderRead;
        self.uTexture = [self.device newTextureWithDescriptor:uvDesc];
        self.vTexture = [self.device newTextureWithDescriptor:uvDesc];
    }

    // Upload texture data
    MTLRegion yRegion = MTLRegionMake2D(0, 0, width, height);
    [self.yTexture replaceRegion:yRegion mipmapLevel:0 withBytes:yPlane bytesPerRow:yLineSize];

    MTLRegion uvRegion = MTLRegionMake2D(0, 0, width/2, height/2);
    [self.uTexture replaceRegion:uvRegion mipmapLevel:0 withBytes:uPlane bytesPerRow:uLineSize];
    [self.vTexture replaceRegion:uvRegion mipmapLevel:0 withBytes:vPlane bytesPerRow:vLineSize];
}

- (void)render {
    if (!self.yTexture || !self.uTexture || !self.vTexture) {
        return;
    }

    // Update vertex buffer if needed (video size or view size changed)
    if (self.needsVertexUpdate) {
        [self updateVertexBufferForAspectRatio];
    }

    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable) return;

    MTLRenderPassDescriptor* passDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    passDescriptor.colorAttachments[0].texture = drawable.texture;
    passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];

    [encoder setRenderPipelineState:self.pipelineState];
    [encoder setVertexBuffer:self.vertexBuffer offset:0 atIndex:0];
    [encoder setFragmentTexture:self.yTexture atIndex:0];
    [encoder setFragmentTexture:self.uTexture atIndex:1];
    [encoder setFragmentTexture:self.vTexture atIndex:2];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];

    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    CGFloat scale = self.window.backingScaleFactor ?: 1.0;
    self.metalLayer.drawableSize = CGSizeMake(newSize.width * scale, newSize.height * scale);
    self.needsVertexUpdate = YES;  // Trigger aspect ratio recalculation on resize
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        self.needsVertexUpdate = YES;
    }
}

@end
