
#import "MBEMesh.h"

#import <ModelIO/ModelIO.h>

#include <algorithm>
#include <vector>

#include "meshoptimizer.h"

typedef struct MBEVertex {
    float x, y, z;
    float nx, ny, nz;
    float u, v;
} MBEVertex;

static const NSUInteger kDefaultMeshletMaxVertexCount = 128;
static const NSUInteger kDefaultMeshletMaxTriangleCount = 256;
static const float kDefaultOverdrawThreshold = 1.05f;

static NSString *MBEOptimizationOptionsDescription(MBEMeshOptimizationOptions options) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (options & MBEMeshOptimizationOptionRemap) {
        [names addObject:@"remap"];
    }
    if (options & MBEMeshOptimizationOptionVertexCache) {
        [names addObject:@"vertexCache"];
    }
    if (options & MBEMeshOptimizationOptionOverdraw) {
        [names addObject:@"overdraw"];
    }
    if (options & MBEMeshOptimizationOptionVertexFetch) {
        [names addObject:@"vertexFetch"];
    }
    if (options & MBEMeshOptimizationOptionMeshlets) {
        [names addObject:@"meshlets"];
    }
    if (options & MBEMeshOptimizationOptionOptimizeMeshlet) {
        [names addObject:@"optimizeMeshlet"];
    }
    return names.count > 0 ? [names componentsJoinedByString:@"|"] : @"raw";
}

static void MBEComputeBoundingSphere(const MBEVertex *vertices,
                                     NSUInteger vertexCount,
                                     simd_float3 *centerOut,
                                     float *radiusOut) {
    if (vertexCount == 0) {
        *centerOut = (simd_float3){ 0.0f, 0.0f, 0.0f };
        *radiusOut = 0.0f;
        return;
    }

    float minX = vertices[0].x;
    float minY = vertices[0].y;
    float minZ = vertices[0].z;
    float maxX = minX;
    float maxY = minY;
    float maxZ = minZ;

    for (NSUInteger i = 1; i < vertexCount; ++i) {
        minX = std::min(minX, vertices[i].x);
        minY = std::min(minY, vertices[i].y);
        minZ = std::min(minZ, vertices[i].z);
        maxX = std::max(maxX, vertices[i].x);
        maxY = std::max(maxY, vertices[i].y);
        maxZ = std::max(maxZ, vertices[i].z);
    }

    simd_float3 center = (simd_float3){
        (minX + maxX) * 0.5f,
        (minY + maxY) * 0.5f,
        (minZ + maxZ) * 0.5f
    };

    float radiusSquared = 0.0f;
    for (NSUInteger i = 0; i < vertexCount; ++i) {
        float dx = vertices[i].x - center.x;
        float dy = vertices[i].y - center.y;
        float dz = vertices[i].z - center.z;
        radiusSquared = std::max(radiusSquared, dx * dx + dy * dy + dz * dz);
    }

    *centerOut = center;
    *radiusOut = sqrtf(radiusSquared);
}

static MTLVertexDescriptor *MBEMakeMetalVertexDescriptor(void) {
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

    vertexDescriptor.layouts[0].stride = sizeof(MBEVertex);

    return vertexDescriptor;
}

static MDLVertexDescriptor *MBEMakeModelIOVertexDescriptor(void) {
    MDLVertexDescriptor *vertexDescriptor = [MDLVertexDescriptor new];
    vertexDescriptor.attributes[0].name = MDLVertexAttributePosition;
    vertexDescriptor.attributes[0].format = MDLVertexFormatFloat3;
    vertexDescriptor.attributes[0].offset = 0;
    vertexDescriptor.attributes[0].bufferIndex = 0;

    vertexDescriptor.attributes[1].name = MDLVertexAttributeNormal;
    vertexDescriptor.attributes[1].format = MDLVertexFormatFloat3;
    vertexDescriptor.attributes[1].offset = sizeof(float) * 3;
    vertexDescriptor.attributes[1].bufferIndex = 0;

    vertexDescriptor.attributes[2].name = MDLVertexAttributeTextureCoordinate;
    vertexDescriptor.attributes[2].format = MDLVertexFormatFloat2;
    vertexDescriptor.attributes[2].offset = sizeof(float) * 6;
    vertexDescriptor.attributes[2].bufferIndex = 0;

    vertexDescriptor.layouts[0].stride = sizeof(MBEVertex);

    return vertexDescriptor;
}

