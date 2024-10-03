#version 460 core

// precision highp float;

out vec2 coords;

const vec2 vertices[4] = {
    {-1., -1.},
    {-1., +1.},
    {+1., -1.},
    {+1., +1.},
};

void main() {
    gl_Position = vec4(vertices[gl_VertexID], 0., 1.);
    coords = vertices[gl_VertexID];
}
