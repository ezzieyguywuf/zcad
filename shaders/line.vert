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
// which[0] = left (true = left, false = right)
// which[1] = up   (true = up,   false = down)
layout(location = 6) in vec2 which;

layout(location = 0) out vec3 v_color;

void main() {
    // transform both ends of the line into "clip space"
    vec4 clipA = ubo.proj * ubo.view * ubo.model * vec4(a_posA, 1.0);
    vec4 clipB = ubo.proj * ubo.view * ubo.model * vec4(a_posB, 1.0);

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
    vec4 normal = vec4(-dir.y, dir.x, 0, 1) * (line.thickness / 2.0) * ubo.proj;

    vec4 outPos = vec4(0,0,0,0);
    if (which[0] > 0) {
      outPos = clipA;
      v_color = a_colorA;
    } else {
      outPos = clipB;
      v_color = a_colorB;
    }

    if (which[1] > 0) {
      outPos.xy += normal.xy;
    } else {
      outPos.xy -= normal.xy;
    }

    gl_Position = outPos;
}
