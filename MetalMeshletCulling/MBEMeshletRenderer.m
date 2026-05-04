
#import "MBEMeshletRenderer.h"

static const NSUInteger kInstanceGridExtent = 20;
static const NSUInteger kInstanceCount = kInstanceGridExtent * kInstanceGridExtent * kInstanceGridExtent;
static const float kInstanceSpacing = 1.5f;
static const float kHiZDepthBias = 0.001f;

simd_float4x4 simd_float4x4_translation(float tx, float ty, float tz)
{
    return simd_matrix((simd_float4){ 1, 0, 0, 0 },
                       (simd_float4){ 0, 1, 0, 0 },
                       (simd_float4){ 0, 0, 1, 0},
                       (simd_float4){ tx, ty, tz, 1 });
}

simd_float4x4 simd_float4x4_perspective_rh(float fovyRadians, float aspect, float nearZ, float farZ)
{
    float ys = 1 / tanf(fovyRadians * 0.5);
    float xs = ys / aspect;
    float zs = farZ / (nearZ - farZ);

    return simd_matrix((simd_float4){ xs, 0, 0, 0 },
                       (simd_float4){ 0, ys, 0, 0 },
                       (simd_float4){ 0, 0, zs, -1 },
                       (simd_float4){ 0, 0, nearZ * zs, 0 });
}

simd_float4x4 simd_float4x4_rotation_axis_angle(float axisX, float axisY, float axisZ, float angle) {
    simd_float3 unitAxis = simd_normalize((simd_float3){ axisX, axisY, axisZ });
    float ct = cosf(angle);
    float st = sinf(angle);
    float ci = 1 - ct;
    float x = unitAxis.x, y = unitAxis.y, z = unitAxis.z;
    return simd_matrix((simd_float4){     ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0 },
                       (simd_float4){ x * y * ci - z * st,     ct + y * y * ci, z * y * ci + x * st, 0 },
                       (simd_float4){ x * z * ci + y * st, y * z * ci - x * st,     ct + z * z * ci, 0 },
                       (simd_float4){                   0,                   0,                   0, 1 });
}

simd_float4x4 simd_float4x4_look_at_rh(simd_float3 eye, simd_float3 target, simd_float3 up)
{
    simd_float3 forward = simd_normalize(target - eye);
    simd_float3 right = simd_normalize(simd_cross(forward, up));
    simd_float3 cameraUp = simd_cross(right, forward);

    return simd_matrix((simd_float4){ right.x, cameraUp.x, -forward.x, 0 },
                       (simd_float4){ right.y, cameraUp.y, -forward.y, 0 },
                       (simd_float4){ right.z, cameraUp.z, -forward.z, 0 },
                       (simd_float4){ -simd_dot(right, eye), -simd_dot(cameraUp, eye), simd_dot(forward, eye), 1 });
}

typedef struct InstanceData {
    simd_float4x4 modelViewProjectionMatrix;
    simd_float4x4 modelViewMatrix;
    simd_float4x4 inverseModelViewMatrix;
    simd_float4x4 normalMatrix;
} InstanceData;

typedef struct MBEFrustum {
    simd_float4 planes[6];
} MBEFrustum;

typedef struct MeshData {
    uint32_t meshletCount;
    uint32_t hasHiZ;
    uint32_t hiZWidth;
    uint32_t hiZHeight;
    uint32_t hiZMipCount;
    float hiZDepthBias;
} MeshData;

typedef struct VSPSCullingData {
    uint32_t instanceCount;
    uint32_t hasHiZ;
    uint32_t hiZWidth;
    uint32_t hiZHeight;
    uint32_t hiZMipCount;
    uint32_t drawCount;
    float hiZDepthBias;
    uint32_t pad;
    simd_float4 bounds;
} VSPSCullingData;

static MTLVertexDescriptor *MBEMakeRenderVertexDescriptor(void) {
    MTLVertexDescriptor *vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
    vertexDescriptor.attributes[0].format = MTLVertexFormatFloat3;
    vertexDescriptor.attributes[0].offset = 0;
    vertexDescriptor.attributes[0].bufferIndex = 0;

    vertexDescriptor.attributes[1].format = MTLVertexFormatFloat3;
    vertexDescriptor.attributes[1].offset = sizeof(float) * 3;
    vertexDescriptor.attributes[1].bufferIndex = 0;

    vertexDescriptor.attributes[2].format = MTLVertexFormatFloat2;
    vertexDescriptor.attributes[2].offset = sizeof(float) * 6;
    vertexDescriptor.attributes[2].bufferIndex = 0;

    vertexDescriptor.layouts[0].stride = sizeof(float) * 8;

    return vertexDescriptor;
}

NSString *MBERenderPathDisplayName(MBERenderPath renderPath) {
    switch (renderPath) {
        case MBERenderPathIndexedVSPS:
            return @"Indexed";
        case MBERenderPathVertexPullingVSPS:
            return @"Pulling";
        case MBERenderPathMeshlet:
            return @"Meshlet";
    }
}

