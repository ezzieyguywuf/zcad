#version 450

layout(binding = 0) uniform UniformBufferObject {
    mat4 model;
    mat4 view;
    mat4 proj;
} ubo;

layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec3 a_color;

layout(location = 0) out vec3 v_color;
layout(location = 1) out uvec2 v_id;

void main() {
    gl_Position = ubo.proj * ubo.view * ubo.model * vec4(a_pos, 1.0);
    gl_PointSize = 15.0f;
    v_color = a_color;
    v_id.x = 1;
    v_id.y = 1;
}

