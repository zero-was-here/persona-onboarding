//  Orb.metal — original "liquid glass orb" shader for the agent's presence.
//  A 2D sphere with a flowing marble interior, fresnel rim, iridescent edge, specular glint,
//  an audio-reactive wobbly silhouette and an outer halo. Palette comes from SwiftUI.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float orbHash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float orbNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = orbHash(i);
    float b = orbHash(i + float2(1.0, 0.0));
    float c = orbHash(i + float2(0.0, 1.0));
    float d = orbHash(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float orbFbm(float2 p) {
    float v = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 5; i++) {
        v += amp * orbNoise(p);
        p = p * 2.03 + float2(1.7, 9.2);
        amp *= 0.5;
    }
    return v;
}

/// level: 0…1 live audio level. energy: 0 idle … 1 speaking. mood: 0 calm … 1 excited.
[[ stitchable ]] half4 agentOrb(float2 position, half4 color, float2 size, float time,
                                float level, float energy, float mood,
                                half4 colorA, half4 colorB, half4 colorC, half4 irid) {
    float2 uv = (position - size * 0.5) / (min(size.x, size.y) * 0.5);
    float r0 = length(uv);
    float ang = atan2(uv.y, uv.x);

    // Silhouette: gentle breathing + audio-driven wobble.
    float breathe = sin(time * 1.3) * 0.012;
    float wob = (orbNoise(float2(ang * 1.6 + time * 0.9, time * 0.7)) - 0.5) * (0.035 + level * 0.16);
    float wob2 = (orbNoise(float2(ang * 3.1 - time * 1.4, time * 1.1 + 3.0)) - 0.5) * level * 0.07;
    float radius = 0.66 + breathe + wob + wob2 + level * 0.045;
    float r = r0 / radius;

    float3 cA = float3(colorA.rgb);
    float3 cB = float3(colorB.rgb);
    float3 cC = float3(colorC.rgb);
    float3 cI = float3(irid.rgb);

    // Halo outside the sphere (premultiplied).
    if (r > 1.0) {
        float d = r - 1.0;
        float halo = exp(-5.5 * d) * (0.28 + 0.5 * energy + 0.35 * level);
        float fade = smoothstep(1.0, 0.0, d * 1.4);
        float a = clamp(halo * fade, 0.0, 1.0) * 0.8;
        float3 hc = mix(cA, cB, 0.35) * a;
        return half4(half3(hc), half(a));
    }

    float z = sqrt(max(1.0 - r * r, 0.0));
    float3 n = normalize(float3(uv / radius, z));
    float3 L = normalize(float3(-0.62, -0.78, 0.95));
    float3 V = float3(0.0, 0.0, 1.0);

    // Marble interior that flows faster when the agent talks.
    float speed = 0.10 + energy * 0.22 + mood * 0.1;
    float2 q = n.xy * 1.9 + float2(time * speed, -time * speed * 0.8);
    float warp = orbFbm(q * 1.3 + time * 0.15);
    float f1 = orbFbm(q + warp * (1.2 + energy * 0.8));
    float f2 = orbFbm(q * 2.3 - float2(time * 0.2, time * 0.05) + warp);

    float3 base = mix(cA, cB, smoothstep(0.28, 0.78, f1));
    base = mix(base, cC, smoothstep(0.58, 0.95, f2) * 0.6);

    // Lighting: soft diffuse, refraction-like depth, inner glow.
    float diff = clamp(dot(n, L), 0.0, 1.0);
    float3 col = base * (0.42 + 0.78 * diff);
    float depth = smoothstep(-0.2, 1.0, -n.y * 0.6 + 0.4);
    col = mix(col, col * 0.62, depth * 0.35);
    col += cB * pow(z, 3.0) * (0.18 + 0.3 * energy);

    // Fresnel rim + iridescence.
    float fres = pow(1.0 - z, 2.4);
    col = mix(col, float3(1.0), fres * 0.5);
    float iridBand = 0.5 + 0.5 * sin(ang * 2.0 + time * 0.6 + fres * 6.0);
    col += cI * fres * (0.45 + 0.35 * iridBand);

    // Specular glint + secondary sparkle.
    float3 H = normalize(L + V);
    float spec = pow(max(dot(n, H), 0.0), 70.0);
    col += spec * 0.95;
    float2 g2 = uv / radius - float2(0.38, 0.42);
    col += exp(-dot(g2, g2) * 90.0) * 0.18;

    // Film grain for a physical feel.
    float grain = (orbHash(position + fract(time) * 100.0) - 0.5) * 0.035;
    col += grain;

    float edge = smoothstep(1.0, 0.975, r);
    col = clamp(col, 0.0, 1.0);
    return half4(half3(col * edge), half(edge));
}
