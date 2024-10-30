#version 460 core

// precision highp float;

// layout(binding = 0) uniform UniformBufferObject {
//     vec2 extent;
//     float time;
//     vec2 mouse;
// };
layout(location = 0) out vec4 color;

void main() {
    vec2 extent = vec2(1920, 1080);
    float time = 0.1;
    vec2 uv = gl_FragCoord.xy / extent;
    color = vec4(0.5 + 0.5 * cos(time + uv.xyx + vec3(0.0, 2.0, 4.0)), 1.0);
}