@implementation MBEMeshBuffer

- (instancetype)initWithBuffer:(id<MTLBuffer>)buffer offset:(NSInteger)offset {
    if (self = [super init]) {
        _buffer = buffer;
        _offset = offset;
    }
    return self;
}

@end

@implementation MBESubmesh

@end

@implementation MBEMesh

- (instancetype)initWithURL:(NSURL *)url device:(id<MTLDevice>)device {
    if (self = [super init]) {
        NSData *meshData = [NSData dataWithContentsOfURL:url];
        if (meshData == nil) {
            return nil;
        }

        MBEMeshFileHeader header;
        [meshData getBytes:&header length:sizeof(header)];
        const uint8_t *meshBytes = (const uint8_t *)meshData.bytes;

        _meshletMaxVertexCount = header.meshletMaxVertexCount;
        _meshletMaxTriangleCount = header.meshletMaxTriangleCount;
        _vertexCount = header.vertexDataLength / sizeof(MBEVertex);
        _meshletCount = header.meshletCount;
        _indexCount = 0;
        _indexType = MTLIndexTypeUInt32;
        MBEComputeBoundingSphere((const MBEVertex *)(meshBytes + header.vertexDataOffset),
                                 _vertexCount,
                                 &_boundsCenter,
                                 &_boundsRadius);

        _vertexDescriptor = MBEMakeMetalVertexDescriptor();

        id<MTLBuffer> vertexBuffer = [device newBufferWithBytes:meshBytes + header.vertexDataOffset
                                                          length:header.vertexDataLength
                                                         options:MTLResourceStorageModeShared];
        vertexBuffer.label = @"Mesh Vertices";

        _vertexBuffers = @[[[MBEMeshBuffer alloc] initWithBuffer:vertexBuffer offset:0]];
        id<MTLBuffer> meshletVertexBuffer = [device newBufferWithBytes:meshBytes + header.meshletVertexOffset
                                                                  length:header.meshletVertexLength
                                                                 options:MTLResourceStorageModeShared];
        meshletVertexBuffer.label = @"Meshlet Vertex Map";
        _meshletVertexBuffer = [[MBEMeshBuffer alloc] initWithBuffer:meshletVertexBuffer offset:0];

        NSAssert(header.submeshCount == 1, @"Only meshes with exactly one submesh are currently supported");
        for (int i = 0; i < header.submeshCount; ++i) {
            MBESubmesh *submesh = [MBESubmesh new];

            id<MTLBuffer> meshletBuffer = [device newBufferWithBytes:meshBytes + header.meshletsOffset
                                                              length:header.meshletCount * sizeof(MBEMeshFileMeshlet)
                                                              options:MTLResourceStorageModeShared];
            meshletBuffer.label = @"Meshlet Descriptors";

            id<MTLBuffer> meshletTriangleBuffer = [device newBufferWithBytes:meshBytes + header.meshletTrianglesOffset
                                                                      length:header.meshletTrianglesLength
                                                                     options:MTLResourceStorageModeShared];
            meshletTriangleBuffer.label = @"Meshlet Triangles";

            submesh.meshletTriangleBuffer = [[MBEMeshBuffer alloc] initWithBuffer:meshletTriangleBuffer offset:0];
            submesh.meshletBuffer = [[MBEMeshBuffer alloc] initWithBuffer:meshletBuffer offset:0];
            submesh.meshletCount = header.meshletCount;

            _submeshes = @[ submesh ];
        }

        const MBEMeshFileMeshlet *meshlets = (const MBEMeshFileMeshlet *)(meshBytes + header.meshletsOffset);
        NSUInteger triangleCount = 0;
        for (NSUInteger i = 0; i < header.meshletCount; ++i) {
            triangleCount += meshlets[i].triangleCount;
        }
        _triangleCount = triangleCount;
    }
    
    return self;
}

- (instancetype)initWithOBJURL:(NSURL *)url device:(id<MTLDevice>)device {
    return [self initWithOBJURL:url
                         device:device
          meshletMaxVertexCount:kDefaultMeshletMaxVertexCount
        meshletMaxTriangleCount:kDefaultMeshletMaxTriangleCount];
}

