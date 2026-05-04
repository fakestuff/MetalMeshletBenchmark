
#include <metal_stdlib>
using namespace metal;

constexpr constant uint kMaxVerticesPerMeshlet = 256;
constexpr constant uint kMaxTrianglesPerMeshlet = 512;
constexpr constant uint kMeshletsPerObject = 32;
constant bool kUseFrustumCulling [[function_constant(0)]];
constant bool kUseConeCulling [[function_constant(1)]];
constant bool kUseHiZCulling [[function_constant(2)]];

struct Vertex {
    packed_float3 position;
    packed_float3 normal;
    packed_float2 texCoords;
};

struct InstanceData {
    float4x4 modelViewProjectionMatrix;
    float4x4 modelViewMatrix;
    float4x4 inverseModelViewMatrix;
    float4x4 normalMatrix;
};

struct MeshData {
    uint meshletCount;
    uint hasHiZ;
    uint hiZWidth;
    uint hiZHeight;
    uint hiZMipCount;
    float hiZDepthBias;
};

struct VSPSCullingData {
    uint instanceCount;
    uint hasHiZ;
    uint hiZWidth;
    uint hiZHeight;
    uint hiZMipCount;
    uint drawCount;
    float hiZDepthBias;
    uint pad;
    float4 bounds;
};

struct IndexedIndirectArguments {
    uint indexCount;
    atomic_uint instanceCount;
    uint indexStart;
    int baseVertex;
    uint baseInstance;
};

struct PullingIndirectArguments {
    uint vertexCount;
    atomic_uint instanceCount;
    uint vertexStart;
    uint baseInstance;
};

struct MeshletVertex {
    float4 position [[position]];
    float3 normal;
    float2 texCoords;
};

struct MeshletPrimitive {
    float4 color [[flat]];
};

struct RasterVertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 texCoords [[attribute(2)]];
};

struct RasterVertexOut {
    float4 position [[position]];
    float3 normal;
    float2 texCoords;
};

struct MeshletDescriptor {
    uint vertexOffset;
    uint vertexCount;
    uint triangleOffset;
    uint triangleCount;
    packed_float3 boundsCenter;
    float boundsRadius;
    packed_float3 coneApex;
    packed_float3 coneAxis;
    float coneCutoff, pad;
};

struct ObjectPayload {
    uint meshletIndices[kMeshletsPerObject];
    uint instanceIndex;
};

/// Extracts the six frustum planes determined by the provided matrix.
// Ref. https://www8.cs.umu.se/kurser/5DV051/HT12/lab/plane_extraction.pdf
// Ref. https://fgiesen.wordpress.com/2012/08/31/frustum-planes-from-the-projection-matrix/
static void extract_frustum_planes(constant float4x4 &matrix, thread float4 *planes) {
    float4x4 mt = transpose(matrix);
    planes[0] = mt[3] + mt[0]; // left
    planes[1] = mt[3] - mt[0]; // right
    planes[2] = mt[3] - mt[1]; // top
    planes[3] = mt[3] + mt[1]; // bottom
    planes[4] = mt[2];         // near
    planes[5] = mt[3] - mt[2]; // far
    for (int i = 0; i < 6; ++i) {
        planes[i] /= length(planes[i].xyz);
    }
}

static bool sphere_intersects_frustum(thread float4 *planes, float3 center, float radius) {
    for(int i = 0; i < 6; ++i) {
        if (dot(center, planes[i].xyz) + planes[i].w < -radius) {
            return false;
        }
    }
    return true;
}

static bool cone_is_backfacing(float3 coneApex, float3 coneAxis, float coneCutoff, float3 cameraPosition) {
    return (dot(normalize(coneApex - cameraPosition), coneAxis) >= coneCutoff);
}

