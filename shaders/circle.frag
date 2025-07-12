#version 450

layout(location = 0) in vec3 v_color;
layout(location = 1) in flat uvec2 v_id;

layout(location = 0) out vec4 f_color;
layout(location = 1) out uvec2 outVertexId;

void main() {
  vec2 point = gl_PointCoord - vec2(0.5, 0.5);
  float distance = length(point);
  float alpha = 1 - smoothstep(0.4, 0.49, distance);
  float color = 1 - step(0.5, distance);
  f_color = vec4(color * v_color.r , color * v_color.g, color * v_color.b, alpha);
  outVertexId = v_id;
}

