enum ShaderSource {
    static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position [[attribute(0)]];
        float2 texCoord [[attribute(1)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    struct Uniforms {
        float4x4 transform;
    };

    struct ColorUniforms {
        float4 color;
    };

    vertex VertexOut vertexShader(
        VertexIn in [[stage_in]],
        constant Uniforms &uniforms [[buffer(1)]]
    ) {
        VertexOut out;
        out.position = uniforms.transform * float4(in.position, 0.0, 1.0);
        out.texCoord = in.texCoord;
        return out;
    }

    fragment float4 fragmentShader(
        VertexOut in [[stage_in]],
        texture2d<float> texture [[texture(0)]],
        sampler texSampler [[sampler(0)]]
    ) {
        return texture.sample(texSampler, in.texCoord);
    }

    fragment float4 flatColorFragment(
        VertexOut in [[stage_in]],
        constant ColorUniforms &colorUniforms [[buffer(0)]]
    ) {
        return colorUniforms.color;
    }

    // MARK: - Animated Selection Border

    struct SelectionUniforms {
        float time;
        float2 rectSize;      // quad size in points
        float borderWidth;    // border thickness in points
        int effectType;       // 0 = rainbow, 1 = glow, 2 = solid skyblue, 3 = fire
        float2 innerOffset;   // offset to inner rect within expanded quad
        float2 innerSize;     // size of the inner rect
    };

    float3 hsv2rgb(float3 c) {
        float3 p = abs(fract(float3(c.x) + float3(1.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
        return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
    }

    // --- Value noise helpers for fire effect (double-FBM distortion) ---
    float fireRand(float2 n) {
        return fract(cos(dot(n, float2(12.9898, 4.1414))) * 43758.5453);
    }

    float fireNoise(float2 n) {
        float2 d = float2(0.0, 1.0);
        float2 b = floor(n);
        float2 f = smoothstep(float2(0.0), float2(1.0), fract(n));
        return mix(mix(fireRand(b), fireRand(b + d.yx), f.x),
                   mix(fireRand(b + d.xy), fireRand(b + d.yy), f.x), f.y);
    }

    float fireFbm(float2 n) {
        float total = 0.0, amplitude = 1.0;
        for (int i = 0; i < 4; i++) {
            total += fireNoise(n) * amplitude;
            n += n;
            amplitude *= 0.5;
        }
        return total;
    }

    // Organic fire via double-FBM turbulence with rich color mixing.
    // uv.x: position along edge; uv.y: 0 at inner edge, 1 at outer tip.
    float4 computeFlame(float2 uv, float time) {
        float3 c1 = float3(0.5, 0.0, 0.1);
        float3 c2 = float3(0.9, 0.1, 0.0);
        float3 c3 = float3(0.2, 0.0, 0.0);
        float3 c4 = float3(1.0, 0.9, 0.0);
        float3 c5 = float3(0.1);
        float3 c6 = float3(0.9);

        float2 speed = float2(0.7, 0.4);

        // Map along-edge to a circle for seamless tiling around the border
        float theta = uv.x * 2.0 * M_PI_F;
        float2 p = float2(cos(theta), sin(theta)) * (1.3 + uv.y * 3.0);

        float q = fireFbm(p - time * 0.1);
        float2 r = float2(fireFbm(p + q + time * speed.x - p.x - p.y),
                           fireFbm(p + q - time * speed.y));
        float3 c = mix(c1, c2, fireFbm(p + r)) + mix(c3, c4, r.x) - mix(c5, c6, r.y);
        c = max(c, float3(0.0));  // clamp out dark shadows without changing the palette

        float fade = cos(1.6 * uv.y);
        c *= fade;
        float alpha = clamp(fade, 0.0, 1.0);
        return float4(clamp(c, 0.0, 1.0), alpha);
    }

    fragment float4 selectionFragment(
        VertexOut in [[stage_in]],
        constant SelectionUniforms &sel [[buffer(0)]]
    ) {
        float2 pixelPos = in.texCoord * sel.rectSize;
        float distLeft = pixelPos.x;
        float distRight = sel.rectSize.x - pixelPos.x;
        float distTop = pixelPos.y;
        float distBottom = sel.rectSize.y - pixelPos.y;
        float distFromEdge = min(min(distLeft, distRight), min(distTop, distBottom));

        if (sel.effectType != 3 && distFromEdge >= sel.borderWidth) {
            // Inside thumbnail area — transparent so thumbnail shows through
            return float4(0.0, 0.0, 0.0, 0.0);
        }

        if (sel.effectType == 0) {
            // Rainbow: hue cycles around the border based on angle from center
            float2 center = sel.rectSize * 0.5;
            float2 dir = pixelPos - center;
            float angle = atan2(dir.y, dir.x);
            float normalizedAngle = (angle + M_PI_F) / (2.0 * M_PI_F);
            float hue = fract(normalizedAngle * 2.0 + sel.time * 0.4);
            float saturation = 0.85;
            float brightness = 0.8 + 0.2 * (1.0 - distFromEdge / sel.borderWidth);
            float3 rgb = hsv2rgb(float3(hue, saturation, brightness));
            return float4(rgb, 1.0);
        } else if (sel.effectType == 1) {
            // Glow: pulsing white, brighter at the outer edge
            float edgeFactor = 1.0 - distFromEdge / sel.borderWidth;
            float pulse = 0.5 + 0.5 * sin(sel.time * 3.0);
            float brightness = mix(0.4, 1.0, edgeFactor * pulse);
            return float4(brightness, brightness, brightness, 1.0);
        } else if (sel.effectType == 2) {
            // Solid skyblue (#87CEEB)
            return float4(0.529, 0.808, 0.922, 1.0);
        } else {
            // Fire: organic double-FBM fire around the border
            float2 innerMin = sel.innerOffset;
            float2 innerMax = sel.innerOffset + sel.innerSize;

            // Inside thumbnail — transparent
            if (pixelPos.x >= innerMin.x && pixelPos.x <= innerMax.x &&
                pixelPos.y >= innerMin.y && pixelPos.y <= innerMax.y) {
                return float4(0.0, 0.0, 0.0, 0.0);
            }

            // Distance from inner rect edge
            float dL = max(0.0, innerMin.x - pixelPos.x);
            float dR = max(0.0, pixelPos.x - innerMax.x);
            float dT = max(0.0, innerMin.y - pixelPos.y);
            float dB = max(0.0, pixelPos.y - innerMax.y);
            float outDist = max(max(dL, dR), max(dT, dB));
            float normalizedDist = 1.0 - clamp(outDist / sel.innerOffset.x, 0.0, 1.0);

            // Angle-based along-edge coordinate for smooth continuity
            float2 center = (innerMin + innerMax) * 0.5;
            float angle = atan2(pixelPos.y - center.y, pixelPos.x - center.x);
            float along = (angle + M_PI_F) / (2.0 * M_PI_F);

            return computeFlame(float2(along, normalizedDist), sel.time);
        }
    }

    // MARK: - Morph Effect on Selected Thumbnail

    struct MorphUniforms {
        float time;
        int effectType;   // 0 = wave, 1 = tv static
    };

    // Hash for procedural noise (TV static)
    float hash21(float2 p) {
        p = fract(p * float2(233.34, 851.73));
        p += dot(p, p + 23.45);
        return fract(p.x * p.y);
    }

    fragment float4 morphThumbnailFragment(
        VertexOut in [[stage_in]],
        texture2d<float> texture [[texture(0)]],
        sampler texSampler [[sampler(0)]],
        constant MorphUniforms &morph [[buffer(0)]]
    ) {
        float2 uv = in.texCoord;
        float t = morph.time;

        if (morph.effectType == 1) {
            // TV Static: noise + scanlines + horizontal tear

            // Horizontal tear — occasional row displacement
            float tearStrength = pow(max(0.0, sin(t * 0.6)), 10.0);
            float rowNoise = hash21(float2(floor(uv.y * 80.0), floor(t * 8.0)));
            uv.x += (rowNoise - 0.5) * 0.06 * tearStrength;

            // Jitter — subtle per-frame horizontal shake
            uv.x += (hash21(float2(t * 13.0, 0.0)) - 0.5) * 0.002;

            float4 color = texture.sample(texSampler, uv);

            // Noise grain overlay
            float noise = hash21(uv * 800.0 + t * 100.0);
            color.rgb = mix(color.rgb, float3(noise), 0.08);

            // Scanlines — darken every other pair of rows
            float scanline = 0.92 + 0.08 * step(0.5, fract(uv.y * 150.0));
            color.rgb *= scanline;

            // Occasional snow burst (peaks every ~5s)
            float snowPulse = pow(max(0.0, sin(t * 0.65)), 16.0);
            float snow = hash21(uv * 400.0 + float2(t * 50.0, t * 37.0));
            color.rgb = mix(color.rgb, float3(snow), snowPulse * 0.4);

            return color;
        }

        // Wave: subtle wobble + occasional chromatic aberration
        uv.x += sin(uv.y * 8.0 + t * 1.5) * 0.003;
        uv.y += cos(uv.x * 8.0 + t * 1.2) * 0.003;

        float pulse = pow(max(0.0, sin(t * 0.8)), 12.0);
        float aberration = pulse * 0.008;

        float2 center = float2(0.5, 0.5);
        float2 dir = uv - center;

        float r = texture.sample(texSampler, uv + dir * aberration).r;
        float g = texture.sample(texSampler, uv).g;
        float b = texture.sample(texSampler, uv - dir * aberration).b;
        float a = texture.sample(texSampler, uv).a;

        return float4(r, g, b, a);
    }

    // MARK: - Nav Zone Overlay (dark overlay + chevron)

    struct NavZoneUniforms {
        float alpha;       // overall opacity (auto-hide)
        int pointsLeft;    // 1 = left chevron (<), 0 = right chevron (>)
        float aspectRatio; // zone width / zone height (for correct SDF)
    };

    float navSdSegment(float2 p, float2 a, float2 b) {
        float2 pa = p - a;
        float2 ba = b - a;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        return length(pa - ba * h);
    }

    fragment float4 navZoneFragment(
        VertexOut in [[stage_in]],
        constant NavZoneUniforms &nav [[buffer(0)]]
    ) {
        float2 uv = in.texCoord;

        // Center coordinates (-1..1), aspect-corrected
        float2 p = uv * 2.0 - 1.0;
        p.x *= nav.aspectRatio;

        // Flip x for right-pointing chevron (shader draws left by default)
        if (nav.pointsLeft == 0) p.x = -p.x;

        float angleDeg = 50.0;
        float size = 0.32;
        float thickness = 0.018;

        float angle = angleDeg * M_PI_F / 180.0;

        float2 dir1 = normalize(float2(cos(angle),  sin(angle)));
        float2 dir2 = normalize(float2(cos(angle), -sin(angle)));

        float2 tip = float2(-0.15, 0.0);

        float2 a = tip + dir1 * size;
        float2 b = tip;
        float2 c = tip + dir2 * size;

        float d = min(
            navSdSegment(p, a, b),
            navSdSegment(p, c, b)
        );

        float edge = fwidth(d);
        float chevron = smoothstep(thickness + edge, thickness - edge, d);

        // Uniform dark overlay + near-black chevron on top
        float overlay = 0.25;
        float overlayAlpha = (overlay + chevron * 0.65) * nav.alpha;
        return float4(0.0, 0.0, 0.0, overlayAlpha);
    }
    """
}
