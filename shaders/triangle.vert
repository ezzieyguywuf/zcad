#version 450

layout(binding = 0) uniform MVPUniformBufferObject {
    mat4 model;
    mat4 view;
    mat4 proj;
} mvp_ubo;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inColor;
layout(location = 11) in uint inUidLower;
layout(location = 12) in uint inUidUpper;

layout(location = 0) out vec3 fragColor;
layout(location = 1) out flat uvec2 outUid;

void main() {
    gl_Position = mvp_ubo.proj * mvp_ubo.view * mvp_ubo.model * vec4(inPosition, 1.0);
    fragColor = inColor;
    outUid = uvec2(inUidLower, inUidUpper);
}
