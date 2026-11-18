// The crayon's raster brush shaders, as Metal source compiled when `WaxRenderer` is first built (in the
// background, see `WaxRenderer.prewarm`). Compiling at run time keeps the build free of the Metal
// toolchain, which Xcode installs separately.

enum WaxShaders {
    static let source = """
    // The crayon's raster brush (`WaxRenderer.swift`): two GPU passes over one region of the destination.
    //
    // 1. Stamps → wax field. Each nib stamp is an instanced quad over its ellipse. Per pixel it works out
    //    how much wax it leaves: the harder it presses there, the deeper into the paper's tooth the wax
    //    reaches. The tooth is the paper's (a function of the page position only, so it never shimmers as a
    //    stroke grows) roughened by the crayon's own texture, which each stamp carries an offset into: it's
    //    the stroke's own, shifted with the direction of travel. A pass back over ink, in another stroke or
    //    the same one, misses different bits of paper, so layering fills the holes in, as wax does.
    //    Stamps are drawn into a single-channel half-float texture with MAX blending: a pixel keeps the most
    //    wax any stamp left there. Max is order-free, so the field is the same however the stamps are
    //    batched or split, and every region, tile and zoom sees the same paper.
    // 2. Field → colour: the wax times the ink.

    #include <metal_stdlib>
    using namespace metal;

    /// One nib stamp in the region's device pixels (y up, origin at the region's bottom-left).
    struct WaxStamp {
        float2 center;
        float2 axisA; // the ellipse's major semi-axis
        float2 axisB; // its minor semi-axis
        float2 grain; // where the crayon's own texture sits under this stamp, in tooth cells
        float alpha;  // how hard the stamp presses, 0…1 (pressure, tilt and the brush's opacity)
        float pad;
    };

    struct StampParams {
        float2 size;      // the region in pixels
        int2 origin;      // the device pixel of the region's top-left: (minX, maxY), device y up
        float2 pageFromX; // device → page (canvas points): page = pageAt0 + x * pageFromX + y * pageFromY
        float2 pageFromY;
        float2 pageAt0;
        float toothSize;  // canvas points per tooth cell
        float contrast;    // 0…1: how much paper shows through
        float pixelsPerPoint;
        uint seed;
    };

    struct StampFragmentIn {
        float4 position [[position]];
        float2 local; // position in the stamp's own axes: the ellipse is |local| <= 1
        float2 grain [[flat]];
        float alpha [[flat]];
    };

    vertex StampFragmentIn waxStampVertex(uint vid [[vertex_id]],
                                          uint iid [[instance_id]],
                                          const device WaxStamp *stamps [[buffer(0)]],
                                          constant StampParams &u [[buffer(1)]]) {
        const float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        const WaxStamp s = stamps[iid];
        const float2 p = s.center + corner.x * s.axisA + corner.y * s.axisB;
        StampFragmentIn out;
        out.position = float4(p / u.size * 2.0 - 1.0, 0.0, 1.0);
        out.local = corner;
        out.grain = s.grain;
        out.alpha = s.alpha;
        return out;
    }

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

    /// Three octaves of value noise, each turned so the lattice doesn't show; about 0.5 ± 0.16.
    static float octaves(float2 p, uint seed) {
        const float2x2 turn1 = float2x2(float2(0.80, 0.60), float2(-0.60, 0.80));
        const float2x2 turn2 = float2x2(float2(0.28, -0.96), float2(0.96, 0.28));
        return 0.55 * valueNoise(p, seed)
             + 0.30 * valueNoise(turn1 * p * 2.03 + 17.1, seed + 1u)
             + 0.15 * valueNoise(turn2 * p * 4.07 + 41.7, seed + 2u);
    }

    /// The tooth under a stamp, in tooth cells, stretched to spread over 0…1: mostly the paper's, which
    /// every stroke shares, partly the crayon's at the stamp's offset. Two passes with different offsets
    /// agree on the paper's deepest pits, so heavy layering still leaves a little paper showing.
    static float tooth(float2 cell, float2 grain, uint seed) {
        const float paper = octaves(cell, seed) - 0.5;
        const float crayon = octaves(cell + grain, seed ^ 0x9e3779b9u) - 0.5;
        const float n = (0.78 * paper + 0.62 * crayon); // weights with unit length: the same spread as one
        return saturate(n * 2.6 + 0.5);
    }

    /// A crayon presses evenly over most of its contact patch and lightly at the rim, so the rim only
    /// catches the tooth's peaks: the ragged edge.
    fragment half4 waxStampFragment(StampFragmentIn in [[stage_in]], constant StampParams &u [[buffer(0)]]) {
        const float r = length(in.local);
        if (r >= 1.0) {
            discard_fragment();
        }
        const float press = in.alpha * (1.0 - smoothstep(0.55, 1.0, r));
        if (press <= 0.002) {
            discard_fragment();
        }
        // Pixel (i, j), row 0 at the top, is device pixel (origin.x + i, origin.y - 1 - j). The page position
        // comes from the device pixel alone, so every region and tile computes the same tooth there.
        const int2 pixel = int2(in.position.xy);
        const float2 onDevice = float2(u.origin.x + pixel.x, u.origin.y - 1 - pixel.y) + 0.5;
        const float2 page = u.pageAt0 + onDevice.x * u.pageFromX + onDevice.y * u.pageFromY;
        const float2 cell = page / u.toothSize;
        const float t = tooth(cell, in.grain, u.seed);
        // How far into the tooth the wax reaches: a firm press fills all but the deepest pits, a light one
        // the upper half, and less contrast fills more.
        const float reach = pow(press, 0.75) * mix(1.35, 0.97, u.contrast);
        float wax = smoothstep(1.0 - reach - 0.08, 1.0 - reach + 0.08, t);
        // Where a tooth cell is under a couple of pixels (zoomed out, thumbnails), the grain would only alias:
        // fade to the share of paper the wax covers.
        const float cellPixels = u.toothSize * u.pixelsPerPoint;
        wax = mix(wax, saturate(reach), saturate((2.5 - cellPixels) / 2.0));
        // Wax lies thicker where it's pressed harder, and a little unevenly.
        const float fleck = valueNoise((cell + in.grain) * 3.1 + 5.3, u.seed + 3u);
        const float amount = wax * mix(0.72, 1.0, saturate(press)) * (0.86 + 0.14 * fleck);
        return half4(half(amount), 0.0h, 0.0h, 0.0h);
    }

    struct WaxParams {
        float4 color; // straight sRGB
        uint width;
        uint height;
        uint rowPixels; // output row stride, in pixels
        uint pad;
    };

    kernel void waxComposite(texture2d<half, access::read> field [[texture(0)]],
                             device uchar4 *out [[buffer(0)]],
                             constant WaxParams &params [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= params.width || gid.y >= params.height) {
            return;
        }
        const uint index = gid.y * params.rowPixels + gid.x;
        const float alpha = saturate(params.color.a * float(field.read(gid).r));
        const float3 rgb = saturate(params.color.rgb) * alpha;
        out[index] = uchar4(uchar(rint(rgb.r * 255.0)), uchar(rint(rgb.g * 255.0)), uchar(rint(rgb.b * 255.0)),
                            uchar(rint(alpha * 255.0)));
    }
    """
}
