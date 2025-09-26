#version 450

layout(binding = 0) uniform UniformBufferObject {
    mat4 model;
    mat4 view;
    mat4 proj;
} ubo;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inColor;
layout(location = 11) in uint inUidLower;
layout(location = 12) in uint inUidUpper;

layout(location = 0) out vec3 v_color;
layout(location = 1) out flat uvec2 v_id;

void main() {
    gl_Position = ubo.proj * ubo.view * ubo.model * vec4(inPosition, 1.0);
    gl_PointSize = 20.0f;
    v_color = inColor;
    v_id = uvec2(inUidLower, inUidUpper);
}

