// sRGB -> Linear conversion (needed because Ghostty passes sRGB values but the shader pipeline operates in linear color space)
vec3 sRGBToLinear(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

// --- CONFIGURATION ---
vec4 TRAIL_COLOR = vec4(sRGBToLinear(iCurrentCursorColor.rgb), iCurrentCursorColor.a); // for custom color: vec4(0.2, 0.6, 1.0, 0.5); (wrap in sRGBToLinear for correct brightness)
const float DURATION = 0.09; // in seconds
const float MAX_TRAIL_LENGTH = 0.2;
const float THRESHOLD_MIN_DISTANCE = 1.5; // min distance to show trail (units of cursor width)
const float BLUR = 2.0; // blur size in pixels (for antialiasing)

// --- CONSTANTS for easing functions ---
const float PI = 3.14159265359;
const float C1_BACK = 1.70158;
const float C2_BACK = C1_BACK * 1.525;
const float C3_BACK = C1_BACK + 1.0;
const float C4_ELASTIC = (2.0 * PI) / 3.0;
const float C5_ELASTIC = (2.0 * PI) / 4.5;
const float SPRING_STIFFNESS = 9.0;
const float SPRING_DAMPING = 0.9;

// --- EASING FUNCTIONS ---

// // Linear
// float ease(float x) {
//     return x;
// }

// // EaseOutQuad
// float ease(float x) {
//     return 1.0 - (1.0 - x) * (1.0 - x);
// }

// // EaseOutCubic
// float ease(float x) {
//     return 1.0 - pow(1.0 - x, 3.0);
// }


// // EaseOutQuart
// float ease(float x) {
//     return 1.0 - pow(1.0 - x, 4.0);
// }

// // EaseOutQuint
// float ease(float x) {
//     return 1.0 - pow(1.0 - x, 5.0);
// }

// // EaseOutSine
// float ease(float x) {
//     return sin((x * PI) / 2.0);
// }

// // EaseOutExpo
// float ease(float x) {
//     return x == 1.0 ? 1.0 : 1.0 - pow(2.0, -10.0 * x);
// }

// EaseOutCirc
float ease(float x) {
    return sqrt(x * (2.0 - x));
}

// // EaseOutBack
// float ease(float x) {
//     return 1.0 + C3_BACK * pow(x - 1.0, 3.0) + C1_BACK * pow(x - 1.0, 2.0);
// }

// // EaseOutElastic
// float ease(float x) {
//     return x == 0.0 ? 0.0
//          : x == 1.0 ? 1.0
//                     : pow(2.0, -10.0 * x) * sin((x * 10.0 - 0.75) * C4_ELASTIC) + 1.0;
// }

// Parametric Spring
// float ease(float x) {
//     x = clamp(x, 0.0, 1.0);
//     float decay = exp(-SPRING_DAMPING * SPRING_STIFFNESS * x);
//     float freq = sqrt(SPRING_STIFFNESS * (1.0 - SPRING_DAMPING * SPRING_DAMPING));
//     float osc = cos(freq * 6.283185 * x) + (SPRING_DAMPING * sqrt(SPRING_STIFFNESS) / freq) * sin(freq * 6.283185 * x);
//     return 1.0 - decay * osc;
// }

float getSdfRectangle(in vec2 p, in vec2 xy, in vec2 b)
{
    vec2 d = abs(p - xy) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// Based on Inigo Quilez's 2D distance functions article: https://iquilezles.org/articles/distfunctions2d/
float seg(in vec2 p, in vec2 a, in vec2 b, inout float s, float d) {
    vec2 e = b - a;
    vec2 w = p - a;
    vec2 proj = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
    d = min(d, dot(proj, proj));

    float c0 = step(0.0, p.y - a.y);
    float c1 = 1.0 - step(0.0, p.y - b.y);
    float c2 = 1.0 - step(0.0, e.x * w.y - e.y * w.x);
    float allCond = c0 * c1 * c2;
    float noneCond = (1.0 - c0) * (1.0 - c1) * (1.0 - c2);
    s *= mix(1.0, -1.0, step(0.5, allCond + noneCond));
    return d;
}

float getSdfParallelogram(in vec2 p, in vec2 v0, in vec2 v1, in vec2 v2, in vec2 v3) {
    float s = 1.0;
    float d = dot(p - v0, p - v0);

    d = seg(p, v0, v3, s, d);
    d = seg(p, v1, v0, s, d);
    d = seg(p, v2, v1, s, d);
    d = seg(p, v3, v2, s, d);

    return s * sqrt(d);
}

vec2 normalize(vec2 value, float isPosition) {
    return (value * 2.0 - (iResolution.xy * isPosition)) / iResolution.y;
}

float determineIfTopRightIsLeading(vec2 a, vec2 b) {
    float condition1 = step(b.x, a.x) * step(a.y, b.y); // a.x < b.x && a.y > b.y
    float condition2 = step(a.x, b.x) * step(b.y, a.y); // a.x > b.x && a.y < b.y

    // if neither condition is met, return 1 (else case)
    return 1.0 - max(condition1, condition2);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord){
    #if !defined(WEB)
    fragColor = texture(iChannel0, fragCoord.xy / iResolution.xy);
    #endif

    vec2 offsetFactor = vec2(-.5, 0.5);

    vec4 currentCursor = vec4(normalize(iCurrentCursor.xy, 1.), normalize(iCurrentCursor.zw, 0.));
    vec4 previousCursor = vec4(normalize(iPreviousCursor.xy, 1.), normalize(iPreviousCursor.zw, 0.));

    vec2 centerCC = currentCursor.xy - (currentCursor.zw * offsetFactor);
    vec2 centerCP = previousCursor.xy - (previousCursor.zw * offsetFactor);

    vec2 delta = centerCP - centerCC;
    float lineLength = length(delta);
    float minDist = currentCursor.w * THRESHOLD_MIN_DISTANCE;
    float progress = (iTime - iTimeCursorChange) / DURATION;

    // Idle / finished animation: skip all trail work (same for every pixel)
    if (lineLength <= minDist || progress >= 1.0) {
        return;
    }
    progress = clamp(progress, 0.0, 1.0);

    vec2 vu = normalize(fragCoord, 1.);
    float aa = BLUR * 2.0 / iResolution.y;
    vec2 halfMax = max(currentCursor.zw, previousCursor.zw) * 0.5;
    vec2 aabbMin = min(centerCC, centerCP) - halfMax - aa;
    vec2 aabbMax = max(centerCC, centerCP) + halfMax + aa;

    // Most of the screen is far from the trail
    if (vu.x < aabbMin.x || vu.y < aabbMin.y || vu.x > aabbMax.x || vu.y > aabbMax.y) {
        return;
    }

    // Current cursor is drawn by Ghostty; punch it out without a full SDF
    vec2 dc = abs(vu - centerCC) - currentCursor.zw * 0.5;
    if (max(dc.x, dc.y) <= 0.0) {
        return;
    }

    float head_eased;
    float tail_eased;
    if (lineLength >= MAX_TRAIL_LENGTH) {
        head_eased = ease(progress);
        tail_eased = ease(smoothstep(MAX_TRAIL_LENGTH / lineLength, 1.0, progress));
    } else {
        head_eased = 1.0;
        tail_eased = ease(progress);
    }

    vec2 delta_abs = abs(centerCC - centerCP);
    float isStraightMove = max(step(delta_abs.y, 0.001), step(delta_abs.x, 0.001));

    float sdfTrail;
    if (isStraightMove > 0.5) {
        vec2 head_center = mix(centerCP, centerCC, head_eased);
        vec2 tail_center = mix(centerCP, centerCC, tail_eased);
        vec2 min_center = min(head_center, tail_center);
        vec2 max_center = max(head_center, tail_center);
        vec2 box_size = (max_center - min_center) + currentCursor.zw;
        vec2 box_center = (min_center + max_center) * 0.5;
        sdfTrail = getSdfRectangle(vu, box_center, box_size * 0.5);
    } else {
        vec2 head_pos_tl = mix(previousCursor.xy, currentCursor.xy, head_eased);
        vec2 tail_pos_tl = mix(previousCursor.xy, currentCursor.xy, tail_eased);

        float isTopRightLeading = determineIfTopRightIsLeading(currentCursor.xy, previousCursor.xy);
        float isBottomLeftLeading = 1.0 - isTopRightLeading;

        vec2 v0 = vec2(head_pos_tl.x + currentCursor.z * isTopRightLeading, head_pos_tl.y - currentCursor.w);
        vec2 v1 = vec2(head_pos_tl.x + currentCursor.z * isBottomLeftLeading, head_pos_tl.y);
        vec2 v2 = vec2(tail_pos_tl.x + currentCursor.z * isBottomLeftLeading, tail_pos_tl.y);
        vec2 v3 = vec2(tail_pos_tl.x + currentCursor.z * isTopRightLeading, tail_pos_tl.y - previousCursor.w);

        sdfTrail = getSdfParallelogram(vu, v0, v1, v2, v3);
    }

    fragColor = mix(fragColor, TRAIL_COLOR, 1.0 - smoothstep(0.0, aa, sdfTrail));
}
