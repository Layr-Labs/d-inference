#include <metal_stdlib>
using namespace metal;

float darkbloomBlob(float2 point, float2 center, float2 radius) {
    float2 delta = (point - center) / radius;
    return exp(-dot(delta, delta) * 1.65);
}

float darkbloomFold(float field, float level, float width) {
    return 1.0 - smoothstep(width * 0.35, width, abs(field - level));
}

float3 darkbloomLaunchField(float2 uv, float time, float focus) {
    float t = time * 0.16;
    float focusAmount = clamp(focus, 0.0, 1.0);
    float2 attractor = float2(0.53, 0.52);
    float2 point = uv;
    point.x += sin(point.y * 7.0 + t * 1.1) * 0.045;
    point.y += sin(point.x * 5.0 - t * 0.8) * 0.032;
    point += float2(
        sin((point.x + point.y) * 9.0 + t) * 0.012,
        cos((point.x - point.y) * 8.0 - t * 0.7) * 0.014
    );

    float2 firstCenter = float2(
        0.14 + sin(t * 0.7) * 0.05,
        0.16 + cos(t * 0.6) * 0.05
    );
    float2 secondCenter = float2(
        0.56 + cos(t * 0.5) * 0.07,
        0.62 + sin(t * 0.8) * 0.08
    );
    float2 thirdCenter = float2(
        0.9 + sin(t * 0.45) * 0.04,
        0.16 + cos(t * 0.7) * 0.05
    );
    float2 fourthCenter = float2(0.28 + cos(t * 0.8) * 0.06, 1.02);

    firstCenter = mix(firstCenter, attractor, focusAmount * 0.32);
    secondCenter = mix(secondCenter, attractor, focusAmount * 0.18);
    thirdCenter = mix(thirdCenter, attractor, focusAmount * 0.38);
    fourthCenter = mix(fourthCenter, attractor, focusAmount * 0.28);

    float field = 0.0;
    field += darkbloomBlob(point, firstCenter, float2(0.27, 0.46)) * 1.4;
    field += darkbloomBlob(point, secondCenter, float2(0.21, 0.42)) * 1.35;
    field += darkbloomBlob(point, thirdCenter, float2(0.24, 0.44)) * 1.0;
    field += darkbloomBlob(point, fourthCenter, float2(0.16, 0.32)) * 0.9;
    field = 1.0 - exp(-field * (1.08 + focusAmount * 0.18));

    float3 paper = float3(0.91, 0.94, 1.0);
    float3 mist = float3(0.46, 0.59, 1.0);
    float3 cobalt = float3(0.1, 0.26, 0.94);
    float softField = smoothstep(0.04, 0.54, field);
    float coreField = smoothstep(0.3, 0.82, field);
    float3 color = mix(paper, mist, softField * 0.86);
    color = mix(color, cobalt, coreField * 0.96);

    float veil = sin((uv.x * 3.0 + uv.y * 2.0) + t * 0.55) * 0.5 + 0.5;
    return mix(color, float3(1.0), veil * 0.045);
}

