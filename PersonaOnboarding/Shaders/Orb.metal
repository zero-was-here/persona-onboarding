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
    for (int i = 0; i < 4; i++) {
        v += amp * orbNoise(p);
        p = p * 2.03 + float2(1.7, 9.2);
        amp *= 0.5;
    }
    return v;
}

/// time: seconds (constant rate). flow: integrated interior phase (speeds up smoothly with energy).
/// level: smoothed 0…1 audio envelope. energy: 0 idle … 1 lively. excited: 0 calm … 1 happy/ringing.
[[ stitchable ]] half4 agentOrb(float2 position, half4 color, float2 size, float time, float flow,
                                float level, float energy, float excited,
                                half4 colorA, half4 colorB, half4 colorC, half4 irid) {
    float2 uv = (position - size * 0.5) / (min(size.x, size.y) * 0.5);
    float r0 = length(uv);
    float ang = atan2(uv.y, uv.x);
    // Direction on the unit circle: continuous all the way round. (Noise sampled on the atan2 angle has a
    // seam at ±π, which split the orb's left edge.)
    float2 dir = uv / max(r0, 1e-4);

    // Silhouette: slow breathing, a clear swell with the voice, and a soft organic wobble.
    float breathe = sin(time * 1.1) * 0.010;
    float wob = (orbNoise(dir * 1.35 + float2(flow * 1.7, -flow * 1.2)) - 0.5) * (0.016 + level * 0.07);
    float radius = 0.62 + breathe + wob + level * 0.08 + excited * 0.012;
    float r = r0 / radius;

    float3 cA = float3(colorA.rgb);
    float3 cB = float3(colorB.rgb);
    float3 cC = float3(colorC.rgb);
    float3 cI = float3(irid.rgb);

    // Halo outside the sphere (premultiplied), glowing up while it talks. Faded out before the view's
    // edge so it never shows a square cut-off.
    if (r > 1.0) {
        float d = r - 1.0;
        float halo = exp(-4.5 * d) * (0.22 + 0.30 * energy + 0.95 * level);
        float window = smoothstep(1.0, 0.80, r0);
        float a = clamp(halo * window, 0.0, 1.0) * 0.8;
        float3 hc = mix(cA, cB, 0.35 + 0.35 * level) * a;
        return half4(half3(hc), half(a));
    }

    float z = sqrt(max(1.0 - r * r, 0.0));
    float3 n = normalize(float3(uv / radius, z));
    float3 L = normalize(float3(-0.62, -0.78, 0.95));
    float3 V = float3(0.0, 0.0, 1.0);

    // Cloudy interior drifting with the integrated flow phase (never jumps).
    float2 q = n.xy * 1.6 + float2(flow, -flow * 0.8);
    float warp = orbFbm(q * 1.2 + flow * 0.5);
    float f1 = orbFbm(q + warp * (1.1 + energy * 0.5));
    float f2 = orbFbm(q * 2.1 - float2(flow * 0.7, flow * 0.2) + warp);

    float3 base = mix(cA, cB, smoothstep(0.28, 0.78, f1));
    base = mix(base, cC, smoothstep(0.58, 0.95, f2) * 0.55);

    // Lighting: soft diffuse, depth, and an inner glow that brightens with the voice.
    float diff = clamp(dot(n, L), 0.0, 1.0);
    float3 col = base * (0.45 + 0.75 * diff);
    float depth = smoothstep(-0.2, 1.0, -n.y * 0.6 + 0.4);
    col = mix(col, col * 0.64, depth * 0.33);
    col += cB * pow(z, 2.2) * (0.14 + 0.20 * energy + 0.65 * level);

    // Fresnel rim + slow iridescence.
    float fres = pow(1.0 - z, 2.4);
    col = mix(col, float3(1.0), fres * 0.45);
    float iridBand = 0.5 + 0.5 * sin(ang * 2.0 + time * 0.4 + fres * 6.0);
    col += cI * fres * (0.4 + 0.3 * iridBand);

    // Specular glint + a softer secondary sparkle.
    float3 H = normalize(L + V);
    float spec = pow(max(dot(n, H), 0.0), 60.0);
    col += spec * 0.85;
    float2 g2 = uv / radius - float2(0.38, 0.42);
    col += exp(-dot(g2, g2) * 90.0) * 0.14;

    // Static film grain (no per-frame flicker).
    col += (orbHash(position) - 0.5) * 0.025;

    float edge = smoothstep(1.0, 0.975, r);
    col = clamp(col, 0.0, 1.0);
    return half4(half3(col * edge), half(edge));
}
