
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

typedef NS_ENUM(NSInteger, MBEMeshletCullingMode) {
    MBEMeshletCullingModeNone = 0,
    MBEMeshletCullingModeFrustum = 1,
    MBEMeshletCullingModeFull = 2,
    MBEMeshletCullingModeFullHiZ = 3,
};

typedef NS_ENUM(NSInteger, MBEVSPSCullingMode) {
    MBEVSPSCullingModeNone = 0,
    MBEVSPSCullingModeCPUFrustum = 1,
    MBEVSPSCullingModeGPUFrustum = 2,
    MBEVSPSCullingModeGPUHiZ = 3,
};

NSString *MBERenderPathDisplayName(MBERenderPath renderPath);
NSString *MBEMeshletCullingModeDisplayName(MBEMeshletCullingMode cullingMode);
NSString *MBEVSPSCullingModeDisplayName(MBEVSPSCullingMode cullingMode);

@interface MBEMeshletRenderer : NSObject

@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, copy) NSArray<id<MTLRenderPipelineState>> *meshRenderPipelines;
@property (nonatomic, strong) id<MTLRenderPipelineState> indexedRenderPipeline;
@property (nonatomic, strong) id<MTLRenderPipelineState> vertexPullingRenderPipeline;
@property (nonatomic, strong) MBEMesh *mesh;
@property (nonatomic, assign) MTLViewport viewport;
@property (nonatomic, assign) MBERenderPath renderPath;
@property (nonatomic, assign) MBEMeshletCullingMode meshletCullingMode;
@property (nonatomic, assign) MBEVSPSCullingMode vspsCullingMode;
@property (nonatomic, assign, readonly) BOOL requiresHiZGeneration;
@property (nonatomic, assign, readonly) NSUInteger totalInstanceCount;
@property (nonatomic, assign, readonly) NSUInteger cpuVisibleInstanceCount;

- (instancetype)initWithDevice:(id<MTLDevice>)device
                  commandQueue:(id<MTLCommandQueue>)commandQueue
                          view:(MTKView *)view;

- (void)prepareFrame;
- (void)encodePreRenderCommandsWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer;
- (void)draw:(id<MTLRenderCommandEncoder>)renderCommandEncoder;
- (void)encodeHiZGenerationWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                depthTexture:(id<MTLTexture>)depthTexture;
- (void)invalidateHiZ;

@end

NS_ASSUME_NONNULL_END
