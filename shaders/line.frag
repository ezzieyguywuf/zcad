#version 450

layout(location = 0) in vec4 v_color;
layout(location = 1) in flat uvec2 v_uid;

layout(location = 0) out vec4 f_color;
layout(location = 2) out uvec2 f_uid;

void main() {
    f_color = v_color;
    f_uid = v_uid;
}
