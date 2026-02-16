#version 450

layout(location = 0) out vec4 fragColor;
layout(location = 0) in vec2 fragCoord; // normalized -1 to 1 coordinates

// The "Golden" Sphere Function
float sdSphere(vec3 p, float r) {
    return length(p) - r;
}

void main() {
    vec3 ro = vec3(0, 0, -3);          // Ray Origin (Camera)
    vec3 rd = normalize(vec3(fragCoord, 1)); // Ray Direction
    
    float t = 0.0; // Distance traveled
    for(int i = 0; i < 64; i++) {
        vec3 p = ro + rd * t;
        float d = sdSphere(p, 1.0); // Check distance to 1-unit sphere
        if(d < 0.001) {
            // WE HIT IT! Draw white.
            fragColor = vec4(1.0, 1.0, 1.0, 1.0);
            return;
        }
        t += d; // "Safe Jump" forward by d
        if(t > 10.0) break; // Missed everything
    }
    
    fragColor = vec4(0.1, 0.1, 0.1, 1.0); // Background dark grey
}