#language slang 2026
// Port of cursor_warp.glsl from ghostty-cursor-shaders to kitty.
// Neovide-like cursor trail with per-corner timing for max smear.

import kitty_custom_shader_types;

// Trail color. Alpha 0 means use kitty's cursor trail color.
static const float4 TRAIL_COLOR = float4(0.0);
// Total animation time in seconds. Customized faded-warp value from README.
static const float DURATION = 0.15;
// 0 = all corners move together, 1 = max smear (leading corners jump instantly).
static const float TRAIL_SIZE = 0.8;
// Min distance to show trail, in units of cursor height. Customized value from README.
static const float THRESHOLD_MIN_DISTANCE = 1.0;
// Blur size in pixels.
static const float BLUR = 1.0;
// 1 = full cursor height, 0 = zero height, >1 gets funky.
static const float TRAIL_THICKNESS = 1.0;
static const float TRAIL_THICKNESS_X = 0.9;
// Fade gradient along the trail. Customized faded-warp enables this.
static const bool FADE_ENABLED = true;
static const float FADE_EXPONENT = 5.0;

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
sdQuad(float2 p, float2 v_tl, float2 v_tr, float2 v_br, float2 v_bl) {
    float s = 1.0;
    float d = dot(p - v_tl, p - v_tl);
    d = seg(p, v_tl, v_tr, s, d);
    d = seg(p, v_tr, v_br, s, d);
    d = seg(p, v_br, v_bl, s, d);
    d = seg(p, v_bl, v_tl, s, d);
    return s * sqrt(d);
}

static float
sgn(float x) {
    return x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0);
}

static float
durFromDot(float dotVal, float dLead, float dSide, float dTrail) {
    float isLead = step(0.5, dotVal);
    float isSide = step(-0.5, dotVal) * (1.0 - isLead);
    float dur = lerp(dTrail, dSide, isSide);
    return lerp(dur, dLead, isLead);
}

