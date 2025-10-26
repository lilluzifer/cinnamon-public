#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position;
    float2 texCoord;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct TransformUniforms {
    float4x4 modelToNDC;
    float opacity;
    uint blendModeIndex;
    float2 _pad;
};

vertex VertexOut transform_vertex(uint vertexID [[vertex_id]],
                                  constant VertexIn *vertices [[buffer(0)]],
                                  constant TransformUniforms &uniforms [[buffer(1)]]) {
    VertexOut out;
    float4 pos = float4(vertices[vertexID].position, 0.0, 1.0);
    out.position = uniforms.modelToNDC * pos;
    out.texCoord = vertices[vertexID].texCoord;
    return out;
}