NSString *MBEMeshletCullingModeDisplayName(MBEMeshletCullingMode cullingMode) {
    switch (cullingMode) {
        case MBEMeshletCullingModeNone:
            return @"No Cull";
        case MBEMeshletCullingModeFrustum:
            return @"Frustum";
        case MBEMeshletCullingModeFull:
            return @"Full";
        case MBEMeshletCullingModeFullHiZ:
            return @"Full+HiZ";
    }
}

NSString *MBEVSPSCullingModeDisplayName(MBEVSPSCullingMode cullingMode) {
    switch (cullingMode) {
        case MBEVSPSCullingModeNone:
            return @"No Cull";
        case MBEVSPSCullingModeCPUFrustum:
            return @"CPU Frustum";
        case MBEVSPSCullingModeGPUFrustum:
            return @"GPU Frustum";
        case MBEVSPSCullingModeGPUHiZ:
            return @"GPU HiZ";
    }
}

static simd_float4 MBERow(simd_float4x4 matrix, int row) {
    return (simd_float4){
        matrix.columns[0][row],
        matrix.columns[1][row],
        matrix.columns[2][row],
        matrix.columns[3][row]
    };
}

static simd_float4 MBENormalizePlane(simd_float4 plane) {
    return plane / simd_length((simd_float3){ plane.x, plane.y, plane.z });
}

static MBEFrustum MBEMakeFrustum(simd_float4x4 matrix) {
    simd_float4 row0 = MBERow(matrix, 0);
    simd_float4 row1 = MBERow(matrix, 1);
    simd_float4 row2 = MBERow(matrix, 2);
    simd_float4 row3 = MBERow(matrix, 3);

    MBEFrustum frustum;
    frustum.planes[0] = MBENormalizePlane(row3 + row0);
    frustum.planes[1] = MBENormalizePlane(row3 - row0);
    frustum.planes[2] = MBENormalizePlane(row3 - row1);
    frustum.planes[3] = MBENormalizePlane(row3 + row1);
    frustum.planes[4] = MBENormalizePlane(row2);
    frustum.planes[5] = MBENormalizePlane(row3 - row2);
    return frustum;
}

static BOOL MBESphereIntersectsFrustum(MBEFrustum frustum, simd_float3 center, float radius) {
    for (NSUInteger i = 0; i < 6; ++i) {
        simd_float4 plane = frustum.planes[i];
        simd_float3 normal = (simd_float3){ plane.x, plane.y, plane.z };
        if (simd_dot(center, normal) + plane.w < -radius) {
            return NO;
        }
    }
    return YES;
}

@interface MBEMeshletRenderer ()
@property (nonatomic, strong) id<MTLDepthStencilState> depthStencilState;
@property (nonatomic, strong) id<MTLBuffer> instanceBuffer;
@property (nonatomic, strong) id<MTLBuffer> visibleInstanceBuffer;
@property (nonatomic, strong) id<MTLBuffer> gpuVisibleInstanceBuffer;
@property (nonatomic, strong) id<MTLBuffer> indexedIndirectBuffer;
@property (nonatomic, strong) id<MTLBuffer> pullingIndirectBuffer;
@property (nonatomic, strong) id<MTLComputePipelineState> hiZCopyDepthPipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> hiZDownsamplePipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> resetIndexedIndirectPipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> resetPullingIndirectPipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> indexedInstanceCullingPipeline;
@property (nonatomic, strong) id<MTLComputePipelineState> pullingInstanceCullingPipeline;
@property (nonatomic, strong) NSArray<id<MTLTexture>> *hiZTextures;
@property (nonatomic, strong) NSArray<NSArray<id<MTLTexture>> *> *hiZMipViews;
@property (nonatomic, strong) id<MTLTexture> hiZFallbackTexture;
@property (nonatomic, assign) NSUInteger hiZReadTextureIndex;
@property (nonatomic, assign) NSUInteger hiZWidth;
@property (nonatomic, assign) NSUInteger hiZHeight;
@property (nonatomic, assign) NSUInteger hiZMipCount;
@property (nonatomic, assign) BOOL hiZValid;
@property (nonatomic, assign, readwrite) NSUInteger cpuVisibleInstanceCount;

- (id<MTLFunction>)newObjectFunctionWithLibrary:(id<MTLLibrary>)library
                                    cullingMode:(MBEMeshletCullingMode)cullingMode
                                          error:(NSError **)error;
- (id<MTLComputePipelineState>)newComputePipelineWithLibrary:(id<MTLLibrary>)library
                                                functionName:(NSString *)functionName
                                                       label:(NSString *)label;
- (void)makeHiZPipelinesWithLibrary:(id<MTLLibrary>)library;
- (void)makeVSPSCullingPipelinesWithLibrary:(id<MTLLibrary>)library;
- (void)ensureHiZTexturesForWidth:(NSUInteger)width height:(NSUInteger)height;
- (BOOL)usesVSPSGPUCulling;
@end

@implementation MBEMeshletRenderer