[[ stitchable ]] half4 darkbloomSpatialField(
    float2 position,
    half4 currentColor,
    float2 size,
    float time,
    float focus,
    float2 pointer,
    float activity,
    float leadingFade
) {
    float2 safeSize = max(size, float2(1.0));
    float2 uv = position / safeSize;
    float activityAmount = clamp(activity, 0.0, 1.0);
    float focusAmount = clamp(focus, 0.0, 1.0);
    float welcomeAmount = clamp(leadingFade, 0.0, 1.0);

    if (welcomeAmount < 0.5) {
        return half4(
            half3(clamp(darkbloomLaunchField(uv, time, focus), 0.0, 1.0)),
            currentColor.a
        );
    }

    // Every welcome-field motion is an integer harmonic of this 120-second
    // master cycle. That keeps the Swift-side time wrap seamless while the
    // individual currents still travel at distinct 15–60 second cadences.
    const float tau = 6.28318530718;
    float cycle = time * (tau / 120.0);
    float motionGain = mix(1.0, 1.22, activityAmount);

    float2 point = uv;
    point.x += sin(point.y * 4.6 + cycle * 6.0) * 0.040 * motionGain;
    point.x += sin((point.x + point.y) * 8.7 - cycle * 4.0) * 0.011;
    point.y += sin(point.x * 4.1 - cycle * 5.0) * 0.030 * motionGain;
    point.y += cos((point.x - point.y) * 7.8 + cycle * 3.0) * 0.010;

    float2 cardCenter = mix(float2(0.66, 0.50), pointer, focusAmount * 0.72);
    float2 topCenter = float2(
        0.69 + sin(cycle * 3.0 + 0.4) * 0.055,
        -0.035 + cos(cycle * 2.0 + 1.1) * 0.035
    );
    float2 edgeCenter = float2(
        1.06 + cos(cycle * 2.0 + 2.2) * 0.040,
        0.43 + sin(cycle * 3.0 + 0.8) * 0.070
    );
    float2 bottomCenter = float2(
        0.71 + cos(cycle * 2.0 + 3.0) * 0.065,
        1.055 + sin(cycle * 3.0 + 1.2) * 0.045
    );
    float2 lowerEdgeCenter = float2(
        1.03 + sin(cycle * 3.0 + 2.4) * 0.045,
        0.82 + cos(cycle * 4.0 + 0.6) * 0.050
    );

    float mass = 0.0;
    mass += darkbloomBlob(point, topCenter, float2(0.45, 0.39)) * 1.22;
    mass += darkbloomBlob(point, edgeCenter, float2(0.34, 0.52)) * 1.08;
    mass += darkbloomBlob(point, bottomCenter, float2(0.48, 0.38)) * 1.26;
    mass += darkbloomBlob(point, lowerEdgeCenter, float2(0.29, 0.34)) * 0.56;

    float apertureBreath = 1.0 + sin(cycle * 4.0 + 0.7) * 0.028;
    float aperture = darkbloomBlob(
        point,
        cardCenter,
        mix(float2(0.31, 0.37), float2(0.26, 0.32), focusAmount)
            * apertureBreath
    );
    mass -= aperture * welcomeAmount * (0.62 + focusAmount * 0.13);
    mass = max(mass, 0.0);

    float field = 1.0 - exp(-mass * (1.0 + activityAmount * 0.16));

    // The broad mass keeps the composition stable. These two smaller waves
    // advect through it so the color boundary flows instead of translating as
    // one rigid ring.
    float fieldTravel = sin(
        point.y * 7.0
            - cycle * 5.0
            + sin(point.x * 3.2 + cycle) * 0.55
    ) * 0.014;
    fieldTravel += sin((point.x + point.y) * 8.0 + cycle * 8.0) * 0.006;
    float animatedField = clamp(
        field + fieldTravel * mix(0.92, 1.24, activityAmount),
        0.0,
        1.0
    );

    float broad = smoothstep(0.045, 0.60, animatedField);
    float core = smoothstep(0.38, 0.84, animatedField);
    float deepCore = smoothstep(0.64, 0.96, animatedField);

    float aspect = safeSize.x / safeSize.y;
    float2 focusPoint = (uv - cardCenter) * float2(aspect, 1.0);
    float focusDistance = length(focusPoint);
    float cardRipple = sin(focusDistance * 27.0 - cycle * 8.0);
    cardRipple *= exp(-focusDistance * 4.6) * focusAmount * 0.010;

    // Each visible ribbon gets its own direction and cadence. They share the
    // underlying field, but no longer move as concentric copies of one curve.
    float firstLevel = 0.29;
    firstLevel += sin(dot(uv, float2(4.5, -1.8)) + cycle * 5.0) * 0.020;
    firstLevel += sin(uv.y * 8.2 - cycle * 3.0) * 0.006;
    firstLevel += cardRipple;

    float secondLevel = 0.53;
    secondLevel += sin(dot(uv, float2(-2.2, 5.4)) - cycle * 4.0 + 1.7) * 0.016;
    secondLevel += sin(uv.x * 9.0 + cycle * 3.0) * 0.005;
    secondLevel -= cardRipple * 0.55;

    float fineLevel = 0.70;
    fineLevel += sin(dot(uv, float2(6.5, 2.5)) + cycle * 7.0 + 3.0) * 0.010;
    fineLevel += cardRipple * 0.30;

    float firstFold = darkbloomFold(animatedField, firstLevel, 0.055);
    float secondFold = darkbloomFold(animatedField, secondLevel, 0.047);
    float fineFold = darkbloomFold(animatedField, fineLevel, 0.034);
    float folds = firstFold * 0.52 + secondFold * 0.38 + fineFold * 0.18;

    float foldRelief = 0.0;
    foldRelief += darkbloomFold(animatedField, firstLevel + 0.018, 0.026) * 0.050;
    foldRelief += darkbloomFold(animatedField, secondLevel + 0.015, 0.024) * 0.038;

    float3 paper = float3(1.0, 1.0, 1.0);
    float3 pale = float3(181.0 / 255.0, 204.0 / 255.0, 1.0);
    float3 mist = float3(126.0 / 255.0, 156.0 / 255.0, 1.0);
    float3 cobalt = float3(49.0 / 255.0, 93.0 / 255.0, 236.0 / 255.0);
    float3 deep = float3(37.0 / 255.0, 75.0 / 255.0, 227.0 / 255.0);

    float cobaltCurrent = 0.0;
    cobaltCurrent += darkbloomBlob(point, topCenter, float2(0.31, 0.25)) * 0.92;
    cobaltCurrent += darkbloomBlob(point, edgeCenter, float2(0.24, 0.43)) * 0.76;
    cobaltCurrent += darkbloomBlob(point, bottomCenter, float2(0.34, 0.24)) * 1.02;
    cobaltCurrent = smoothstep(0.16, 0.96, cobaltCurrent);

    float luminousAxis = cardCenter.x;
    luminousAxis += sin(uv.y * 3.4 - cycle * 5.0) * (0.028 + activityAmount * 0.010);
    float luminousChannel = exp(-pow((uv.x - luminousAxis) * 3.4, 2.0));
    luminousChannel *= smoothstep(0.08, 0.72, animatedField);

    float3 color = mix(paper, pale, broad * 0.80);
    color = mix(color, mist, core * 0.84);
    color = mix(color, cobalt, core * (0.62 + activityAmount * 0.16));
    color = mix(color, deep, deepCore * (0.42 + activityAmount * 0.18));
    color = mix(color, cobalt, cobaltCurrent * (0.46 + activityAmount * 0.12));
    color = mix(color, pale, luminousChannel * 0.46);
    color = mix(color, deep, clamp(foldRelief, 0.0, 0.075));
    color = mix(color, paper, clamp(folds, 0.0, 0.56));

    float focusRing = exp(-pow((length(focusPoint) - 0.26) * 13.0, 2.0));
    color = mix(color, pale, focusRing * focusAmount * welcomeAmount * 0.25);

    float leadingGate = mix(1.0, smoothstep(0.0, 0.38, uv.x), welcomeAmount);
    color = mix(paper, color, leadingGate);

    return half4(half3(clamp(color, 0.0, 1.0)), currentColor.a);
}
