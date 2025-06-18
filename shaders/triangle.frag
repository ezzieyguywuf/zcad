#version 450

layout(location = 0) in vec3 v_color;
layout(location = 1) in flat uvec2 v_uid;

layout(location = 0) out vec4 f_color;
layout(location = 1) out uvec2 f_uid;

void main() {
    f_color = vec4(v_color, 1.0);
    f_uid = v_uid;
}