- (instancetype)initWithDevice:(id<MTLDevice>)device commandQueue:(id<MTLCommandQueue>)commandQueue view:(MTKView *)view {
    if (self = [super init]) {
        _device = device;
        _commandQueue = commandQueue;
        _viewport = (MTLViewport){ 0.0, 0.0, view.drawableSize.width, view.drawableSize.height, 0.0, 1.0 };
        _renderPath = MBERenderPathMeshlet;
        _meshletCullingMode = MBEMeshletCullingModeFull;
        _vspsCullingMode = MBEVSPSCullingModeCPUFrustum;
        view.depthStencilPixelFormat = MTLPixelFormatDepth32Float;

        [self makeRenderPipelinesWithView:view];
        _instanceBuffer = [self.device newBufferWithLength:sizeof(InstanceData) * kInstanceCount
                                                   options:MTLResourceStorageModeShared];
        _instanceBuffer.label = @"Instance Data";
        _visibleInstanceBuffer = [self.device newBufferWithLength:sizeof(InstanceData) * kInstanceCount
                                                          options:MTLResourceStorageModeShared];
        _visibleInstanceBuffer.label = @"VS/PS Visible Instance Data";
        _gpuVisibleInstanceBuffer = [self.device newBufferWithLength:sizeof(InstanceData) * kInstanceCount
                                                             options:MTLResourceStorageModePrivate];
        _gpuVisibleInstanceBuffer.label = @"VS/PS GPU Visible Instance Data";
        _indexedIndirectBuffer = [self.device newBufferWithLength:sizeof(MTLDrawIndexedPrimitivesIndirectArguments)
                                                          options:MTLResourceStorageModePrivate];
        _indexedIndirectBuffer.label = @"Indexed VS/PS Indirect Arguments";
        _pullingIndirectBuffer = [self.device newBufferWithLength:sizeof(MTLDrawPrimitivesIndirectArguments)
                                                          options:MTLResourceStorageModePrivate];
        _pullingIndirectBuffer.label = @"Vertex Pulling VS/PS Indirect Arguments";
        _cpuVisibleInstanceCount = kInstanceCount;
        _hiZReadTextureIndex = 0;
    }
    return self;
}

- (NSUInteger)totalInstanceCount {
    return kInstanceCount;
}

- (BOOL)usesVSPSGPUCulling {
    return (self.renderPath == MBERenderPathIndexedVSPS || self.renderPath == MBERenderPathVertexPullingVSPS) &&
        (self.vspsCullingMode == MBEVSPSCullingModeGPUFrustum || self.vspsCullingMode == MBEVSPSCullingModeGPUHiZ);
}

- (BOOL)requiresHiZGeneration {
    if (self.renderPath == MBERenderPathMeshlet) {
        return self.meshletCullingMode == MBEMeshletCullingModeFullHiZ;
    }
    return self.vspsCullingMode == MBEVSPSCullingModeGPUHiZ;
}

- (void)makeRenderPipelinesWithView:(MTKView *)view {
    id<MTLLibrary> library = [self.device newDefaultLibrary];

    id<MTLFunction> meshFunction = [library newFunctionWithName:@"mesh_main"];
    id<MTLFunction> meshFragmentFunction = [library newFunctionWithName:@"meshlet_fragment_main"];
    id<MTLFunction> indexedVertexFunction = [library newFunctionWithName:@"indexed_vertex_main"];
    id<MTLFunction> vertexPullingFunction = [library newFunctionWithName:@"vertex_pulling_vertex_main"];
    id<MTLFunction> rasterFragmentFunction = [library newFunctionWithName:@"raster_fragment_main"];

    NSError *error = nil;
    MTLPipelineOption options = MTLPipelineOptionNone;
    NSMutableArray<id<MTLRenderPipelineState>> *meshRenderPipelines = [NSMutableArray arrayWithCapacity:4];
    for (NSInteger mode = MBEMeshletCullingModeNone; mode <= MBEMeshletCullingModeFullHiZ; ++mode) {
        error = nil;
        MBEMeshletCullingMode cullingMode = (MBEMeshletCullingMode)mode;
        id<MTLFunction> objectFunction = [self newObjectFunctionWithLibrary:library
                                                                cullingMode:cullingMode
                                                                      error:&error];
        if (objectFunction == nil) {
            NSLog(@"Failed to specialize object shader for %@: %@", MBEMeshletCullingModeDisplayName(cullingMode), error);
            continue;
        }

        MTLMeshRenderPipelineDescriptor *pipelineDescriptor = [MTLMeshRenderPipelineDescriptor new];
        pipelineDescriptor.label = [NSString stringWithFormat:@"Meshlet %@", MBEMeshletCullingModeDisplayName(cullingMode)];
        pipelineDescriptor.objectFunction = objectFunction;
        pipelineDescriptor.meshFunction = meshFunction;
        pipelineDescriptor.fragmentFunction = meshFragmentFunction;
        pipelineDescriptor.rasterSampleCount = view.sampleCount;
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat;
        pipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat;

        id<MTLRenderPipelineState> pipeline = [self.device newRenderPipelineStateWithMeshDescriptor:pipelineDescriptor
                                                                                            options:options
                                                                                         reflection:nil
                                                                                              error:&error];
        if (pipeline == nil) {
            NSLog(@"Failed to create meshlet %@ pipeline: %@", MBEMeshletCullingModeDisplayName(cullingMode), error);
            continue;
        }

        [meshRenderPipelines addObject:pipeline];
    }
    self.meshRenderPipelines = meshRenderPipelines;
    [self makeHiZPipelinesWithLibrary:library];
    [self makeVSPSCullingPipelinesWithLibrary:library];

    MTLRenderPipelineDescriptor *indexedDescriptor = [MTLRenderPipelineDescriptor new];
    indexedDescriptor.vertexFunction = indexedVertexFunction;
    indexedDescriptor.fragmentFunction = rasterFragmentFunction;
    indexedDescriptor.vertexDescriptor = MBEMakeRenderVertexDescriptor();
    indexedDescriptor.rasterSampleCount = view.sampleCount;
    indexedDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    indexedDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat;

    error = nil;
    self.indexedRenderPipeline = [self.device newRenderPipelineStateWithDescriptor:indexedDescriptor error:&error];
    if (self.indexedRenderPipeline == nil) {
        NSLog(@"Failed to create indexed VS/PS pipeline: %@", error);
    }

    MTLRenderPipelineDescriptor *vertexPullingDescriptor = [MTLRenderPipelineDescriptor new];
    vertexPullingDescriptor.vertexFunction = vertexPullingFunction;
    vertexPullingDescriptor.fragmentFunction = rasterFragmentFunction;
    vertexPullingDescriptor.rasterSampleCount = view.sampleCount;
    vertexPullingDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    vertexPullingDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat;

    error = nil;
    self.vertexPullingRenderPipeline = [self.device newRenderPipelineStateWithDescriptor:vertexPullingDescriptor error:&error];
    if (self.vertexPullingRenderPipeline == nil) {
        NSLog(@"Failed to create vertex pulling VS/PS pipeline: %@", error);
    }

    MTLDepthStencilDescriptor *depthDescriptor = [MTLDepthStencilDescriptor new];
    depthDescriptor.depthCompareFunction = MTLCompareFunctionLess;
    depthDescriptor.depthWriteEnabled = YES;
    self.depthStencilState = [self.device newDepthStencilStateWithDescriptor:depthDescriptor];
}