static bool sphere_is_hiz_occluded(texture2d<float, access::read> hiZTexture,
                                   uint hasHiZ,
                                   uint hiZWidth,
                                   uint hiZHeight,
                                   uint hiZMipCount,
                                   float hiZDepthBias,
                                   float4x4 modelViewProjectionMatrix,
                                   float3 center,
                                   float radius) {
    if (hasHiZ == 0 || hiZWidth == 0 || hiZHeight == 0 || hiZMipCount == 0) {
        return false;
    }

    float2 viewportSize = float2(float(hiZWidth), float(hiZHeight));
    float2 minPixel = viewportSize;
    float2 maxPixel = float2(0.0f);
    float nearestDepth = 1.0f;

    for (uint corner = 0; corner < 8; ++corner) {
        float3 offset = float3((corner & 1u) ? radius : -radius,
                              (corner & 2u) ? radius : -radius,
                              (corner & 4u) ? radius : -radius);
        float4 clip = modelViewProjectionMatrix * float4(center + offset, 1.0f);
        if (clip.w <= 0.0001f) {
            return false;
        }

        float3 ndc = clip.xyz / clip.w;
        if (ndc.x < -1.25f || ndc.x > 1.25f || ndc.y < -1.25f || ndc.y > 1.25f || ndc.z < -0.25f || ndc.z > 1.25f) {
            return false;
        }

        float2 pixel = float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f) * viewportSize;
        minPixel = min(minPixel, pixel);
        maxPixel = max(maxPixel, pixel);
        nearestDepth = min(nearestDepth, saturate(ndc.z));
    }

    minPixel = clamp(minPixel, float2(0.0f), viewportSize - 1.0f);
    maxPixel = clamp(maxPixel, float2(0.0f), viewportSize - 1.0f);
    float2 rectSize = max(maxPixel - minPixel, float2(1.0f));
    uint mipLevel = min(uint(ceil(log2(max(rectSize.x, rectSize.y)))), hiZMipCount - 1u);

    uint2 mipSize = uint2(max(hiZWidth >> mipLevel, 1u), max(hiZHeight >> mipLevel, 1u));
    float2 mipScale = float2(mipSize) / viewportSize;
    uint2 minTexel = min(uint2(floor(minPixel * mipScale)), mipSize - 1u);
    uint2 maxTexel = min(uint2(floor(maxPixel * mipScale)), mipSize - 1u);

    float occluderMaxDepth = 0.0f;
    occluderMaxDepth = max(occluderMaxDepth, hiZTexture.read(minTexel, mipLevel).r);
    occluderMaxDepth = max(occluderMaxDepth, hiZTexture.read(uint2(maxTexel.x, minTexel.y), mipLevel).r);
    occluderMaxDepth = max(occluderMaxDepth, hiZTexture.read(uint2(minTexel.x, maxTexel.y), mipLevel).r);
    occluderMaxDepth = max(occluderMaxDepth, hiZTexture.read(maxTexel, mipLevel).r);

    return nearestDepth > occluderMaxDepth + hiZDepthBias;
}

static bool vsps_instance_is_visible(texture2d<float, access::read> hiZTexture,
                                     constant VSPSCullingData &culling,
                                     constant InstanceData &instance) {
    float3 center = culling.bounds.xyz;
    float radius = culling.bounds.w;

    float4 frustumPlanes[6];
    extract_frustum_planes(instance.modelViewProjectionMatrix, frustumPlanes);
    if (!sphere_intersects_frustum(frustumPlanes, center, radius)) {
        return false;
    }

    return !sphere_is_hiz_occluded(hiZTexture,
                                   culling.hasHiZ,
                                   culling.hiZWidth,
                                   culling.hiZHeight,
                                   culling.hiZMipCount,
                                   culling.hiZDepthBias,
                                   instance.modelViewProjectionMatrix,
                                   center,
                                   radius);
}

static uint hash_uint(uint value) {
    value = ((value >> ((value >> 28) + 4)) ^ value) * 277803737u;
    return (value >> 22) ^ value;
}

static float3 hash_color(uint clusterID) {
    uint value = hash_uint(clusterID * 747796405u + 2891336453u);
    float3 color = float3(value & 255u, (value >> 8) & 255u, (value >> 16) & 255u) / 255.0f;
    return color * 0.75f + 0.25f;
}

