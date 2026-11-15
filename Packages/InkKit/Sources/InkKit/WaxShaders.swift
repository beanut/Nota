// The crayon's raster brush shaders, as Metal source compiled when `WaxRenderer` is first built (in the
// background, see `WaxRenderer.prewarm`). Compiling at run time keeps the build free of the Metal
// toolchain, which Xcode installs separately.

enum WaxShaders {
    static let source = """
    // The crayon's raster brush (`WaxRenderer.swift`): two GPU passes over one region of the destination.
    //
    // 1. Stamps → pressure field. Each nib stamp is an instanced quad over its ellipse, drawn into a
    //    single-channel half-float texture with MAX blending: a pixel keeps the strongest press of any stamp
    //    over it. Max is order-free, so the field is the same however the stamps are batched or split.
    // 2. Field → wax. Per pixel, a paper tooth computed in page space decides whether wax reaches the
    //    paper there: the harder the press, the deeper into the tooth it goes. The tooth is a function of the
    //    page position only, so it never shimmers as a stroke grows, and every region, tile, band and zoom
    //    sees the same paper.

    #include <metal_stdlib>
    using namespace metal;

    /// One nib stamp in the region's device pixels (y up, origin at the region's bottom-left).
    struct WaxStamp {
        float2 center;
        float2 axisA; // the ellipse's major semi-axis
        float2 axisB; // its minor semi-axis
        float alpha;  // how hard the stamp presses, 0…1 (pressure, tilt and the brush's opacity)
        float pad;
    };

    struct StampUniforms {
        float2 size; // the region in pixels
    };

    struct StampFragmentIn {
        float4 position [[position]];
        float2 local; // position in the stamp's own axes: the ellipse is |local| <= 1
        float alpha;
    };

    vertex StampFragmentIn waxStampVertex(uint vid [[vertex_id]],
                                          uint iid [[instance_id]],
                                          const device WaxStamp *stamps [[buffer(0)]],
                                          constant StampUniforms &u [[buffer(1)]]) {
        const float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        const WaxStamp s = stamps[iid];
        const float2 p = s.center + corner.x * s.axisA + corner.y * s.axisB;
        StampFragmentIn out;
        out.position = float4(p / u.size * 2.0 - 1.0, 0.0, 1.0);
        out.local = corner;
        out.alpha = s.alpha;
        return out;
    }

    /// A crayon presses evenly over most of its contact patch and lightly at the rim, so the rim only
    /// catches the tooth's peaks: the ragged edge.
    fragment half4 waxStampFragment(StampFragmentIn in [[stage_in]]) {
        const float r = length(in.local);
        if (r >= 1.0) {
            discard_fragment();
        }
        const float press = in.alpha * (1.0 - smoothstep(0.55, 1.0, r));
        return half4(half(press), 0.0h, 0.0h, 0.0h);
    }

    struct WaxParams {
        float2 pageOrigin; // page position (canvas points) of pixel (0, 0)'s centre
        float2 pageStepX;  // page offset of one pixel to the right
        float2 pageStepY;  // page offset of one pixel down
        float4 color;      // straight sRGB
        float toothSize;   // canvas points per tooth cell
        float contrast;    // 0…1: how much paper shows through
        float pixelsPerPoint;
        uint seed;
        uint width;
        uint height;
        uint rowPixels; // output row stride, in pixels
        uint pad;
    };

    static float hash(int2 p, uint seed) {
        uint h = uint(p.x) * 0x8da6b343u ^ uint(p.y) * 0xd8163841u ^ (seed + 1u) * 0xcb1ab31fu;
        h ^= h >> 13;
        h *= 0x5bd1e995u;
        h ^= h >> 15;
        return float(h & 0xffffffu) / 16777215.0;
    }

    /// Smooth value noise on the unit lattice, 0…1.
    static float valueNoise(float2 p, uint seed) {
        const float2 i = floor(p);
        const float2 f = p - i;
        const float2 u = f * f * (3.0 - 2.0 * f);
        const int2 c = int2(i);
        const float a = hash(c, seed), b = hash(c + int2(1, 0), seed);
        const float d = hash(c + int2(0, 1), seed), e = hash(c + int2(1, 1), seed);
        return mix(mix(a, b, u.x), mix(d, e, u.x), u.y);
    }

    /// The paper tooth at a page position, in tooth cells: three octaves, each turned so the lattice
    /// doesn't show, stretched to spread over 0…1.
    static float tooth(float2 p, uint seed) {
        const float2x2 turn1 = float2x2(float2(0.80, 0.60), float2(-0.60, 0.80));
        const float2x2 turn2 = float2x2(float2(0.28, -0.96), float2(0.96, 0.28));
        const float n = 0.55 * valueNoise(p, seed)
                      + 0.30 * valueNoise(turn1 * p * 2.03 + 17.1, seed + 1u)
                      + 0.15 * valueNoise(turn2 * p * 4.07 + 41.7, seed + 2u);
        return saturate((n - 0.5) * 2.6 + 0.5);
    }

    kernel void waxComposite(texture2d<half, access::read> field [[texture(0)]],
                             device uchar4 *out [[buffer(0)]],
                             constant WaxParams &params [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= params.width || gid.y >= params.height) {
            return;
        }
        const uint index = gid.y * params.rowPixels + gid.x;
        const float press = float(field.read(gid).r);
        if (press <= 0.002) {
            out[index] = uchar4(0);
            return;
        }
        const float2 page = params.pageOrigin + float(gid.x) * params.pageStepX + float(gid.y) * params.pageStepY;
        const float2 cell = page / params.toothSize;
        const float t = tooth(cell, params.seed);
        // How far into the tooth the wax reaches: a firm press fills all but the deepest pits, a light one
        // the upper half, and less contrast fills more.
        const float reach = pow(press, 0.75) * mix(1.35, 0.97, params.contrast);
        float wax = smoothstep(1.0 - reach - 0.08, 1.0 - reach + 0.08, t);
        // Where a tooth cell is under a couple of pixels (zoomed out, thumbnails), the grain would only alias:
        // fade to the share of paper the wax covers.
        const float cellPixels = params.toothSize * params.pixelsPerPoint;
        wax = mix(wax, saturate(reach), saturate((2.5 - cellPixels) / 2.0));
        // Wax lies thicker where it's pressed harder, and a little unevenly.
        const float fleck = valueNoise(cell * 3.1 + 5.3, params.seed + 3u);
        const float alpha = params.color.a * wax * mix(0.72, 1.0, saturate(press)) * (0.86 + 0.14 * fleck);
        const float3 rgb = saturate(params.color.rgb) * alpha;
        out[index] = uchar4(uchar(rint(rgb.r * 255.0)), uchar(rint(rgb.g * 255.0)), uchar(rint(rgb.b * 255.0)),
                            uchar(rint(saturate(alpha) * 255.0)));
    }
    """
}
