#include <metal_stdlib>
using namespace metal;

template<typename T>
T blend_normal(T base, T blend) { return blend; }

template<typename T>
T blend_multiply(T base, T blend) { return base * blend; }

template<typename T>
T blend_screen(T base, T blend) { return base + blend - base * blend; }

fragment float4 blend_fragment(float4 baseColor [[stage_in]],
                               texture2d<float> texture [[texture(0)]]) {
    return baseColor; // Placeholder.
}