- (id<MTLComputePipelineState>)newComputePipelineWithLibrary:(id<MTLLibrary>)library
                                                functionName:(NSString *)functionName
                                                       label:(NSString *)label {
    NSError *error = nil;
    id<MTLFunction> function = [library newFunctionWithName:functionName];
    if (function == nil) {
        NSLog(@"Failed to find %@ compute function", label);
        return nil;
    }

    id<MTLComputePipelineState> pipeline = [self.device newComputePipelineStateWithFunction:function error:&error];
    if (pipeline == nil) {
        NSLog(@"Failed to create %@ compute pipeline: %@", label, error);
    }
    return pipeline;
}

- (id<MTLFunction>)newObjectFunctionWithLibrary:(id<MTLLibrary>)library
                                    cullingMode:(MBEMeshletCullingMode)cullingMode
                                          error:(NSError **)error {
    bool useFrustumCulling = cullingMode != MBEMeshletCullingModeNone;
    bool useConeCulling = cullingMode == MBEMeshletCullingModeFull || cullingMode == MBEMeshletCullingModeFullHiZ;
    bool useHiZCulling = cullingMode == MBEMeshletCullingModeFullHiZ;

    MTLFunctionConstantValues *constantValues = [MTLFunctionConstantValues new];
    [constantValues setConstantValue:&useFrustumCulling type:MTLDataTypeBool atIndex:0];
    [constantValues setConstantValue:&useConeCulling type:MTLDataTypeBool atIndex:1];
    [constantValues setConstantValue:&useHiZCulling type:MTLDataTypeBool atIndex:2];

    return [library newFunctionWithName:@"object_main" constantValues:constantValues error:error];
}

- (void)makeHiZPipelinesWithLibrary:(id<MTLLibrary>)library {
    self.hiZCopyDepthPipeline = [self newComputePipelineWithLibrary:library
                                                       functionName:@"hiz_copy_depth"
                                                              label:@"Hi-Z copy-depth"];
    self.hiZDownsamplePipeline = [self newComputePipelineWithLibrary:library
                                                        functionName:@"hiz_downsample_max"
                                                               label:@"Hi-Z downsample"];

    MTLTextureDescriptor *fallbackDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                                  width:1
                                                                                                 height:1
                                                                                              mipmapped:NO];
    fallbackDescriptor.usage = MTLTextureUsageShaderRead;
    fallbackDescriptor.storageMode = MTLStorageModeShared;
    self.hiZFallbackTexture = [self.device newTextureWithDescriptor:fallbackDescriptor];
    float fallbackDepth = 1.0f;
    [self.hiZFallbackTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                               mipmapLevel:0
                                 withBytes:&fallbackDepth
                               bytesPerRow:sizeof(float)];
    self.hiZFallbackTexture.label = @"Hi-Z Fallback Texture";
}