- (instancetype)initWithOBJURL:(NSURL *)url
                        device:(id<MTLDevice>)device
         meshletMaxVertexCount:(NSUInteger)meshletMaxVertexCount
       meshletMaxTriangleCount:(NSUInteger)meshletMaxTriangleCount {
    return [self initWithOBJURL:url
                         device:device
          meshletMaxVertexCount:meshletMaxVertexCount
        meshletMaxTriangleCount:meshletMaxTriangleCount
            optimizationOptions:MBEMeshOptimizationOptionMeshlets | MBEMeshOptimizationOptionOptimizeMeshlet];
}

- (instancetype)initWithOBJURL:(NSURL *)url
                        device:(id<MTLDevice>)device
         meshletMaxVertexCount:(NSUInteger)meshletMaxVertexCount
       meshletMaxTriangleCount:(NSUInteger)meshletMaxTriangleCount
           optimizationOptions:(MBEMeshOptimizationOptions)optimizationOptions {
    if (self = [super init]) {
        _optimizationOptions = optimizationOptions;
        NSError *error = nil;
        MDLAsset *asset = [[MDLAsset alloc] initWithURL:url
                                       vertexDescriptor:MBEMakeModelIOVertexDescriptor()
                                        bufferAllocator:nil
                                       preserveTopology:NO
                                                  error:&error];
        if (asset == nil) {
            NSLog(@"Failed to load OBJ %@: %@", url.path, error);
            return nil;
        }

        NSArray<MDLObject *> *meshObjects = [asset childObjectsOfClass:[MDLMesh class]];
        if (meshObjects.count == 0) {
            NSLog(@"OBJ %@ did not contain a root MDLMesh", url.path);
            return nil;
        }
        if (meshObjects.count > 1) {
            NSLog(@"OBJ %@ contains %lu meshes; using the first mesh for now", url.path, (unsigned long)meshObjects.count);
        }

        MDLMesh *sourceMesh = (MDLMesh *)meshObjects.firstObject;
        if (sourceMesh.vertexBuffers.count == 0 || sourceMesh.submeshes.count == 0) {
            NSLog(@"OBJ %@ did not contain vertex/index data", url.path);
            return nil;
        }

        id<MDLMeshBuffer> sourceVertexBuffer = sourceMesh.vertexBuffers.firstObject;
        MDLMeshBufferMap *vertexMap = [sourceVertexBuffer map];
        const MBEVertex *vertexBytes = (const MBEVertex *)vertexMap.bytes;
        std::vector<MBEVertex> vertices(vertexBytes, vertexBytes + sourceMesh.vertexCount);

        std::vector<uint32_t> indices;
        for (MDLSubmesh *sourceSubmesh in sourceMesh.submeshes) {
            id<MDLMeshBuffer> indexBuffer = [sourceSubmesh indexBufferAsIndexType:MDLIndexBitDepthUInt32];
            MDLMeshBufferMap *indexMap = [indexBuffer map];
            const uint32_t *indexBytes = (const uint32_t *)indexMap.bytes;
            indices.insert(indices.end(), indexBytes, indexBytes + sourceSubmesh.indexCount);
        }

        if (vertices.empty() || indices.empty() || indices.size() % 3 != 0) {
            NSLog(@"OBJ %@ produced invalid mesh data: %zu vertices, %zu indices", url.path, vertices.size(), indices.size());
            return nil;
        }

        if (optimizationOptions & MBEMeshOptimizationOptionRemap) {
            std::vector<unsigned int> remap(vertices.size());
            size_t remappedVertexCount = meshopt_generateVertexRemap(remap.data(),
                                                                     indices.data(),
                                                                     indices.size(),
                                                                     vertices.data(),
                                                                     vertices.size(),
                                                                     sizeof(MBEVertex));

            std::vector<uint32_t> remappedIndices(indices.size());
            std::vector<MBEVertex> remappedVertices(remappedVertexCount);
            meshopt_remapIndexBuffer(remappedIndices.data(), indices.data(), indices.size(), remap.data());
            meshopt_remapVertexBuffer(remappedVertices.data(), vertices.data(), vertices.size(), sizeof(MBEVertex), remap.data());
            indices = std::move(remappedIndices);
            vertices = std::move(remappedVertices);
        }

        if (optimizationOptions & MBEMeshOptimizationOptionVertexCache) {
            meshopt_optimizeVertexCache(indices.data(), indices.data(), indices.size(), vertices.size());
        }

        if (optimizationOptions & MBEMeshOptimizationOptionOverdraw) {
            meshopt_optimizeOverdraw(indices.data(),
                                     indices.data(),
                                     indices.size(),
                                     &vertices[0].x,
                                     vertices.size(),
                                     sizeof(MBEVertex),
                                     kDefaultOverdrawThreshold);
        }

        if (optimizationOptions & MBEMeshOptimizationOptionVertexFetch) {
            std::vector<MBEVertex> fetchOptimizedVertices(vertices.size());
            size_t fetchOptimizedVertexCount = meshopt_optimizeVertexFetch(fetchOptimizedVertices.data(),
                                                                           indices.data(),
                                                                           indices.size(),
                                                                           vertices.data(),
                                                                           vertices.size(),
                                                                           sizeof(MBEVertex));
            fetchOptimizedVertices.resize(fetchOptimizedVertexCount);
            vertices = std::move(fetchOptimizedVertices);
        }

        meshletMaxVertexCount = std::max<NSUInteger>(3, std::min<NSUInteger>(meshletMaxVertexCount, 256));
        meshletMaxTriangleCount = std::max<NSUInteger>(1, std::min<NSUInteger>(meshletMaxTriangleCount, 512));

        size_t meshletCount = 0;
        std::vector<meshopt_Meshlet> meshletsInternal;
        std::vector<uint32_t> meshletVertices;
        std::vector<uint8_t> meshletTriangles;
        std::vector<MBEMeshFileMeshlet> meshletRecords;

        if (optimizationOptions & MBEMeshOptimizationOptionMeshlets) {
            const float coneWeight = 0.2f;
            size_t maxMeshletCount = meshopt_buildMeshletsBound(indices.size(), meshletMaxVertexCount, meshletMaxTriangleCount);
            meshletsInternal.resize(maxMeshletCount);
            meshletVertices.resize(maxMeshletCount * meshletMaxVertexCount);
            meshletTriangles.resize(maxMeshletCount * meshletMaxTriangleCount * 3);

            meshletCount = meshopt_buildMeshlets(meshletsInternal.data(),
                                                 meshletVertices.data(),
                                                 meshletTriangles.data(),
                                                 indices.data(),
                                                 indices.size(),
                                                 &vertices[0].x,
                                                 vertices.size(),
                                                 sizeof(MBEVertex),
                                                 meshletMaxVertexCount,
                                                 meshletMaxTriangleCount,
                                                 coneWeight);
            if (meshletCount == 0) {
                NSLog(@"meshoptimizer generated no meshlets for %@", url.path);
                return nil;
            }

            meshletsInternal.resize(meshletCount);
            const meshopt_Meshlet &lastMeshlet = meshletsInternal.back();
            meshletVertices.resize(lastMeshlet.vertex_offset + lastMeshlet.vertex_count);
            meshletTriangles.resize(lastMeshlet.triangle_offset + lastMeshlet.triangle_count * 3);
            meshletRecords.reserve(meshletCount);

            for (const meshopt_Meshlet &meshlet : meshletsInternal) {
                if (optimizationOptions & MBEMeshOptimizationOptionOptimizeMeshlet) {
                    meshopt_optimizeMeshlet(meshletVertices.data() + meshlet.vertex_offset,
                                            meshletTriangles.data() + meshlet.triangle_offset,
                                            meshlet.triangle_count,
                                            meshlet.vertex_count);
                }

                meshopt_Bounds bounds = meshopt_computeMeshletBounds(meshletVertices.data() + meshlet.vertex_offset,
                                                                     meshletTriangles.data() + meshlet.triangle_offset,
                                                                     meshlet.triangle_count,
                                                                     &vertices[0].x,
                                                                     vertices.size(),
                                                                     sizeof(MBEVertex));

                MBEMeshFileMeshlet meshletRecord = {
                    .vertexOffset = meshlet.vertex_offset,
                    .vertexCount = meshlet.vertex_count,
                    .triangleOffset = meshlet.triangle_offset,
                    .triangleCount = meshlet.triangle_count,
                    .bounds = {
                        bounds.center[0],
                        bounds.center[1],
                        bounds.center[2],
                        bounds.radius
                    },
                    .coneApex = {
                        bounds.cone_apex[0],
                        bounds.cone_apex[1],
                        bounds.cone_apex[2],
                    },
                    .coneAxis = {
                        bounds.cone_axis[0],
                        bounds.cone_axis[1],
                        bounds.cone_axis[2],
                    },
                    .coneCutoff = bounds.cone_cutoff,
                    .pad = 0.0f,
                };
                meshletRecords.push_back(meshletRecord);
            }
        }

        _meshletMaxVertexCount = meshletMaxVertexCount;
        _meshletMaxTriangleCount = meshletMaxTriangleCount;
        _vertexCount = vertices.size();
        _indexCount = indices.size();
        _indexType = MTLIndexTypeUInt32;
        _triangleCount = indices.size() / 3;
        _meshletCount = meshletCount;
        MBEComputeBoundingSphere(vertices.data(), vertices.size(), &_boundsCenter, &_boundsRadius);
        _vertexDescriptor = MBEMakeMetalVertexDescriptor();

        id<MTLBuffer> vertexBuffer = [device newBufferWithBytes:vertices.data()
                                                          length:vertices.size() * sizeof(MBEVertex)
                                                         options:MTLResourceStorageModeShared];
        vertexBuffer.label = @"Runtime OBJ Mesh Vertices";
        _vertexBuffers = @[[[MBEMeshBuffer alloc] initWithBuffer:vertexBuffer offset:0]];

        id<MTLBuffer> indexBuffer = [device newBufferWithBytes:indices.data()
                                                         length:indices.size() * sizeof(uint32_t)
                                                        options:MTLResourceStorageModeShared];
        indexBuffer.label = @"Runtime OBJ Mesh Indices";
        _indexBuffer = [[MBEMeshBuffer alloc] initWithBuffer:indexBuffer offset:0];

        if (meshletCount > 0) {
            id<MTLBuffer> meshletVertexBuffer = [device newBufferWithBytes:meshletVertices.data()
                                                                      length:meshletVertices.size() * sizeof(uint32_t)
                                                                     options:MTLResourceStorageModeShared];
            meshletVertexBuffer.label = @"Runtime OBJ Meshlet Vertex Map";
            _meshletVertexBuffer = [[MBEMeshBuffer alloc] initWithBuffer:meshletVertexBuffer offset:0];

            id<MTLBuffer> meshletBuffer = [device newBufferWithBytes:meshletRecords.data()
                                                              length:meshletRecords.size() * sizeof(MBEMeshFileMeshlet)
                                                             options:MTLResourceStorageModeShared];
            meshletBuffer.label = @"Runtime OBJ Meshlet Descriptors";

            id<MTLBuffer> meshletTriangleBuffer = [device newBufferWithBytes:meshletTriangles.data()
                                                                      length:meshletTriangles.size() * sizeof(uint8_t)
                                                                     options:MTLResourceStorageModeShared];
            meshletTriangleBuffer.label = @"Runtime OBJ Meshlet Triangles";

            MBESubmesh *submesh = [MBESubmesh new];
            submesh.meshletBuffer = [[MBEMeshBuffer alloc] initWithBuffer:meshletBuffer offset:0];
            submesh.meshletTriangleBuffer = [[MBEMeshBuffer alloc] initWithBuffer:meshletTriangleBuffer offset:0];
            submesh.meshletCount = meshletCount;
            _submeshes = @[ submesh ];
        } else {
            _submeshes = @[];
        }

        NSLog(@"Loaded runtime OBJ %@ [%@]: %lu vertices, %lu triangles, %lu meshlets (%lu/%lu), bounds center=(%.3f, %.3f, %.3f), radius=%.3f",
              url.lastPathComponent,
              MBEOptimizationOptionsDescription(optimizationOptions),
              (unsigned long)_vertexCount,
              (unsigned long)_triangleCount,
              (unsigned long)_meshletCount,
              (unsigned long)_meshletMaxVertexCount,
              (unsigned long)_meshletMaxTriangleCount,
              _boundsCenter.x,
              _boundsCenter.y,
              _boundsCenter.z,
              _boundsRadius);
    }

    return self;
}

@end