public float4
fragment_main(float4 color, KittyTextures t, KittyCustomShaderData d) {
    if (d.cursor_trail_color.a <= 0.0) return color;
    if (d.cursor_trail_change_time <= 0.0) return color;

    float baseProgress = d.timestamp - d.cursor_trail_change_time;
    if (baseProgress >= DURATION) return color;
    if (baseProgress < 0.0) return color;

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

    float prevLeft = d.cursor_trail_prev_edge.x * pixelDims.x;
    float prevRight = d.cursor_trail_prev_edge.y * pixelDims.x;
    float prevTop = d.cursor_trail_prev_edge.z * pixelDims.y;
    float prevBottom = d.cursor_trail_prev_edge.w * pixelDims.y;
    float prevWidth = prevRight - prevLeft;
    float prevHeight = prevTop - prevBottom;
    float2 prevCenter = float2((prevLeft + prevRight) * 0.5, (prevTop + prevBottom) * 0.5);

    float lineLength = length(curCenter - prevCenter);
    float minDist = max(curHeight, 1.0) * THRESHOLD_MIN_DISTANCE;
    if (lineLength < minDist) return color;

    // Current corners with thickness scaling.
    float cc_hw = curWidth * 0.5 * TRAIL_THICKNESS_X;
    float cc_hh = curHeight * 0.5 * TRAIL_THICKNESS;
    float2 cc_tl = curCenter + float2(-cc_hw, cc_hh);
    float2 cc_tr = curCenter + float2(cc_hw, cc_hh);
    float2 cc_bl = curCenter + float2(-cc_hw, -cc_hh);
    float2 cc_br = curCenter + float2(cc_hw, -cc_hh);

    float cp_hw = max(prevWidth, 1.0) * 0.5 * TRAIL_THICKNESS_X;
    float cp_hh = max(prevHeight, 1.0) * 0.5 * TRAIL_THICKNESS;
    float2 cp_tl = prevCenter + float2(-cp_hw, cp_hh);
    float2 cp_tr = prevCenter + float2(cp_hw, cp_hh);
    float2 cp_bl = prevCenter + float2(-cp_hw, -cp_hh);
    float2 cp_br = prevCenter + float2(cp_hw, -cp_hh);

    float dTrail = DURATION;
    float dLead = DURATION * (1.0 - TRAIL_SIZE);
    float dSide = (dLead + dTrail) * 0.5;

    float2 moveVec = curCenter - prevCenter;
    float2 s = float2(sgn(moveVec.x), sgn(moveVec.y));

    float dot_tl = dot(float2(-1.0, 1.0), s);
    float dot_tr = dot(float2(1.0, 1.0), s);
    float dot_bl = dot(float2(-1.0, -1.0), s);
    float dot_br = dot(float2(1.0, -1.0), s);

    float dur_tl = durFromDot(dot_tl, dLead, dSide, dTrail);
    float dur_tr = durFromDot(dot_tr, dLead, dSide, dTrail);
    float dur_bl = durFromDot(dot_bl, dLead, dSide, dTrail);
    float dur_br = durFromDot(dot_br, dLead, dSide, dTrail);

    float isRight = step(0.5, s.x);
    float isLeft = step(0.5, -s.x);
    float dot_right = (dot_tr + dot_br) * 0.5;
    float dur_right = durFromDot(dot_right, dLead, dSide, dTrail);
    float dot_left = (dot_tl + dot_bl) * 0.5;
    float dur_left = durFromDot(dot_left, dLead, dSide, dTrail);

    float f_tl = lerp(dur_tl, dur_left, isLeft);
    float f_bl = lerp(dur_bl, dur_left, isLeft);
    float f_tr = lerp(dur_tr, dur_right, isRight);
    float f_br = lerp(dur_br, dur_right, isRight);

    float p_tl = ease(clamp(baseProgress / max(f_tl, 1e-5), 0.0, 1.0));
    float p_tr = ease(clamp(baseProgress / max(f_tr, 1e-5), 0.0, 1.0));
    float p_bl = ease(clamp(baseProgress / max(f_bl, 1e-5), 0.0, 1.0));
    float p_br = ease(clamp(baseProgress / max(f_br, 1e-5), 0.0, 1.0));

    float2 v_tl = lerp(cp_tl, cc_tl, p_tl);
    float2 v_tr = lerp(cp_tr, cc_tr, p_tr);
    float2 v_br = lerp(cp_br, cc_br, p_br);
    float2 v_bl = lerp(cp_bl, cc_bl, p_bl);

    float sdfTrail = sdQuad(px, v_tl, v_tr, v_br, v_bl);
    float sdfCursor = sdBox(px, curCenter, curSize * 0.5);

    // Antialias. Ghostty disables it on straight moves for small BLUR to avoid pulse.
    float isDiag = abs(s.x) * abs(s.y);
    float effBlur = BLUR < 2.5 ? lerp(0.0, BLUR, isDiag) : BLUR;
    effBlur = max(effBlur, 0.0);
    float shapeAlpha = effBlur <= 0.01 ? (sdfTrail <= 0.0 ? 1.0 : 0.0) : 1.0 - smoothstep(0.0, effBlur, sdfTrail);
    if (shapeAlpha <= 0.0) return color;

    float3 trailRgb = TRAIL_COLOR.a > 0.0 ? TRAIL_COLOR.rgb : d.cursor_trail_color.rgb;
    float trailA = TRAIL_COLOR.a > 0.0 ? TRAIL_COLOR.a : 1.0;
    if (FADE_ENABLED) {
        float2 fragVec = px - prevCenter;
        float fadeP = clamp(dot(fragVec, moveVec) / (dot(moveVec, moveVec) + 1e-6), 0.0, 1.0);
        trailA *= pow(fadeP, FADE_EXPONENT);
    }
    float finalAlpha = saturate(trailA * shapeAlpha);
    if (finalAlpha <= 0.0) return color;

    float4 newColor = float4(lerp(color.rgb, trailRgb, finalAlpha), color.a);
    return lerp(newColor, color, step(sdfCursor, 0.0));
}
