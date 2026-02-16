#version 450
// This extension tells editors "Hey, I'm using Vulkan-specific stuff!"
#extension GL_ARB_separate_shader_objects : enable

void main() {
    // The cast to int helps some pickier extensions/drivers
    int i = int(gl_VertexIndex);
    
    vec2 pos = vec2((i << 1) & 2, i & 2);
    gl_Position = vec4(pos * 2.0 - 1.0, 0.0, 1.0);
} // end of quad.vert