
#version 450

layout(location = 0) in vec4 v_color;

layout(location = 0) out vec4 f_color;
layout(location = 2) out uvec2 f_id;

void main() {
    f_color = v_color;
    f_id = uvec2(1, 0);
}