- (void)makeVSPSCullingPipelinesWithLibrary:(id<MTLLibrary>)library {
    self.resetIndexedIndirectPipeline = [self newComputePipelineWithLibrary:library
                                                               functionName:@"reset_indexed_indirect_args"
                                                                      label:@"Reset indexed indirect args"];
    self.resetPullingIndirectPipeline = [self newComputePipelineWithLibrary:library
                                                               functionName:@"reset_pulling_indirect_args"
                                                                      label:@"Reset pulling indirect args"];
    self.indexedInstanceCullingPipeline = [self newComputePipelineWithLibrary:library
                                                                 functionName:@"vsps_cull_instances_indexed"
                                                                        label:@"Indexed VS/PS instance culling"];
    self.pullingInstanceCullingPipeline = [self newComputePipelineWithLibrary:library
                                                                 functionName:@"vsps_cull_instances_pulling"
                                                                        label:@"Pulling VS/PS instance culling"];
}

- (void)prepareFrame {
    if (self.mesh == nil) {
        return;
    }

    [self updateInstanceBuffer];
}

- (void)encodePreRenderCommandsWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer {
    if (![self usesVSPSGPUCulling] || commandBuffer == nil || self.mesh == nil || self.mesh.indexCount == 0) {
        return;
    }

    id<MTLComputePipelineState> resetPipeline = nil;
    id<MTLComputePipelineState> cullingPipeline = nil;
    id<MTLBuffer> indirectBuffer = nil;
    if (self.renderPath == MBERenderPathIndexedVSPS) {
        resetPipeline = self.resetIndexedIndirectPipeline;
        cullingPipeline = self.indexedInstanceCullingPipeline;
        indirectBuffer = self.indexedIndirectBuffer;
    } else if (self.renderPath == MBERenderPathVertexPullingVSPS) {
        resetPipeline = self.resetPullingIndirectPipeline;
        cullingPipeline = self.pullingInstanceCullingPipeline;
        indirectBuffer = self.pullingIndirectBuffer;
    }

    if (resetPipeline == nil || cullingPipeline == nil || indirectBuffer == nil || self.gpuVisibleInstanceBuffer == nil) {
        return;
    }

    VSPSCullingData cullingData = {
        .instanceCount = (uint32_t)kInstanceCount,
        .hasHiZ = (uint32_t)(self.vspsCullingMode == MBEVSPSCullingModeGPUHiZ && self.hiZValid),
        .hiZWidth = (uint32_t)self.hiZWidth,
        .hiZHeight = (uint32_t)self.hiZHeight,
        .hiZMipCount = (uint32_t)self.hiZMipCount,
        .drawCount = (uint32_t)self.mesh.indexCount,
        .hiZDepthBias = kHiZDepthBias,
        .pad = 0,
        .bounds = (simd_float4){ self.mesh.boundsCenter.x, self.mesh.boundsCenter.y, self.mesh.boundsCenter.z, self.mesh.boundsRadius },
    };

    id<MTLTexture> hiZTexture = self.hiZValid ? self.hiZTextures[self.hiZReadTextureIndex] : self.hiZFallbackTexture;
    id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
    computeEncoder.label = @"VS/PS GPU Instance Culling";

    [computeEncoder setComputePipelineState:resetPipeline];
    [computeEncoder setBuffer:indirectBuffer offset:0 atIndex:0];
    [computeEncoder setBytes:&cullingData length:sizeof(cullingData) atIndex:1];
    [computeEncoder dispatchThreads:MTLSizeMake(1, 1, 1)
               threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];

    [computeEncoder memoryBarrierWithScope:MTLBarrierScopeBuffers];

    [computeEncoder setComputePipelineState:cullingPipeline];
    [computeEncoder setBuffer:self.instanceBuffer offset:0 atIndex:0];
    [computeEncoder setBuffer:self.gpuVisibleInstanceBuffer offset:0 atIndex:1];
    [computeEncoder setBuffer:indirectBuffer offset:0 atIndex:2];
    [computeEncoder setBytes:&cullingData length:sizeof(cullingData) atIndex:3];
    [computeEncoder setTexture:hiZTexture atIndex:0];

    MTLSize threadsPerThreadgroup = MTLSizeMake(128, 1, 1);
    [computeEncoder dispatchThreads:MTLSizeMake(kInstanceCount, 1, 1)
               threadsPerThreadgroup:threadsPerThreadgroup];
    [computeEncoder endEncoding];
}