static float4 apply_lighting(float3 color, float3 normal) {
    float3 N = normalize(normal);
    float3 L = normalize(float3(1, 1, 1));

    float ambientIntensity = 0.1f;
    float diffuseIntensity = saturate(dot(N, L));

    return float4(color * saturate(ambientIntensity + diffuseIntensity), 1.0f);
}

[[vertex]]
RasterVertexOut indexed_vertex_main(RasterVertexIn in [[stage_in]],
                                    constant InstanceData *instances [[buffer(1)]],
                                    uint instanceID [[instance_id]])
{
    constant InstanceData &instance = instances[instanceID];

    RasterVertexOut out;
    out.position = instance.modelViewProjectionMatrix * float4(in.position, 1.0f);
    out.normal = (instance.normalMatrix * float4(in.normal, 0.0f)).xyz;
    out.texCoords = in.texCoords;
    return out;
}

[[vertex]]
RasterVertexOut vertex_pulling_vertex_main(uint vertexID [[vertex_id]],
                                           uint instanceID [[instance_id]],
                                           device const Vertex *vertices [[buffer(0)]],
                                           device const uint *indices [[buffer(1)]],
                                           constant InstanceData *instances [[buffer(2)]])
{
    uint index = indices[vertexID];
    device const Vertex &meshVertex = vertices[index];
    constant InstanceData &instance = instances[instanceID];

    RasterVertexOut out;
    out.position = instance.modelViewProjectionMatrix * float4(meshVertex.position, 1.0f);
    out.normal = (instance.normalMatrix * float4(meshVertex.normal, 0.0f)).xyz;
    out.texCoords = meshVertex.texCoords;
    return out;
}

[[fragment]]
float4 raster_fragment_main(RasterVertexOut in [[stage_in]],
                            uint primitiveID [[primitive_id]])
{
    uint clusterID = primitiveID / 256u;
    return apply_lighting(hash_color(clusterID), in.normal);
}

[[object, max_total_threadgroups_per_mesh_grid(kMeshletsPerObject)]]
void object_main(device const MeshletDescriptor *meshlets [[buffer(0)]],
                 constant InstanceData *instances         [[buffer(1)]],
                 constant MeshData &mesh                  [[buffer(2)]],
                 texture2d<float, access::read> hiZTexture [[texture(0)]],
                 uint3 threadPositionInGrid                [[thread_position_in_grid]],
                 uint threadIndex                          [[thread_position_in_threadgroup]],
                 object_data ObjectPayload &outObject      [[payload]],
                 mesh_grid_properties outGrid)
{
    uint meshletIndex = threadPositionInGrid.x;
    uint instanceIndex = threadPositionInGrid.y;

    if (threadIndex == 0) {
        outObject.instanceIndex = instanceIndex;
    }

    int passed = 0;
    if (meshletIndex < mesh.meshletCount) {
        constant InstanceData &instance = instances[instanceIndex];
        device const MeshletDescriptor &meshlet = meshlets[meshletIndex];

        if (!kUseFrustumCulling) {
            passed = 1;
        } else {
            float4 frustumPlanes[6];
            extract_frustum_planes(instance.modelViewProjectionMatrix, frustumPlanes);
            bool frustumCulled = !sphere_intersects_frustum(frustumPlanes, meshlet.boundsCenter, meshlet.boundsRadius);

            bool normalConeCulled = false;
            if (kUseConeCulling) {
                float3 cameraPosition = instance.inverseModelViewMatrix[3].xyz;
                normalConeCulled = cone_is_backfacing(meshlet.coneApex, meshlet.coneAxis, meshlet.coneCutoff, cameraPosition);
            }

            bool hiZCulled = false;
            if (kUseHiZCulling && !frustumCulled && !normalConeCulled) {
                hiZCulled = sphere_is_hiz_occluded(hiZTexture,
                                                   mesh.hasHiZ,
                                                   mesh.hiZWidth,
                                                   mesh.hiZHeight,
                                                   mesh.hiZMipCount,
                                                   mesh.hiZDepthBias,
                                                   instance.modelViewProjectionMatrix,
                                                   meshlet.boundsCenter,
                                                   meshlet.boundsRadius);
            }

            passed = (!frustumCulled && !normalConeCulled && !hiZCulled) ? 1 : 0;
        }
    }

    // Perform a prefix scan to determine the number of meshlets not culled by lower-indexed threads
    // in our SIMDgroup, which tells us which payload index to write our meshlet index into iff it passed.
    int payloadIndex = simd_prefix_exclusive_sum(passed);

    if (passed) {
        // Our meshlet passed its culling tests, so write it into the payload
        outObject.meshletIndices[payloadIndex] = meshletIndex;
    }

    // If we are the first thread in our object, it is our responsibility to launch
    // a mesh shader grid for each potentially visible meshlet.
    uint visibleMeshletCount = simd_sum(passed);
    if (threadIndex == 0) {
        // The mesh threadgroup count is the number of potentially visible meshlets spawned by this object
        outGrid.set_threadgroups_per_grid(uint3(visibleMeshletCount, 1, 1));
    }
}

