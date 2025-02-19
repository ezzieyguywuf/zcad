#version 450

layout(location = 0) in vec3 v_color;

layout(location = 0) out vec4 f_color;

void main() {
  vec2 point = gl_PointCoord - vec2(0.5, 0.5);
  float distance = length(point);
  float alpha = 1 - smoothstep(0.4, 0.49, distance);
  float color =  step(0.5, distance);
  f_color = vec4(color, color, color, alpha);
}

