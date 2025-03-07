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
layout(location = 6) in uint up_int;
layout(location = 7) in uint left_int;
layout(location = 8) in uint edge_int;

layout(location = 0) out vec4 v_color;

void main() {
    bool left = up_int > 0;
    bool up = left_int > 0;
    bool edge = edge_int > 0;
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
      v_color = vec4(1 , 0 , 0, 1);
      if (up) {
        offset += antialias_offset;
      } else {
        offset -= antialias_offset;
      }
    }

    // Dividing by "w" converts to normalized device coordinates. We also have
    // to account for the aspect ratio
    vec2 ndcA = clipA.xy / clipA.w;
    vec2 ndcB = clipB.xy / clipB.w;
    ndcA.x = ndcA.x * line.aspect_ratio;
    ndcB.x = ndcB.x * line.aspect_ratio;
    // This defines the direction from pointA to pointB
    vec2 dir = normalize(ndcB.xy - ndcA.xy);

    // The normal is easy to find in 2D. We put it in a vec4 so we can apply the
    // projection matrix to it. We'll extrude the line in this direction by half
    // the thickness
    vec4 normal = vec4(-dir.y, dir.x, 0, 1) * offset * ubo.proj;

    if (up) {
      outPos.xy += normal.xy;
    } else {
      outPos.xy -= normal.xy;
    }

    gl_Position = outPos;
}
