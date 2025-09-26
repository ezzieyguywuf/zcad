#version 450

layout(binding = 0) uniform UniformBufferObject {
  mat4 model;
  mat4 view;
  mat4 proj;
}
ubo;
layout(binding = 1) uniform LineUniformBufferObject {
  float aspect_ratio;
  float thickness;
}
line;

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
  bool is_endcap = (a_flags & 8u) != 0u;
  bool is_start_cap = (a_flags & 16u) != 0u;
  uint segment_index =
      (a_flags >> 4) & 15u;  // Extract 4 bits for segment_index

  // transform both ends of the line into "clip space"
  vec4 clipA = ubo.proj * ubo.view * ubo.model * vec4(a_posA, 1.0);
  vec4 clipB = ubo.proj * ubo.view * ubo.model * vec4(a_posB, 1.0);

  float antialias_offset = line.thickness * 0.1;
  float offset = line.thickness / 2.0 - antialias_offset;

  vec4 outPos = vec4(0, 0, 0, 0);

  vec2 ndcA = clipA.xy / clipA.w;
  vec2 ndcB = clipB.xy / clipB.w;
  vec2 dir = normalize(ndcB.xy - ndcA.xy);
  vec2 normal = vec2(-dir.y, dir.x);

  if (is_endcap) {
    vec4 cap_center_pos;
    vec2 cap_center_ndc;
    vec2 cap_dir;

    if (left) {  // Repurposing 'left' to mean 'is_start_cap'
      cap_center_pos = clipA;
      v_color = vec4(a_colorA, 1);
      cap_center_ndc = ndcA;
      cap_dir = -dir;
    } else {
      cap_center_pos = clipB;
      v_color = vec4(a_colorB, 1);
      cap_center_ndc = ndcB;
      cap_dir = dir;
    }

    // Sweep a 180-degree arc for the semicircle
    float angle_rad = 3.14159265 * (float(segment_index) / 15.0 -
                                    0.5);  // Maps 0..15 to -PI/2..PI/2

    // 1. Calculate the offset vector in a uniform coordinate system (using the
    // uncorrected dir and normal)
    vec2 offset_vec =
        (cap_dir * cos(angle_rad) + normal * sin(angle_rad)) * offset;

    // 2. Correct the final offset vector for the screen's aspect ratio
    offset_vec.x /= line.aspect_ratio;

    // 3. Apply the corrected offset
    vec2 final_ndc = cap_center_ndc + offset_vec;
    outPos =
        vec4(final_ndc * cap_center_pos.w, cap_center_pos.z, cap_center_pos.w);

  } else {
    // This is the original logic for the line body
    if (left) {
      outPos = clipA;
      v_color = vec4(a_colorA, 1);
    } else {
      outPos = clipB;
      v_color = vec4(a_colorB, 1);
    }

    float offset_amt = offset;
    if (edge) {
      v_color.a = 0;
      offset_amt += antialias_offset;
    }

    vec2 corrected_normal = normal;
    corrected_normal.x /= line.aspect_ratio;

    vec2 final_ndc = outPos.xy / outPos.w;
    if (up) {
      final_ndc += corrected_normal * offset_amt;
    } else {
      final_ndc -= corrected_normal * offset_amt;
    }
    outPos.xy = final_ndc * outPos.w;
  }

  gl_Position = outPos;
}
