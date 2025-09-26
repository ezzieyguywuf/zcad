#version 450

layout(location = 0) in vec3 fragColor;
layout(location = 1) in flat uvec2 outUid;

layout(location = 0) out vec4 outColor;
layout(location = 3) out uvec2 outSurfaceId;

void main() {
  outColor = vec4(fragColor, 1.0);
  outSurfaceId = outUid;
}
