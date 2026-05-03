
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#import "MBEMesh.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MBERenderPath) {
    MBERenderPathIndexedVSPS = 0,
    MBERenderPathVertexPullingVSPS = 1,
    MBERenderPathMeshlet = 2,
};

NSString *MBERenderPathDisplayName(MBERenderPath renderPath);

@interface MBEMeshletRenderer : NSObject

@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLRenderPipelineState> meshRenderPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> indexedRenderPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> vertexPullingRenderPipeline;
@property (nonatomic, strong) MBEMesh *mesh;
@property (nonatomic, assign) MTLViewport viewport;
@property (nonatomic, assign) MBERenderPath renderPath;
@property (nonatomic, assign, readonly) NSUInteger totalInstanceCount;
@property (nonatomic, assign, readonly) NSUInteger cpuVisibleInstanceCount;

- (instancetype)initWithDevice:(id<MTLDevice>)device
                  commandQueue:(id<MTLCommandQueue>)commandQueue
                          view:(MTKView *)view;

- (void)draw:(id<MTLRenderCommandEncoder>)renderCommandEncoder;

@end

NS_ASSUME_NONNULL_END
