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
        int effectType;       // 0 = rainbow, 1 = glow
    };

    float3 hsv2rgb(float3 c) {
        float3 p = abs(fract(float3(c.x) + float3(1.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
        return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
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

        if (distFromEdge >= sel.borderWidth) {
            // Inside thumbnail area — background color
            return float4(0.08, 0.08, 0.08, 1.0);
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
        } else {
            // Glow: pulsing white, brighter at the outer edge
            float edgeFactor = 1.0 - distFromEdge / sel.borderWidth;
            float pulse = 0.5 + 0.5 * sin(sel.time * 3.0);
            float brightness = mix(0.4, 1.0, edgeFactor * pulse);
            return float4(brightness, brightness, brightness, 1.0);
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
    """
}
