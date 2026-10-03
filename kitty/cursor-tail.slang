#language slang 2026
// Port of cursor_tail.glsl from ghostty-cursor-shaders to kitty.
// Comet-like trail, mimics kitty's own trail but with Ghostty easing.

import kitty_custom_shader_types;

// Trail color. Alpha 0 means use kitty's cursor trail color.
static const float4 TRAIL_COLOR = float4(0.0);
// Animation time in seconds.
static const float DURATION = 0.09;
// Max trail length in Ghostty normalized units (0.2 ~= 10% of screen height).
// Converted to pixels internally as MAX * viewportHeight * 0.5.
static const float MAX_TRAIL_LENGTH = 0.2;
// Min distance to show trail, in units of cursor height.
static const float THRESHOLD_MIN_DISTANCE = 1.5;
// Antialias size in pixels.
static const float BLUR = 2.0;

static float
ease(float x) {
    // EaseOutCirc
    return sqrt(1.0 - pow(x - 1.0, 2.0));
}

static float
sdBox(float2 p, float2 center, float2 hext) {
    float2 d = abs(p - center) - hext;
    return length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0);
}

static float
seg(float2 p, float2 a, float2 b, inout float s, float d) {
    float2 e = b - a;
    float2 w = p - a;
    float2 proj = a + e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
    d = min(d, dot(p - proj, p - proj));
    float c0 = step(0.0, p.y - a.y);
    float c1 = 1.0 - step(0.0, p.y - b.y);
    float c2 = 1.0 - step(0.0, e.x * w.y - e.y * w.x);
    float allCond = c0 * c1 * c2;
    float noneCond = (1.0 - c0) * (1.0 - c1) * (1.0 - c2);
    s *= lerp(1.0, -1.0, step(0.5, allCond + noneCond));
    return d;
}

static float
sdQuad(float2 p, float2 v0, float2 v1, float2 v2, float2 v3) {
    float s = 1.0;
    float d = dot(p - v0, p - v0);
    d = seg(p, v0, v3, s, d);
    d = seg(p, v1, v0, s, d);
    d = seg(p, v2, v1, s, d);
    d = seg(p, v3, v2, s, d);
    return s * sqrt(d);
}

static float
topRightLeading(float2 a, float2 b) {
    float c1 = step(b.x, a.x) * step(a.y, b.y);
    float c2 = step(a.x, b.x) * step(b.y, a.y);
    return 1.0 - max(c1, c2);
}

public float4
fragment_main(float4 color, KittyTextures t, KittyCustomShaderData d) {
    if (d.cursor_trail_color.a <= 0.0) return color;
    if (d.cursor_trail_change_time <= 0.0) return color;

    float progress = clamp((d.timestamp - d.cursor_trail_change_time) / DURATION, 0.0, 1.0);
    if (progress >= 1.0) return color;

    float2 pixelDims = max(float2(d.viewport_size_pixels) * t.viewport.zw, float2(1.0));
    float2 px = t.pos * pixelDims;

    float curLeft = d.cursor_trail_edge.x * pixelDims.x;
    float curRight = d.cursor_trail_edge.y * pixelDims.x;
    float curTop = d.cursor_trail_edge.z * pixelDims.y;
    float curBottom = d.cursor_trail_edge.w * pixelDims.y;
    float curWidth = curRight - curLeft;
    float curHeight = curTop - curBottom;
    float2 curCenter = float2((curLeft + curRight) * 0.5, (curTop + curBottom) * 0.5);
    float2 curSize = float2(curWidth, curHeight);
    float2 curLT = float2(curLeft, curTop);

    float prevLeft = d.cursor_trail_prev_edge.x * pixelDims.x;
    float prevTop = d.cursor_trail_prev_edge.z * pixelDims.y;
    float prevBottom = d.cursor_trail_prev_edge.w * pixelDims.y;
    float prevHeight = (d.cursor_trail_prev_edge.z - d.cursor_trail_prev_edge.w) * pixelDims.y;
    float2 prevCenter = float2(
        (d.cursor_trail_prev_edge.x + d.cursor_trail_prev_edge.y) * 0.5 * pixelDims.x,
        (d.cursor_trail_prev_edge.z + d.cursor_trail_prev_edge.w) * 0.5 * pixelDims.y);
    float2 prevLT = float2(prevLeft, prevTop);

    float lineLength = length(curCenter - prevCenter);
    float minDist = max(curHeight, 1.0) * THRESHOLD_MIN_DISTANCE;
    if (lineLength < minDist) return color;

    // MAX_TRAIL_LENGTH is in Ghostty normalized units, convert to pixels.
    float maxTrailPx = MAX_TRAIL_LENGTH * pixelDims.y * 0.5;
    float tailDelay = maxTrailPx / max(lineLength, 1e-5);
    float isLong = step(maxTrailPx, lineLength);

    float headShort = ease(progress);
    float tailShort = tailDelay >= 1.0 ? 0.0 : ease(smoothstep(tailDelay, 1.0, progress));
    float headLong = 1.0;
    float tailLong = ease(progress);
    float headEased = lerp(headLong, headShort, isLong);
    float tailEased = lerp(tailLong, tailShort, isLong);

    float2 delta = abs(curCenter - prevCenter);
    float isHorizontal = step(delta.y, 1.0);
    float isVertical = step(delta.x, 1.0);
    float isStraight = max(isHorizontal, isVertical);

    // Diagonal parallelogram path.
    float2 headTL = lerp(prevLT, curLT, headEased);
    float2 tailTL = lerp(prevLT, curLT, tailEased);
    float isTR = topRightLeading(curCenter, prevCenter);
    float isBL = 1.0 - isTR;
    float2 v0 = float2(headTL.x + curWidth * isTR, headTL.y - curHeight);
    float2 v1 = float2(headTL.x + curWidth * isBL, headTL.y);
    float2 v2 = float2(tailTL.x + curWidth * isBL, tailTL.y);
    float2 v3 = float2(tailTL.x + curWidth * isTR, tailTL.y - max(prevHeight, 1.0));
    float sdfDiag = sdQuad(px, v0, v1, v2, v3);

    // Straight rectangle path.
    float2 headC = lerp(prevCenter, curCenter, headEased);
    float2 tailC = lerp(prevCenter, curCenter, tailEased);
    float2 mn = min(headC, tailC);
    float2 mx = max(headC, tailC);
    float2 boxSize = (mx - mn) + curSize;
    float2 boxCenter = (mn + mx) * 0.5;
    float sdfRect = sdBox(px, boxCenter, boxSize * 0.5);

    float sdfTrail = lerp(sdfDiag, sdfRect, isStraight);
    float sdfCursor = sdBox(px, curCenter, curSize * 0.5);

    float aa = max(BLUR, 1.0);
    float trailAlpha = 1.0 - smoothstep(0.0, aa, sdfTrail);
    if (trailAlpha <= 0.0) return color;

    float3 trailRgb = TRAIL_COLOR.a > 0.0 ? TRAIL_COLOR.rgb : d.cursor_trail_color.rgb;
    float baseAlpha = TRAIL_COLOR.a > 0.0 ? TRAIL_COLOR.a : 1.0;
    float4 newColor = float4(lerp(color.rgb, trailRgb, saturate(trailAlpha * baseAlpha)), color.a);
    return lerp(newColor, color, step(sdfCursor, 0.0));
}
