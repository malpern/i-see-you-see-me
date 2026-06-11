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

// Sclera lit as a sphere: fake normals from the circular profile, a single
// upper-left key light, warm off-white base, vascular warmth + faint veins
// near the corners, and socket falloff toward the rim. The "3D" read comes
// entirely from the lambert term — no geometry.
[[ stitchable ]] half4 sclera(float2 position, half4 color, float2 size) {
    float2 e = (position / size - 0.5) * 2.0;
    float r = length(e);
    if (color.a < 0.01) {
        return half4(0.0);
    }

    float rc = clamp(r, 0.0, 1.0);
    float z = sqrt(max(0.0, 1.0 - rc * rc));
    float3 n = normalize(float3(e.x, e.y, z));
    float3 lightDir = normalize(float3(-0.35, -0.5, 0.8));
    float lambert = max(0.0, dot(n, lightDir));

    float3 base = float3(0.985, 0.975, 0.952);
    float3 col = base * (0.66 + 0.34 * lambert);

    // Vascular warmth strongest at the horizontal corners.
    float corner = smoothstep(0.55, 1.0, abs(e.x)) * (1.0 - 0.5 * abs(e.y));
    col = mix(col, float3(0.93, 0.80, 0.76), corner * 0.30);

    // Faint wiggly veins radiating from the corners.
    float theta = atan2(e.y, e.x);
    float veins = sin(theta * 9.0 + sin(r * 14.0 + theta * 3.0) * 1.5);
    veins = smoothstep(0.86, 1.0, veins) * corner;
    col = mix(col, float3(0.86, 0.58, 0.55), veins * 0.22);

    // Socket falloff at the rim.
    col *= 1.0 - smoothstep(0.72, 1.0, r) * 0.24;

    return half4(half3(col), 1.0) * color.a;
}