using Meshlet = metal::mesh<MeshletVertex, MeshletPrimitive, kMaxVerticesPerMeshlet, kMaxTrianglesPerMeshlet, topology::triangle>;

[[mesh]]
void mesh_main(object_data ObjectPayload const& object   [[payload]],
               device const Vertex *meshVertices       [[buffer(0)]],
               constant MeshletDescriptor *meshlets    [[buffer(1)]],
               constant uint *meshletVertices          [[buffer(2)]],
               constant uchar *meshletTriangles        [[buffer(3)]],
               constant InstanceData *instances        [[buffer(4)]],
               uint payloadIndex    [[threadgroup_position_in_grid]],
               uint threadIndex   [[thread_position_in_threadgroup]],
               Meshlet outMesh)
{
    uint meshletIndex = object.meshletIndices[payloadIndex];
    constant MeshletDescriptor &meshlet = meshlets[meshletIndex];
    constant InstanceData &instance = instances[object.instanceIndex];

    if (threadIndex < meshlet.vertexCount) {
        device const Vertex &meshVertex = meshVertices[meshletVertices[meshlet.vertexOffset + threadIndex]];
        MeshletVertex v;
        v.position = instance.modelViewProjectionMatrix * float4(meshVertex.position, 1.0f);
        v.normal = (instance.normalMatrix * float4(meshVertex.normal, 0.0f)).xyz; // view-space normal
        v.texCoords = meshVertex.texCoords;
        outMesh.set_vertex(threadIndex, v);
    }

    if (threadIndex < meshlet.triangleCount) {
        uint i = threadIndex * 3;
        outMesh.set_index(i + 0, meshletTriangles[meshlet.triangleOffset + i + 0]);
        outMesh.set_index(i + 1, meshletTriangles[meshlet.triangleOffset + i + 1]);
        outMesh.set_index(i + 2, meshletTriangles[meshlet.triangleOffset + i + 2]);

        MeshletPrimitive prim = {
            .color = float4(hash_color(meshletIndex), 1)
        };
        outMesh.set_primitive(threadIndex, prim);
    }

    if (threadIndex == 0) {
        outMesh.set_primitive_count(meshlet.triangleCount);
    }
}

struct FragmentIn {
    MeshletVertex vert;
    MeshletPrimitive prim;
};

[[fragment]]
float4 meshlet_fragment_main(FragmentIn in [[stage_in]]) {
    return apply_lighting(in.prim.color.rgb, in.vert.normal);
}

