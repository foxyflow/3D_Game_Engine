#version 450
#extension GL_ARB_separate_shader_objects : enable

layout(location = 0) out vec4 fragColor;

// --- PACKED MEMORY LAYOUT (Matches Odin [4]f32) ---
// This uniform block is the GPU-side view of the SceneData struct in Odin.
// In Vulkan/GLSL terms this is a Uniform Buffer Object (UBO).
// The std140 layout rule means:
// - everything is aligned and padded in a predictable way
// - as long as SceneData in Odin follows the same packing, the values
//   will line up 1:1 with these vec4s.
layout(set = 3, binding = 0, std140) uniform SceneBlock
{
    vec4 u_screen; // x: width, y: height, z: time, w: unused
    vec4 u_ball;   // xyz: position, w: radius
    vec4 u_box;    // xyz: position, w: size
} ubo;

// --- SDF Primitives ---
// Each function returns a signed distance:
// - < 0 : the point is inside the shape
// - = 0 : exactly on the surface
// - > 0 : outside, and the value is the distance to the surface
float sdSphere(vec3 p, float r)
{ 
    return length(p) - r; 
}

float sdBox(vec3 p, vec3 b)
{
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float sdPlane(vec3 p)
{ 
    return p.y + 1.0; 
}

float smin(float a, float b, float k)
{
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * h * k * (1.0 / 6.0);
}

// --- The World Function ---
// This is the \"scene\" function for the ray marcher.
// Given a point in 3D space, it returns the distance to the nearest surface.
float map(vec3 p)
{
    // 1. Ball (Dynamic from CPU)
    vec3 ballPos = p - ubo.u_ball.xyz;
    float sphere = sdSphere(ballPos, ubo.u_ball.w);

    // 2. Box (Dynamic from CPU)
    // Rotation based on time
    float time = ubo.u_screen.z;
    float s = sin(time);
    float c = cos(time);
    mat2 rot = mat2(c, -s, s, c);

    vec3 boxPos = p - ubo.u_box.xyz;
    boxPos.xz *= rot; // Rotate the domain
    
    // Use the .w component as the uniform size for the box
    float box = sdBox(boxPos, vec3(ubo.u_box.w));

    // 3. Floor
    float floorDist = sdPlane(p);

    // Combine
    return smin(smin(sphere, box, 0.4), floorDist, 0.2);
}

vec3 calcNormal(vec3 p)
{
    vec2 e = vec2(0.001, 0.0);
    return normalize(vec3(
        map(p + e.xyy) - map(p - e.xyy),
        map(p + e.yxy) - map(p - e.yxy),
        map(p + e.yyx) - map(p - e.yyx)
    ));
}

void main()
{
    // --- FIX: Read resolution from the packed vector ---
    vec2 res = ubo.u_screen.xy; 
    
    vec2 uv = (gl_FragCoord.xy * 2.0 - res) / res.y;
    uv.y = -uv.y; 

    vec3 ro = vec3(0, 1, -5);
    vec3 rd = normalize(vec3(uv, 1.2)); 
    
    float t = 0.0;
    for(int i = 0; i < 100; i++)
    {
        float d = map(ro + rd * t);
        if(d < 0.001 || t > 20.0) break;
        t += d;
    }

    if(t < 20.0)
    {
        vec3 p = ro + rd * t;
        vec3 n = calcNormal(p);
        vec3 lightDir = normalize(vec3(1.0, 3.0, -2.0));
        float diff = max(dot(n, lightDir), 0.0);
        
        vec3 viewDir = normalize(ro - p);
        vec3 reflectDir = reflect(-lightDir, n);
        float spec = pow(max(dot(viewDir, reflectDir), 0.0), 32.0);
        
        vec3 baseColor = vec3(0.1, 0.4, 0.8);
        vec3 color = (diff * baseColor) + (spec * 0.8);
        color *= exp(-0.05 * t); 
        fragColor = vec4(color + 0.05, 1.0);
    }
    else
    {
        fragColor = vec4(0.02, 0.02, 0.05, 1.0); 
    }
}
 //---------------------------old unpacked code but with comments---------------------------
// #version 450
// #extension GL_ARB_separate_shader_objects : enable

// // The output color for the current pixel
// layout(location = 0) out vec4 fragColor;
// //length(p) - r is the sphere rendering formula, this is the math behind it: d= sqrt(x^2 + y^2 + z^2) - r
// /*
// In GLSL, we write that as length(p) - radius. If the length of the vector p is greater than the radius, the distance is positive (outside).
//  If it's less, it's negative (inside)
// */
// // SDL3 GPU uniform: set=3, binding=0 for fragment uniforms
// // (Matches SDL_PushGPUFragmentUniformData slot 0)
// layout(set = 3, binding = 0, std140) uniform SceneBlock {
//     float u_time;  // time value
//     float u_width; // of rectangle
//     float u_height; // of rectangle
//     float u_ball_size; // size of the ball // no padding needed.
// } ubo;  // Instance name (use ubo. below)

// // --- Primitives and Operations -----------------------------------------------
// // --- Signed Distance Functions (SDFs) ---

// // Returns distance to a sphere. 0 at surface, >0 outside, <0 inside.
// float sdSphere(vec3 p, float r) { 
//     return length(p) - r; 
// }

// float sdBox(vec3 p, vec3 b) {
//   vec3 q = abs(p) - b;
//   return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
// }

// // Returns distance to an infinite flat plane sitting at y = -1.0
// float sdPlane(vec3 p) { 
//     return p.y + 1.0; 
// }

// // k is the "smoothing" factor. 
// // Higher k = more melting/blending. Lower k = sharper transition.
// float smin(float a, float b, float k) {
//     float h = max(k - abs(a - b), 0.0) / k;
//     return min(a, b) - h * h * h * k * (1.0 / 6.0);
// }

// // --- The World Function ---------------------------------------
// float map(vec3 p) {
//     // 1. Moving the Sphere across the X-axis
//     // sin(time) moves between -1 and 1. Multiply by 2.5 to sweep from -2.5 to 2.5.
//     float moveX = sin(ubo.u_time * 2.0) * 2.5; 
//     vec3 spherePos = p - vec3(moveX, 0.0, 0.0); 
//     float sphere = sdSphere(spherePos, 0.6); // Slightly smaller sphere

//     // 2. The Box at the Center (0,0,0)
//     float s = sin(ubo.u_time);
//     float c = cos(ubo.u_time);
//     mat2 rot = mat2(c, -s, s, c);
    
//     vec3 boxPos = p - vec3(0.1882, 0.9373, 0.0392); // Center the box
//     boxPos.xz *= rot; // Keep it spinning
//     float box = sdBox(boxPos, vec3(0.8784, 0.102, 0.8941)); // A nice sized cube

//     // 3. The Floor
//     float floorDist = sdPlane(p); 
    
//     // --- COMBINATION ---
    
//     // Use smin if you want them to "melt" together as they pass through
//     // Use min if you want them to stay distinct shapes
//     float shapes = smin(sphere, box, 0.4); 
    
//     // Melt the shapes into the floor
//     return smin(shapes, floorDist, 0.2); 
// }

// // --- Normal + Lighting Math ---

// // Calculates the "Normal" (surface direction) by checking the slope of the distance
// vec3 calcNormal(vec3 p) {
//     vec2 e = vec2(0.001, 0.0);
//     return normalize(vec3(
//         map(p + e.xyy) - map(p - e.xyy),
//         map(p + e.yxy) - map(p - e.yxy),
//         map(p + e.yyx) - map(p - e.yyx)
//     ));
// }



// void main() {
//     // 1. Setup Screen Coordinates
//     // Dynamic Resolution Correction rather than hardcoding 800x600, we can use the uniform values passed from the CPU to get the actual screen resolution.
//     vec2 res = vec2(ubo.u_width, ubo.u_height);
//     // Normalize coordinates so (0,0) is center, and Y is flipped to be "up"
//     vec2 uv = (gl_FragCoord.xy * 2.0 - res) / res.y; // res = screen res (This keeps the aspect ratio correct regardless of screen size)
//     uv.y = -uv.y; 

//     // 2. Setup the Camera
//     vec3 ro = vec3(0, 1, -5);            // Ray Origin (Camera Position)
//     vec3 rd = normalize(vec3(uv, 1.2));  // Ray Direction (Forward into screen)
    
//     // 3. Raymarching Loop (The "Engine") // Sphere tracing algorithm: we march along the ray in steps equal to the distance to the nearest surface, until we hit something or go too far.
// float t = 0.0;
//     for(int i = 0; i < 100; i++) {
//         float d = map(ro + rd * t);
//         if(d < 0.001 || t > 20.0) break;
//         t += d;
//     }

//     // 4. Shading and Coloring
// if(t < 20.0) {
//         vec3 p = ro + rd * t;
//         vec3 n = calcNormal(p);
//         vec3 lightDir = normalize(vec3(1.0, 3.0, -2.0));
        
//         // 1. Diffuse (Matte)
//         float diff = max(dot(n, lightDir), 0.0);
        
//         // 2. Specular (Shiny glint)
//         vec3 viewDir = normalize(ro - p);
//         vec3 reflectDir = reflect(-lightDir, n);
//         float spec = pow(max(dot(viewDir, reflectDir), 0.0), 32.0); // 32 = shininess
        
//         vec3 baseColor = vec3(0.1, 0.4, 0.8); // Deep Blue
//         vec3 color = (diff * baseColor) + (spec * 0.8); // Add the white glint
        
//         // Simple fog/depth shading
//         color *= exp(-0.05 * t); 
        
//         fragColor = vec4(color + 0.05, 1.0);
//     } else {
//         fragColor = vec4(0.02, 0.02, 0.05, 1.0); 
//     }
// }