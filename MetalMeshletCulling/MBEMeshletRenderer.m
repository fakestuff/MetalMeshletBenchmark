
#import "MBEMeshletRenderer.h"

static const NSUInteger kInstanceGridExtent = 20;
static const NSUInteger kInstanceCount = kInstanceGridExtent * kInstanceGridExtent * kInstanceGridExtent;
static const float kInstanceSpacing = 1.5f;

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
    simd_float4x4 inverseModelViewMatrix;
    simd_float4x4 normalMatrix;
} InstanceData;

typedef struct MBEFrustum {
    simd_float4 planes[6];
} MBEFrustum;

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
@property (nonatomic, assign, readwrite) NSUInteger cpuVisibleInstanceCount;
@end

@implementation MBEMeshletRenderer

- (instancetype)initWithDevice:(id<MTLDevice>)device commandQueue:(id<MTLCommandQueue>)commandQueue view:(MTKView *)view {
    if (self = [super init]) {
        _device = device;
        _commandQueue = commandQueue;
        _viewport = (MTLViewport){ 0.0, 0.0, view.drawableSize.width, view.drawableSize.height, 0.0, 1.0 };
        _renderPath = MBERenderPathMeshlet;
        view.depthStencilPixelFormat = MTLPixelFormatDepth32Float;

        [self makeRenderPipelinesWithView:view];
        _instanceBuffer = [self.device newBufferWithLength:sizeof(InstanceData) * kInstanceCount
                                                   options:MTLResourceStorageModeShared];
        _instanceBuffer.label = @"Instance Data";
        _visibleInstanceBuffer = [self.device newBufferWithLength:sizeof(InstanceData) * kInstanceCount
                                                          options:MTLResourceStorageModeShared];
        _visibleInstanceBuffer.label = @"VS/PS Visible Instance Data";
        _cpuVisibleInstanceCount = kInstanceCount;
    }
    return self;
}

- (NSUInteger)totalInstanceCount {
    return kInstanceCount;
}

