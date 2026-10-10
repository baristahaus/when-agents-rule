#version 450
layout(location = 0) in vec2 inPos;
layout(location = 1) in vec4 inColor;
layout(push_constant) uniform PC {
    layout(offset = 0)  vec2 scale;
    layout(offset = 8)  vec2 offset;
} pc;
layout(location = 0) out vec4 vColor;
void main() {
    gl_Position = vec4(inPos * pc.scale + pc.offset, 0.0, 1.0);
    vColor = inColor;
}
