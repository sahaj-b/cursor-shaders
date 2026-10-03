#language slang 2026
// Port of cursor_sweep.glsl from ghostty-cursor-shaders to kitty.
// Animated trail that shrinks from previous to current cursor position.
//
import kitty_custom_shader_types;

// Trail color. Alpha 0 means use kitty's cursor trail color.
// Set alpha > 0 for a custom color, e.g. float4(0.2, 0.6, 1.0, 0.8).
static const float4 TRAIL_COLOR = float4(0.0);
// Total animation time in seconds.
static const float DURATION = 0.2;
// How much of the full prev->curr quad to start with. 0 = start at cursor, 1 = full trail.
static const float TRAIL_LENGTH = 0.5;
// Min distance to show trail, in units of cursor height.
static const float THRESHOLD_MIN_DISTANCE = 1.5;
// Blur / antialias size in pixels.
static const float BLUR = 2.0;

static float
ease(float x) {
    // EaseOutCubic
    return 1.0 - pow(1.0 - x, 3.0);
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
getTopVertexFlag(float2 a, float2 b) {
    float c1 = step(b.x, a.x) * step(a.y, b.y);
    float c2 = step(a.x, b.x) * step(b.y, a.y);
    return 1.0 - max(c1, c2);
}

public float4
fragment_main(float4 color, KittyTextures t, KittyCustomShaderData d) {
    if (d.cursor_trail_color.a <= 0.0) return color;
    if (d.cursor_trail_change_time <= 0.0) return color;

    float age = clamp((d.timestamp - d.cursor_trail_change_time) / DURATION, 0.0, 1.0);
    if (age >= 1.0) return color;

    float2 pixelDims = max(float2(d.viewport_size_pixels) * t.viewport.zw, float2(1.0));
    float2 px = t.pos * pixelDims;

    // Current cursor rect in pixels. edge: .x=left .y=right .z=top .w=bottom, y-up.
    float curLeft = d.cursor_trail_edge.x * pixelDims.x;
    float curRight = d.cursor_trail_edge.y * pixelDims.x;
    float curTop = d.cursor_trail_edge.z * pixelDims.y;
    float curBottom = d.cursor_trail_edge.w * pixelDims.y;
    float curWidth = curRight - curLeft;
    float curHeight = curTop - curBottom;
    float2 curCenter = float2((curLeft + curRight) * 0.5, (curTop + curBottom) * 0.5);
    float2 curSize = float2(curWidth, curHeight);

    float prevLeft = d.cursor_trail_prev_edge.x * pixelDims.x;
    float prevTop = d.cursor_trail_prev_edge.z * pixelDims.y;
    float prevBottom = d.cursor_trail_prev_edge.w * pixelDims.y;
    float2 prevCenter = float2(
        (d.cursor_trail_prev_edge.x + d.cursor_trail_prev_edge.y) * 0.5 * pixelDims.x,
        (d.cursor_trail_prev_edge.z + d.cursor_trail_prev_edge.w) * 0.5 * pixelDims.y);

    float lineLength = length(curCenter - prevCenter);
    float minDist = max(curHeight, 1.0) * THRESHOLD_MIN_DISTANCE;
    if (lineLength < minDist) return color;

    float shrink = ease(age);

    // Straight move detection. Ghostty used 0.001 in normalized coords (~0.5px).
    float2 delta = abs(curCenter - prevCenter);
    float isHorizontal = step(delta.y, 1.0);
    float isVertical = step(delta.x, 1.0);
    float isStraight = max(isHorizontal, isVertical);

    // Parallelogram for diagonal moves. Matches Ghostty logic, widths use current width.
    float topFlag = getTopVertexFlag(curCenter, prevCenter);
    float botFlag = 1.0 - topFlag;
    float2 v0 = float2(lerp(curLeft, curRight, topFlag), curBottom);
    float2 v1 = float2(lerp(curLeft, curRight, botFlag), curTop);
    float2 v2_full = float2(prevLeft + curWidth * botFlag, prevTop);
    float2 v3_full = float2(prevLeft + curWidth * topFlag, prevBottom);
    float2 v2_start = lerp(v1, v2_full, TRAIL_LENGTH);
    float2 v3_start = lerp(v0, v3_full, TRAIL_LENGTH);
    float2 v2_anim = lerp(v2_start, v1, shrink);
    float2 v3_anim = lerp(v3_start, v0, shrink);
    float sdfDiag = sdQuad(px, v0, v1, v2_anim, v3_anim);

    // Rectangle for straight moves.
    float2 mn = min(prevCenter, curCenter);
    float2 mx = max(prevCenter, curCenter);
    float2 fullSize = (mx - mn) + curSize;
    float2 fullCenter = (mn + mx) * 0.5;
    float2 startSize = lerp(curSize, fullSize, TRAIL_LENGTH);
    float2 startCenter = lerp(curCenter, fullCenter, TRAIL_LENGTH);
    float2 animSize = lerp(startSize, curSize, shrink);
    float2 animCenter = lerp(startCenter, curCenter, shrink);
    float sdfRect = sdBox(px, animCenter, animSize * 0.5);

    float sdfTrail = lerp(sdfDiag, sdfRect, isStraight);
    float sdfCursor = sdBox(px, curCenter, curSize * 0.5);

    float aa = max(BLUR, 1.0);
    float trailAlpha = 1.0 - smoothstep(0.0, aa, sdfTrail);
    if (trailAlpha <= 0.0) return color;

    float3 trailRgb = TRAIL_COLOR.a > 0.0 ? TRAIL_COLOR.rgb : d.cursor_trail_color.rgb;
    float baseAlpha = TRAIL_COLOR.a > 0.0 ? TRAIL_COLOR.a : 1.0;
    float4 newColor = float4(lerp(color.rgb, trailRgb, saturate(trailAlpha * baseAlpha)), color.a);
    // Punch hole so the real cursor draws clean on top.
    return lerp(newColor, color, step(sdfCursor, 0.0));
}
