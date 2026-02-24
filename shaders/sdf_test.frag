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

// float map(vec3 p) // old map procedure
// {
//     // 1. Ball (Dynamic from CPU)
//     vec3 ballPos = p - ubo.u_ball.xyz;
//     float sphere = sdSphere(ballPos, ubo.u_ball.w);

//     // 2. Box (Dynamic from CPU)
//     // Rotation based on time
//     float time = ubo.u_screen.z;
//     float s = sin(time);
//     float c = cos(time);
//     mat2 rot = mat2(c, -s, s, c);

//     vec3 boxPos = p - ubo.u_box.xyz;
//     boxPos.xz *= rot; // Rotate the domain
    
//     // Use the .w component as the uniform size for the box
//     float box = sdBox(boxPos, vec3(ubo.u_box.w));

//     // 3. Floor
//     float floorDist = sdPlane(p);

//     // Combine
//     return smin(smin(sphere, box, 0.4), floorDist, 0.2);
// }

float map(vec3 p) //
{
    // Room parameters
    float roomHalfX = 4.0;   // half-width of room in X
    float roomHalfZ = 6.0;   // half-depth of room in Z
    float roomHeight = 3.0;  // height of the walls
    float wallThickness = 0.1;

    // Floor (y = -1 plane from earlier)
    float floorDist = sdPlane(p);

    // Ceiling (optional) at y = roomHeight - 1.0 (so the floor is at -1)
    vec3 ceilP = p - vec3(0.0, roomHeight, 0.0);
    float ceilingDist = sdPlane(-ceilP); // flip plane to face down

    // Left wall: centered at (-roomHalfX, roomHeight/2, 0)
    vec3 leftP = p - vec3(-roomHalfX, roomHeight * 0.5, 0.0);
    float leftWall = sdBox(leftP, vec3(wallThickness, roomHeight * 0.5, roomHalfZ));

    // Right wall: centered at (+roomHalfX, roomHeight/2, 0)
    vec3 rightP = p - vec3(roomHalfX, roomHeight * 0.5, 0.0);
    float rightWall = sdBox(rightP, vec3(wallThickness, roomHeight * 0.5, roomHalfZ));

    // Back wall: centered at (0, roomHeight/2, -roomHalfZ)
    vec3 backP = p - vec3(0.0, roomHeight * 0.5, -roomHalfZ);
    float backWall = sdBox(backP, vec3(roomHalfX, roomHeight * 0.5, wallThickness));

    // Front wall: centered at (0, roomHeight/2, +roomHalfZ)
    vec3 frontP = p - vec3(0.0, roomHeight * 0.5, roomHalfZ);
    float frontWall = sdBox(frontP, vec3(roomHalfX, roomHeight * 0.5, wallThickness));

    // Combine all surfaces using min (sharp intersections)
    float walls = min(min(leftWall, rightWall), min(frontWall, backWall));
    float roomShell = min(min(floorDist, ceilingDist), walls);

    return roomShell;
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
        
        vec3 baseColor = vec3(1.0, 0.5, 0.1);
        vec3 color = (diff * baseColor) + (spec * 0.8);
        color *= exp(-0.05 * t); 
        fragColor = vec4(color + 0.05, 1.0);
    }
    else //Background Color
    {
        fragColor = vec4(0.1, 0.1, 0.15, 1.0); 
    }
}
 //---------------------------extra comments---------------------------
/*
Room size:
Wider room: increase roomHalfX.
Deeper room: increase roomHalfZ.
Taller room: increase roomHeight.
Wall thickness:
Thicker slabs: increase wallThickness.
Open one wall (make a doorway):
Temporarily remove frontWall or backWall from the min:
    float walls = min(leftWall, rightWall); // no front/back
*/