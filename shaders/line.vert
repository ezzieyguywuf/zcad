#version 450

layout(binding = 0) uniform UniformBufferObject {
    mat4 model;
    mat4 view;
    mat4 proj;
} ubo;
layout(binding = 1) uniform LineUniformBufferObject {
    float aspect_ratio;
    float thickness;
} line;

layout(location = 2) in vec3 a_posA;
layout(location = 3) in vec3 a_posB;
layout(location = 4) in vec3 a_colorA;
layout(location = 5) in vec3 a_colorB;
layout(location = 8) in uint a_flags;
layout(location = 9) in uint a_uid_lower;
layout(location = 10) in uint a_uid_upper;

layout(location = 0) out vec4 v_color;
layout(location = 1) out flat uvec2 v_uid;

void main() {
    v_uid = uvec2(a_uid_lower, a_uid_upper);
    bool up = (a_flags & 1u) != 0u;
    bool left = (a_flags & 2u) != 0u;
    bool edge = (a_flags & 4u) != 0u;
    // transform both ends of the line into "clip space"
    vec4 clipA = ubo.proj * ubo.view * ubo.model * vec4(a_posA, 1.0);
    vec4 clipB = ubo.proj * ubo.view * ubo.model * vec4(a_posB, 1.0);

    float antialias_offset = line.thickness * 0.1;
    float offset = line.thickness / 2.0 - antialias_offset;

    vec4 outPos = vec4(0,0,0,0);
    if (left) {
      outPos = clipA;
      v_color = vec4(a_colorA, 1);
    } else {
      outPos = clipB;
      v_color = vec4(a_colorB, 1);
    }

    if (edge) {
      v_color.a = 0;
      offset += antialias_offset;
    }

    vec2 ndcA = clipA.xy / clipA.w;
    vec2 ndcB = clipB.xy / clipB.w;
    vec2 dir = normalize(ndcB.xy - ndcA.xy);

    // The normal is easy to find in 2D.
    vec2 normal = vec2(-dir.y, dir.x);

    // We need to account for the aspect ratio to avoid distortion
    normal.x /= line.aspect_ratio;

    float offset_amt = line.thickness / 2.0;
    if (edge) {
        v_color.a = 0;
        offset_amt += antialias_offset;
    }

    // Calculate the final position in NDC
    vec2 final_ndc = outPos.xy / outPos.w;
    if (up) {
        final_ndc += normal * offset_amt;
    } else {
        final_ndc -= normal * offset_amt;
    }

    // Convert back to clip space
    outPos.xy = final_ndc * outPos.w;

    gl_Position = outPos;
}
