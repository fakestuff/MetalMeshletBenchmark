
#include <metal_stdlib>
using namespace metal;

constexpr constant uint kMaxVerticesPerMeshlet = 256;
constexpr constant uint kMaxTrianglesPerMeshlet = 512;
constexpr constant uint kMeshletsPerObject = 32;

struct Vertex {
    packed_float3 position;
    packed_float3 normal;
    packed_float2 texCoords;
};

struct InstanceData {
    float4x4 modelViewProjectionMatrix;
    float4x4 inverseModelViewMatrix;
    float4x4 normalMatrix;
};

struct MeshData {
    uint meshletCount;
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

        float4 frustumPlanes[6];
        extract_frustum_planes(instance.modelViewProjectionMatrix, frustumPlanes);
        bool frustumCulled = !sphere_intersects_frustum(frustumPlanes, meshlet.boundsCenter, meshlet.boundsRadius);

        float3 cameraPosition = instance.inverseModelViewMatrix[3].xyz;
        bool normalConeCulled = cone_is_backfacing(meshlet.coneApex, meshlet.coneAxis, meshlet.coneCutoff, cameraPosition);

        passed = (!frustumCulled && !normalConeCulled) ? 1 : 0;
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
