glslc -O --target-env=vulkan1.0 -fshader-stage=vert vert.glsl -o vert.spv
glslc -O --target-env=vulkan1.0 -fshader-stage=frag frag.glsl -o frag.spv