[[kernel]]
void reset_indexed_indirect_args(device IndexedIndirectArguments *arguments [[buffer(0)]],
                                 constant VSPSCullingData &culling [[buffer(1)]],
                                 uint gid [[thread_position_in_grid]]) {
    if (gid != 0) {
        return;
    }

    arguments->indexCount = culling.drawCount;
    atomic_store_explicit(&arguments->instanceCount, 0u, memory_order_relaxed);
    arguments->indexStart = 0u;
    arguments->baseVertex = 0;
    arguments->baseInstance = 0u;
}

[[kernel]]
void reset_pulling_indirect_args(device PullingIndirectArguments *arguments [[buffer(0)]],
                                 constant VSPSCullingData &culling [[buffer(1)]],
                                 uint gid [[thread_position_in_grid]]) {
    if (gid != 0) {
        return;
    }

    arguments->vertexCount = culling.drawCount;
    atomic_store_explicit(&arguments->instanceCount, 0u, memory_order_relaxed);
    arguments->vertexStart = 0u;
    arguments->baseInstance = 0u;
}

[[kernel]]
void vsps_cull_instances_indexed(constant InstanceData *instances [[buffer(0)]],
                                 device InstanceData *visibleInstances [[buffer(1)]],
                                 device IndexedIndirectArguments *arguments [[buffer(2)]],
                                 constant VSPSCullingData &culling [[buffer(3)]],
                                 texture2d<float, access::read> hiZTexture [[texture(0)]],
                                 uint gid [[thread_position_in_grid]]) {
    if (gid >= culling.instanceCount) {
        return;
    }

    constant InstanceData &instance = instances[gid];
    if (!vsps_instance_is_visible(hiZTexture, culling, instance)) {
        return;
    }

    uint visibleIndex = atomic_fetch_add_explicit(&arguments->instanceCount, 1u, memory_order_relaxed);
    InstanceData instanceCopy = instance;
    visibleInstances[visibleIndex] = instanceCopy;
}

[[kernel]]
void vsps_cull_instances_pulling(constant InstanceData *instances [[buffer(0)]],
                                 device InstanceData *visibleInstances [[buffer(1)]],
                                 device PullingIndirectArguments *arguments [[buffer(2)]],
                                 constant VSPSCullingData &culling [[buffer(3)]],
                                 texture2d<float, access::read> hiZTexture [[texture(0)]],
                                 uint gid [[thread_position_in_grid]]) {
    if (gid >= culling.instanceCount) {
        return;
    }

    constant InstanceData &instance = instances[gid];
    if (!vsps_instance_is_visible(hiZTexture, culling, instance)) {
        return;
    }

    uint visibleIndex = atomic_fetch_add_explicit(&arguments->instanceCount, 1u, memory_order_relaxed);
    InstanceData instanceCopy = instance;
    visibleInstances[visibleIndex] = instanceCopy;
}

[[kernel]]
void hiz_copy_depth(depth2d<float, access::read> depthTexture [[texture(0)]],
                    texture2d<float, access::write> hiZTexture [[texture(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= hiZTexture.get_width() || gid.y >= hiZTexture.get_height()) {
        return;
    }

    hiZTexture.write(depthTexture.read(gid), gid);
}

[[kernel]]
void hiz_downsample_max(texture2d<float, access::read> sourceTexture [[texture(0)]],
                        texture2d<float, access::write> destinationTexture [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destinationTexture.get_width() || gid.y >= destinationTexture.get_height()) {
        return;
    }

    uint2 sourceSize = uint2(sourceTexture.get_width(), sourceTexture.get_height());
    uint2 destinationSize = uint2(destinationTexture.get_width(), destinationTexture.get_height());
    uint2 start = (gid * sourceSize) / destinationSize;
    uint2 end = min(((gid + 1u) * sourceSize + destinationSize - 1u) / destinationSize, sourceSize);
    float maxDepth = 0.0f;

    for (uint y = start.y; y < end.y; ++y) {
        for (uint x = start.x; x < end.x; ++x) {
            maxDepth = max(maxDepth, sourceTexture.read(uint2(x, y)).r);
        }
    }

    destinationTexture.write(maxDepth, gid);
}