- (void)draw:(id<MTLRenderCommandEncoder>)renderCommandEncoder {
    if (self.mesh == nil) {
        return;
    }

    [renderCommandEncoder setDepthStencilState:self.depthStencilState];
    [renderCommandEncoder setViewport:self.viewport];
    [renderCommandEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
    [renderCommandEncoder setCullMode:MTLCullModeBack];

    switch (self.renderPath) {
        case MBERenderPathIndexedVSPS:
            [self drawIndexedWithRenderCommandEncoder:renderCommandEncoder];
            break;
        case MBERenderPathVertexPullingVSPS:
            [self drawVertexPullingWithRenderCommandEncoder:renderCommandEncoder];
            break;
        case MBERenderPathMeshlet:
            [self drawMeshletsWithRenderCommandEncoder:renderCommandEncoder];
            break;
    }
}

- (void)updateInstanceBuffer {
    float aspect = self.viewport.height > 0.0 ? self.viewport.width / self.viewport.height : 1.0f;
    simd_float4x4 viewMatrix = simd_float4x4_look_at_rh((simd_float3){ 0.0f, 4.0f, -4.0f },
                                                        (simd_float3){ 0.0f, 0.0f, -15.5f },
                                                        (simd_float3){ 0.0f, 1.0f, 0.0f });
    simd_float4x4 projectionMatrix = simd_float4x4_perspective_rh(65.0f * (M_PI / 180.0f), aspect, 0.1f, 200.0f);
    simd_float4x4 viewProjectionMatrix = simd_mul(projectionMatrix, viewMatrix);
    BOOL vspsMode = self.renderPath == MBERenderPathIndexedVSPS || self.renderPath == MBERenderPathVertexPullingVSPS;
    BOOL usesCPUCulling = vspsMode && self.vspsCullingMode == MBEVSPSCullingModeCPUFrustum;
    BOOL meshletMode = self.renderPath == MBERenderPathMeshlet;
    MBEFrustum worldFrustum = usesCPUCulling ? MBEMakeFrustum(viewProjectionMatrix) : (MBEFrustum){ 0 };
    simd_float4x4 viewNormalMatrix = simd_inverse(simd_transpose(viewMatrix));

    InstanceData *instances = (InstanceData *)self.instanceBuffer.contents;
    InstanceData *visibleInstances = (InstanceData *)self.visibleInstanceBuffer.contents;
    NSUInteger instanceIndex = 0;
    NSUInteger visibleInstanceCount = 0;
    float gridCenter = ((float)kInstanceGridExtent - 1.0f) * 0.5f;
    for (NSUInteger iz = 0; iz < kInstanceGridExtent; ++iz) {
        for (NSUInteger iy = 0; iy < kInstanceGridExtent; ++iy) {
            for (NSUInteger ix = 0; ix < kInstanceGridExtent; ++ix) {
                float x = ((float)ix - gridCenter) * kInstanceSpacing;
                float y = ((float)iy - gridCenter) * kInstanceSpacing;
                float z = -((float)iz + 3.0f) * kInstanceSpacing;

                BOOL cpuVisible = YES;
                if (usesCPUCulling) {
                    simd_float3 worldBoundsCenter = self.mesh.boundsCenter + (simd_float3){ x, y, z };
                    if (!MBESphereIntersectsFrustum(worldFrustum, worldBoundsCenter, self.mesh.boundsRadius)) {
                        cpuVisible = NO;
                    }
                }

                simd_float4x4 modelMatrix = simd_float4x4_translation(x, y, z);
                simd_float4x4 modelViewMatrix = simd_mul(viewMatrix, modelMatrix);
                simd_float4x4 modelViewProjectionMatrix = simd_mul(viewProjectionMatrix, modelMatrix);
                InstanceData instance = (InstanceData){
                    .modelViewProjectionMatrix = modelViewProjectionMatrix,
                    .modelViewMatrix = modelViewMatrix,
                    .inverseModelViewMatrix = meshletMode ? simd_inverse(modelViewMatrix) : viewMatrix,
                    .normalMatrix = meshletMode ? simd_inverse(simd_transpose(modelViewMatrix)) : viewNormalMatrix,
                };

                instances[instanceIndex] = instance;
                if (usesCPUCulling && cpuVisible) {
                    visibleInstances[visibleInstanceCount++] = instance;
                }
                instanceIndex += 1;
            }
        }
    }

    self.cpuVisibleInstanceCount = usesCPUCulling ? visibleInstanceCount : kInstanceCount;
}

- (void)drawIndexedWithRenderCommandEncoder:(id<MTLRenderCommandEncoder>)renderCommandEncoder {
    BOOL usesGPUCulling = [self usesVSPSGPUCulling];
    NSUInteger instanceCount = self.vspsCullingMode == MBEVSPSCullingModeCPUFrustum ? self.cpuVisibleInstanceCount : kInstanceCount;
    if (self.mesh.indexBuffer == nil || self.mesh.indexCount == 0 || (!usesGPUCulling && instanceCount == 0)) {
        return;
    }

    MBEMeshBuffer *vertexBuffer = self.mesh.vertexBuffers.firstObject;
    id<MTLBuffer> instanceBuffer = usesGPUCulling ? self.gpuVisibleInstanceBuffer :
        (self.vspsCullingMode == MBEVSPSCullingModeCPUFrustum ? self.visibleInstanceBuffer : self.instanceBuffer);

    [renderCommandEncoder setRenderPipelineState:self.indexedRenderPipeline];
    [renderCommandEncoder setVertexBuffer:vertexBuffer.buffer offset:vertexBuffer.offset atIndex:0];
    [renderCommandEncoder setVertexBuffer:instanceBuffer offset:0 atIndex:1];
    if (usesGPUCulling) {
        [renderCommandEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                          indexType:self.mesh.indexType
                                        indexBuffer:self.mesh.indexBuffer.buffer
                                  indexBufferOffset:self.mesh.indexBuffer.offset
                                     indirectBuffer:self.indexedIndirectBuffer
                               indirectBufferOffset:0];
    } else {
        [renderCommandEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                         indexCount:self.mesh.indexCount
                                          indexType:self.mesh.indexType
                                        indexBuffer:self.mesh.indexBuffer.buffer
                                  indexBufferOffset:self.mesh.indexBuffer.offset
                                      instanceCount:instanceCount];
    }
}

- (void)drawVertexPullingWithRenderCommandEncoder:(id<MTLRenderCommandEncoder>)renderCommandEncoder {
    BOOL usesGPUCulling = [self usesVSPSGPUCulling];
    NSUInteger instanceCount = self.vspsCullingMode == MBEVSPSCullingModeCPUFrustum ? self.cpuVisibleInstanceCount : kInstanceCount;
    if (self.mesh.indexBuffer == nil || self.mesh.indexCount == 0 || (!usesGPUCulling && instanceCount == 0)) {
        return;
    }

    MBEMeshBuffer *vertexBuffer = self.mesh.vertexBuffers.firstObject;
    id<MTLBuffer> instanceBuffer = usesGPUCulling ? self.gpuVisibleInstanceBuffer :
        (self.vspsCullingMode == MBEVSPSCullingModeCPUFrustum ? self.visibleInstanceBuffer : self.instanceBuffer);

    [renderCommandEncoder setRenderPipelineState:self.vertexPullingRenderPipeline];
    [renderCommandEncoder setVertexBuffer:vertexBuffer.buffer offset:vertexBuffer.offset atIndex:0];
    [renderCommandEncoder setVertexBuffer:self.mesh.indexBuffer.buffer offset:self.mesh.indexBuffer.offset atIndex:1];
    [renderCommandEncoder setVertexBuffer:instanceBuffer offset:0 atIndex:2];
    if (usesGPUCulling) {
        [renderCommandEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                              indirectBuffer:self.pullingIndirectBuffer
                        indirectBufferOffset:0];
    } else {
        [renderCommandEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                                 vertexStart:0
                                 vertexCount:self.mesh.indexCount
                               instanceCount:instanceCount];
    }
}

- (void)drawMeshletsWithRenderCommandEncoder:(id<MTLRenderCommandEncoder>)renderCommandEncoder {
    if (self.meshRenderPipelines.count == 0 || self.mesh.meshletCount == 0 || self.mesh.meshletVertexBuffer == nil) {
        return;
    }

    NSInteger selectedMode = self.meshletCullingMode;
    selectedMode = MIN(MAX(selectedMode, MBEMeshletCullingModeNone), MBEMeshletCullingModeFullHiZ);
    NSUInteger pipelineIndex = (NSUInteger)selectedMode;
    if (pipelineIndex >= self.meshRenderPipelines.count) {
        return;
    }

    [renderCommandEncoder setRenderPipelineState:self.meshRenderPipelines[pipelineIndex]];

    // We produce one vertex and/or one triangle per mesh thread, so calculate
    // the max number of threads we need to launch per mesh threadgroup.
    const size_t maxMeshThreads = MAX(self.mesh.meshletMaxVertexCount, self.mesh.meshletMaxTriangleCount);

    MBEMeshBuffer *vertexBuffer = self.mesh.vertexBuffers.firstObject;
    [renderCommandEncoder setMeshBuffer:vertexBuffer.buffer offset:vertexBuffer.offset atIndex:0];

    [renderCommandEncoder setMeshBuffer:self.mesh.meshletVertexBuffer.buffer
                                 offset:self.mesh.meshletVertexBuffer.offset
                                atIndex:2];
    [renderCommandEncoder setObjectBuffer:self.instanceBuffer offset:0 atIndex:1];
    [renderCommandEncoder setMeshBuffer:self.instanceBuffer offset:0 atIndex:4];
    id<MTLTexture> hiZTexture = self.hiZValid ? self.hiZTextures[self.hiZReadTextureIndex] : self.hiZFallbackTexture;
    [renderCommandEncoder setObjectTexture:hiZTexture atIndex:0];

    for (MBESubmesh *submesh in self.mesh.submeshes) {
        [renderCommandEncoder setObjectBuffer:submesh.meshletBuffer.buffer
                                       offset:submesh.meshletBuffer.offset
                                      atIndex:0];
        MeshData meshData = {
            .meshletCount = (uint32_t)submesh.meshletCount,
            .hasHiZ = (uint32_t)(selectedMode == MBEMeshletCullingModeFullHiZ && self.hiZValid),
            .hiZWidth = (uint32_t)self.hiZWidth,
            .hiZHeight = (uint32_t)self.hiZHeight,
            .hiZMipCount = (uint32_t)self.hiZMipCount,
            .hiZDepthBias = kHiZDepthBias,
        };
        [renderCommandEncoder setObjectBytes:&meshData length:sizeof(meshData) atIndex:2];

        [renderCommandEncoder setMeshBuffer:submesh.meshletBuffer.buffer
                                     offset:submesh.meshletBuffer.offset
                                    atIndex:1];
        [renderCommandEncoder setMeshBuffer:submesh.meshletTriangleBuffer.buffer
                                     offset:submesh.meshletTriangleBuffer.offset
                                    atIndex:3];

        // TODO: Set fragment resources (material data, etc.)

        NSInteger threadsPerObjectGrid = submesh.meshletCount;
        NSInteger threadsPerObjectThreadgroup = 32;
        NSInteger threadgroupsPerObject = (threadsPerObjectGrid + threadsPerObjectThreadgroup - 1) / threadsPerObjectThreadgroup;
        NSInteger threadsPerMeshThreadgroup = maxMeshThreads;
        [renderCommandEncoder drawMeshThreadgroups:MTLSizeMake(threadgroupsPerObject, kInstanceCount, 1)
                       threadsPerObjectThreadgroup:MTLSizeMake(threadsPerObjectThreadgroup, 1, 1)
                         threadsPerMeshThreadgroup:MTLSizeMake(threadsPerMeshThreadgroup, 1, 1)];
    }
}

- (void)ensureHiZTexturesForWidth:(NSUInteger)width height:(NSUInteger)height {
    if (width == 0 || height == 0) {
        [self invalidateHiZ];
        return;
    }

    if (self.hiZTextures.count == 2 && self.hiZWidth == width && self.hiZHeight == height) {
        return;
    }

    NSUInteger maxDimension = MAX(width, height);
    NSUInteger mipCount = 1;
    while (maxDimension > 1) {
        maxDimension /= 2;
        mipCount += 1;
    }

    NSMutableArray<id<MTLTexture>> *textures = [NSMutableArray arrayWithCapacity:2];
    NSMutableArray<NSArray<id<MTLTexture>> *> *allMipViews = [NSMutableArray arrayWithCapacity:2];
    for (NSUInteger textureIndex = 0; textureIndex < 2; ++textureIndex) {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                              width:width
                                                                                             height:height
                                                                                          mipmapped:YES];
        descriptor.mipmapLevelCount = mipCount;
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;

        id<MTLTexture> texture = [self.device newTextureWithDescriptor:descriptor];
        texture.label = [NSString stringWithFormat:@"Hi-Z Pyramid %lu", (unsigned long)textureIndex];
        [textures addObject:texture];

        NSMutableArray<id<MTLTexture>> *mipViews = [NSMutableArray arrayWithCapacity:mipCount];
        for (NSUInteger mip = 0; mip < mipCount; ++mip) {
            id<MTLTexture> mipView = [texture newTextureViewWithPixelFormat:MTLPixelFormatR32Float
                                                                textureType:MTLTextureType2D
                                                                     levels:NSMakeRange(mip, 1)
                                                                     slices:NSMakeRange(0, 1)];
            mipView.label = [NSString stringWithFormat:@"Hi-Z Pyramid %lu Mip %lu", (unsigned long)textureIndex, (unsigned long)mip];
            [mipViews addObject:mipView];
        }
        [allMipViews addObject:mipViews];
    }

    self.hiZTextures = textures;
    self.hiZMipViews = allMipViews;
    self.hiZWidth = width;
    self.hiZHeight = height;
    self.hiZMipCount = mipCount;
    self.hiZReadTextureIndex = 0;
    self.hiZValid = NO;
    NSLog(@"Recreated Hi-Z textures: %lux%lu, %lu mips",
          (unsigned long)width,
          (unsigned long)height,
          (unsigned long)mipCount);
}

- (void)encodeHiZGenerationWithCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                depthTexture:(id<MTLTexture>)depthTexture {
    if (commandBuffer == nil || depthTexture == nil || self.hiZCopyDepthPipeline == nil || self.hiZDownsamplePipeline == nil) {
        return;
    }

    [self ensureHiZTexturesForWidth:depthTexture.width height:depthTexture.height];
    if (self.hiZTextures.count != 2 || self.hiZMipViews.count != 2 || self.hiZMipCount == 0) {
        return;
    }

    NSUInteger writeTextureIndex = self.hiZValid ? 1 - self.hiZReadTextureIndex : 0;
    NSArray<id<MTLTexture>> *mipViews = self.hiZMipViews[writeTextureIndex];
    id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
    computeEncoder.label = @"Build Hi-Z Pyramid";

    [computeEncoder setComputePipelineState:self.hiZCopyDepthPipeline];
    [computeEncoder setTexture:depthTexture atIndex:0];
    [computeEncoder setTexture:mipViews[0] atIndex:1];
    MTLSize threadsPerThreadgroup = MTLSizeMake(8, 8, 1);
    MTLSize mip0Threads = MTLSizeMake(depthTexture.width, depthTexture.height, 1);
    [computeEncoder dispatchThreads:mip0Threads threadsPerThreadgroup:threadsPerThreadgroup];

    for (NSUInteger mip = 1; mip < self.hiZMipCount; ++mip) {
        id<MTLTexture> dstMip = mipViews[mip];
        [computeEncoder memoryBarrierWithScope:MTLBarrierScopeTextures];
        [computeEncoder setComputePipelineState:self.hiZDownsamplePipeline];
        [computeEncoder setTexture:mipViews[mip - 1] atIndex:0];
        [computeEncoder setTexture:dstMip atIndex:1];
        MTLSize mipThreads = MTLSizeMake(dstMip.width, dstMip.height, 1);
        [computeEncoder dispatchThreads:mipThreads threadsPerThreadgroup:threadsPerThreadgroup];
    }

    [computeEncoder endEncoding];

    __weak typeof(self) weakSelf = self;
    [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> completedCommandBuffer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.hiZReadTextureIndex = writeTextureIndex;
            weakSelf.hiZValid = YES;
        });
    }];
}

- (void)invalidateHiZ {
    self.hiZValid = NO;
}

@end
