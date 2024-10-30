#version 460 core

// precision highp float;

const vec2 vertices[] = {
    {-1.0, -1.0},
    {+3.0, -1.0},
    {-1.0, +3.0},
};

void main() {
    gl_Position = vec4(vertices[gl_VertexIndex], 0.0, 1.0);
}
