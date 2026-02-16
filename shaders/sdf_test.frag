#version 450
#extension GL_ARB_separate_shader_objects : enable

// The output color for the current pixel
layout(location = 0) out vec4 fragColor;
//length(p) - r is the sphere rendering formula, this is the math behind it: d= sqrt(x^2 + y^2 + z^2) - r
/*
In GLSL, we write that as length(p) - radius. If the length of the vector p is greater than the radius, the distance is positive (outside).
 If it's less, it's negative (inside)
*/
// SDL3 GPU uniform: set=3, binding=0 for fragment uniforms
// (Matches SDL_PushGPUFragmentUniformData slot 0)
layout(set = 3, binding = 0, std140) uniform TimeBlock {
    float u_time;  // Your time value
} ubo;  // Instance name (use ubo. below)


// --- Signed Distance Functions (SDFs) ---

// Returns distance to a sphere. 0 at surface, >0 outside, <0 inside.
float sdSphere(vec3 p, float r) { 
    return length(p) - r; 
}

// Returns distance to an infinite flat plane sitting at y = -1.0
float sdPlane(vec3 p) { 
    return p.y + 1.0; 
}

// k is the "smoothing" factor. 
// Higher k = more melting/blending. Lower k = sharper transition.
float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * h * k * (1.0 / 6.0);
}

// --- The World Function ---
float map(vec3 p) {
    // This will make the sphere bounce up and down over time
    float bounce = sin(ubo.u_time * 3.0) * 0.5; // Bounce between -0.5 and +0.5 using sin.
    // To move an object UP, you subtract from its position vector.
    // Here, we subtract -0.5 from Y (which is like adding 0.5).
    // This pushes the sphere DOWN toward the floor (y = -1.0).
    vec3 spherePos = p - vec3(0.0, bounce, 0.0); 
    
    float sphere = sdSphere(spherePos, 1.0); // Use our shifted position
    float floor  = sdPlane(p);               // The floor stays at p.y + 1.0
    
    // Melt them together! 
    // 0.5 is the smoothing radius.
    return smin(sphere, floor, 0.5); 
}

// --- Normal + Lighting Math ---

// Calculates the "Normal" (surface direction) by checking the slope of the distance
vec3 calcNormal(vec3 p) {
    vec2 e = vec2(0.001, 0.0);
    return normalize(vec3(
        map(p + e.xyy) - map(p - e.xyy),
        map(p + e.yxy) - map(p - e.yxy),
        map(p + e.yyx) - map(p - e.yyx)
    ));
}

void main() {
    // 1. Setup Screen Coordinates
    vec2 screen_res = vec2(800, 600);
    // Normalize coordinates so (0,0) is center, and Y is flipped to be "up"
    vec2 uv = (gl_FragCoord.xy * 2.0 - screen_res) / screen_res.y;
    uv.y = -uv.y; 

    // 2. Setup the Camera
    vec3 ro = vec3(0, 0, -3);            // Ray Origin (Camera Position)
    vec3 rd = normalize(vec3(uv, 1.0));  // Ray Direction (Forward into screen)
    
    // 3. Raymarching Loop (The "Engine") // Sphere tracing algorithm: we march along the ray in steps equal to the distance to the nearest surface, until we hit something or go too far.
    float t = 0.0; // Total distance traveled by the ray
    for(int i = 0; i < 80; i++) {
        vec3 p = ro + rd * t;      // Current point along the ray
        float d = map(p);          // How far is the closest object?
        
        if(d < 0.001) break;       // HIT: We are close enough to the surface
        if(t > 20.0) break;        // MISS: We traveled too far into the void
        
        t += d;                    // "March" forward by the safe distance
    }

    // 4. Shading and Coloring
    if(t < 20.0)
    {
        // We hit an object!
        vec3 p = ro + rd * t;      // The exact point of impact
        vec3 n = calcNormal(p);    // Which way is the surface facing?
        
        // Simple Diffuse Lighting (Dot product of Normal and Light Direction)
        vec3 lightDir = normalize(vec3(1.0, 2.0, -1.0));
        float diff = max(dot(n, lightDir), 0.0);
        
        // Final color: (Lighting * BaseColor) + Ambient light
        vec3 baseColor = vec3(0.7647, 0.2353, 0.5333); // Purple
        fragColor = vec4(vec3(diff) * baseColor + 0.1, 1.0);
        
    } else
    {
        // We hit nothing (The Background)
        fragColor = vec4(0.2549, 0.0392, 0.3647, 1.0); 
    }
}