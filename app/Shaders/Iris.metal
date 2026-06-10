#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Procedural iris for SwiftUI's .colorEffect.
// Drawn in normalized polar space: radial fibers, a ruffled collarette
// just outside the pupil, a dark limbal ring at the rim, and a soft-edged
// pupil whose radius follows the engine's dilation signal.
[[ stitchable ]] half4 iris(float2 position, half4 color, float2 size, float dilation) {
    float2 uv = position / size - 0.5;
    float r = length(uv) * 2.0;
    float theta = atan2(uv.y, uv.x);

    if (color.a < 0.01 || r > 1.0) {
        return half4(0.0);
    }

    float pupilR = 0.34 + 0.24 * dilation;

    // Radial fibers: layered angular waves at different frequencies.
    float f1 = sin(theta * 70.0);
    float f2 = sin(theta * 23.0 + 2.1);
    float f3 = sin(theta * 113.0 + 4.7);
    float fibers = 0.55 * f1 + 0.3 * f2 + 0.15 * f3;
    fibers *= smoothstep(pupilR * 0.8, pupilR + 0.25, r);
    float fiberShade = 1.0 + fibers * 0.16;

    // Base color: bright teal near the pupil falling to a deep blue-green rim.
    float3 inner = float3(0.42, 0.82, 0.70);
    float3 mid   = float3(0.16, 0.55, 0.50);
    float3 outer = float3(0.04, 0.26, 0.27);
    float3 col = mix(inner, mid, smoothstep(pupilR, 0.7, r));
    col = mix(col, outer, smoothstep(0.6, 1.0, r));
    col *= fiberShade;

    // Collarette: brighter ruffled ring just outside the pupil.
    float collar = exp(-pow((r - (pupilR + 0.10)) * 9.0, 2.0));
    col += collar * float3(0.10, 0.09, 0.03) * (1.0 + 0.5 * sin(theta * 17.0));

    // Limbal ring: dark rim where iris meets sclera.
    col *= mix(1.0, 0.25, smoothstep(0.82, 1.0, r));

    // Pupil, soft edge.
    float pupilMask = smoothstep(pupilR, pupilR - 0.05, r);
    col = mix(col, float3(0.015), pupilMask);

    // Gentle top light.
    col += (0.5 - uv.y) * 0.04;

    return half4(half3(col), 1.0) * color.a;
}