- (void)makeRenderPipelinesWithView:(MTKView *)view {
    id<MTLLibrary> library = [self.device newDefaultLibrary];

    id<MTLFunction> objectFunction = [library newFunctionWithName:@"object_main"];
    id<MTLFunction> meshFunction = [library newFunctionWithName:@"mesh_main"];
    id<MTLFunction> meshFragmentFunction = [library newFunctionWithName:@"meshlet_fragment_main"];
    id<MTLFunction> indexedVertexFunction = [library newFunctionWithName:@"indexed_vertex_main"];
    id<MTLFunction> vertexPullingFunction = [library newFunctionWithName:@"vertex_pulling_vertex_main"];
    id<MTLFunction> rasterFragmentFunction = [library newFunctionWithName:@"raster_fragment_main"];

    MTLMeshRenderPipelineDescriptor *pipelineDescriptor = [MTLMeshRenderPipelineDescriptor new];

    pipelineDescriptor.objectFunction = objectFunction;
    pipelineDescriptor.meshFunction = meshFunction;
    pipelineDescriptor.fragmentFunction = meshFragmentFunction;

    pipelineDescriptor.rasterSampleCount = view.sampleCount;

    pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat;
    pipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat;

    MTLPipelineOption options = MTLPipelineOptionNone;
    NSError *error = nil;
    self.meshRenderPipeline = [self.device newRenderPipelineStateWithMeshDescriptor:pipelineDescriptor
                                                                            options:options
                                                                         reflection:nil
                                                                              error:&error];
    if (self.meshRenderPipeline == nil) {
        NSLog(@"Failed to create meshlet pipeline: %@", error);
    }

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

- (void)draw:(id<MTLRenderCommandEncoder>)renderCommandEncoder {
    if (self.mesh == nil) {
        return;
    }

    [self updateInstanceBuffer];

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
    BOOL usesCPUCulling = self.renderPath == MBERenderPathIndexedVSPS || self.renderPath == MBERenderPathVertexPullingVSPS;

    InstanceData *instances = (InstanceData *)(usesCPUCulling ? self.visibleInstanceBuffer.contents : self.instanceBuffer.contents);
    NSUInteger instanceIndex = 0;
    NSUInteger visibleInstanceCount = 0;
    float gridCenter = ((float)kInstanceGridExtent - 1.0f) * 0.5f;
    for (NSUInteger iz = 0; iz < kInstanceGridExtent; ++iz) {
        for (NSUInteger iy = 0; iy < kInstanceGridExtent; ++iy) {
            for (NSUInteger ix = 0; ix < kInstanceGridExtent; ++ix) {
                float x = ((float)ix - gridCenter) * kInstanceSpacing;
                float y = ((float)iy - gridCenter) * kInstanceSpacing;
                float z = -((float)iz + 3.0f) * kInstanceSpacing;

                simd_float4x4 modelMatrix = simd_float4x4_translation(x, y, z);
                simd_float4x4 modelViewMatrix = simd_mul(viewMatrix, modelMatrix);
                simd_float4x4 modelViewProjectionMatrix = simd_mul(projectionMatrix, modelViewMatrix);
                InstanceData instance = (InstanceData){
                    .modelViewProjectionMatrix = modelViewProjectionMatrix,
                    .inverseModelViewMatrix = simd_inverse(modelViewMatrix),
                    .normalMatrix = simd_inverse(simd_transpose(modelViewMatrix)),
                };

                if (usesCPUCulling) {
                    MBEFrustum frustum = MBEMakeFrustum(modelViewProjectionMatrix);
                    if (MBESphereIntersectsFrustum(frustum, self.mesh.boundsCenter, self.mesh.boundsRadius)) {
                        instances[visibleInstanceCount++] = instance;
                    }
                } else {
                    instances[instanceIndex] = instance;
                }
                instanceIndex += 1;
            }
        }
    }

    self.cpuVisibleInstanceCount = usesCPUCulling ? visibleInstanceCount : kInstanceCount;
}

- (void)drawIndexedWithRenderCommandEncoder:(id<MTLRenderCommandEncoder>)renderCommandEncoder {
    if (self.mesh.indexBuffer == nil || self.mesh.indexCount == 0 || self.cpuVisibleInstanceCount == 0) {
        return;
    }

    MBEMeshBuffer *vertexBuffer = self.mesh.vertexBuffers.firstObject;

    [renderCommandEncoder setRenderPipelineState:self.indexedRenderPipeline];
    [renderCommandEncoder setVertexBuffer:vertexBuffer.buffer offset:vertexBuffer.offset atIndex:0];
    [renderCommandEncoder setVertexBuffer:self.visibleInstanceBuffer offset:0 atIndex:1];
    [renderCommandEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                     indexCount:self.mesh.indexCount
                                      indexType:self.mesh.indexType
                                    indexBuffer:self.mesh.indexBuffer.buffer
                              indexBufferOffset:self.mesh.indexBuffer.offset
                                  instanceCount:self.cpuVisibleInstanceCount];
}

- (void)drawVertexPullingWithRenderCommandEncoder:(id<MTLRenderCommandEncoder>)renderCommandEncoder {
    if (self.mesh.indexBuffer == nil || self.mesh.indexCount == 0 || self.cpuVisibleInstanceCount == 0) {
        return;
    }

    MBEMeshBuffer *vertexBuffer = self.mesh.vertexBuffers.firstObject;

    [renderCommandEncoder setRenderPipelineState:self.vertexPullingRenderPipeline];
    [renderCommandEncoder setVertexBuffer:vertexBuffer.buffer offset:vertexBuffer.offset atIndex:0];
    [renderCommandEncoder setVertexBuffer:self.mesh.indexBuffer.buffer offset:self.mesh.indexBuffer.offset atIndex:1];
    [renderCommandEncoder setVertexBuffer:self.visibleInstanceBuffer offset:0 atIndex:2];
    [renderCommandEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                             vertexStart:0
                             vertexCount:self.mesh.indexCount
                           instanceCount:self.cpuVisibleInstanceCount];
}

- (void)drawMeshletsWithRenderCommandEncoder:(id<MTLRenderCommandEncoder>)renderCommandEncoder {
    [renderCommandEncoder setRenderPipelineState:self.meshRenderPipeline];

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

    for (MBESubmesh *submesh in self.mesh.submeshes) {
        [renderCommandEncoder setObjectBuffer:submesh.meshletBuffer.buffer
                                       offset:submesh.meshletBuffer.offset
                                      atIndex:0];
        uint32_t meshletCount = (uint32_t)submesh.meshletCount;
        [renderCommandEncoder setObjectBytes:&meshletCount length:sizeof(meshletCount) atIndex:2];

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

@end
