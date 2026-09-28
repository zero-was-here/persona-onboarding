//  Orb.metal — original "dark glass orb" shader for the agent's presence.
//  A 2D sphere with a deep flowing interior and luminous veins, a glowing fresnel rim, iridescent edge,
//  specular glint, an audio-reactive silhouette and an outer halo. Dark body so the white eyes read.
//  Palette comes from SwiftUI (a: body, b: swirls, c: luminous accent, irid: rim sheen).

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
        float halo = exp(-4.5 * d) * (0.16 + 0.24 * energy + 0.9 * level);
        float window = smoothstep(1.0, 0.80, r0);
        float a = clamp(halo * window, 0.0, 1.0) * 0.75;
        float3 hc = mix(cC, cI, 0.3 - 0.15 * level) * a;
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

    // Deep body with swirls; luminous veins that light up while it talks.
    float3 base = mix(cA, cB, smoothstep(0.30, 0.80, f1));
    base = mix(base, cC, smoothstep(0.62, 0.95, f2) * (0.22 + 0.4 * level));

    // Lighting: soft diffuse, depth, and a glow from within that rises with the voice.
    float diff = clamp(dot(n, L), 0.0, 1.0);
    float3 col = base * (0.55 + 0.6 * diff);
    float depth = smoothstep(-0.2, 1.0, -n.y * 0.6 + 0.4);
    col = mix(col, col * 0.7, depth * 0.3);
    col += cC * pow(z, 3.0) * (0.03 + 0.05 * energy + 0.28 * level);

    // Glowing fresnel rim in the accent colour + slow iridescent sheen.
    float fres = pow(1.0 - z, 2.2);
    col = mix(col, cC, fres * (0.5 + 0.3 * level));
    float iridBand = 0.5 + 0.5 * sin(ang * 2.0 + time * 0.4 + fres * 6.0);
    col += cI * fres * (0.3 + 0.3 * iridBand);

    // Glassy specular glint up near the rim (kept away from the eyes) + a softer secondary sparkle.
    float3 Ls = normalize(float3(-0.9, -1.1, 0.55));
    float3 H = normalize(Ls + V);
    float spec = pow(max(dot(n, H), 0.0), 70.0);
    col += spec * 0.7;
    float2 g2 = uv / radius - float2(0.38, 0.42);
    col += exp(-dot(g2, g2) * 90.0) * 0.08;

    // Static film grain (no per-frame flicker).
    col += (orbHash(position) - 0.5) * 0.025;

    // Blend the silhouette straight into the halo's first ring (no dark seam at the edge).
    float edge = smoothstep(1.0, 0.975, r);
    col = clamp(col, 0.0, 1.0);
    float haloA = clamp((0.16 + 0.24 * energy + 0.9 * level) * smoothstep(1.0, 0.80, r0), 0.0, 1.0) * 0.75;
    float3 haloC = mix(cC, cI, 0.3 - 0.15 * level) * haloA;
    return half4(half3(col * edge + haloC * (1.0 - edge)), half(edge + haloA * (1.0 - edge)));
}
