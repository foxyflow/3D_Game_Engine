// sdf_test.frag
// SDF raymarcher: floor, 4 walls, player sphere. Colors by material (merge-through walls).
#version 450
#extension GL_ARB_separate_shader_objects : enable

layout(location = 0) out vec4 fragColor;

// --- UBO (matches Odin SceneData) ---
layout(set = 3, binding = 0, std140) uniform SceneBlock
{
    vec4 u_screen;     // x: width, y: height, z: time, w: unused
    vec4 u_ball;       // player: xyz position, w radius
    vec4 u_box;        // x: player_color (0=Red, 1=Blue, 2=Green, 3=Yellow)
    vec4 u_cam_pos;    // camera position (xyz)
    vec4 u_cam_forward;// forward basis vector
    vec4 u_cam_right;  // right basis vector
    vec4 u_cam_up;     // up basis vector
    vec4 u_projectile;  // xyz position, w radius (0 = inactive) - active projectile
    vec4 u_projectiles[8]; // stuck projectiles
} ubo;

// --- Room UBO: room 0 at origin, room 1 at (center_x, center_z) ---
layout(set = 3, binding = 1, std140) uniform RoomBlock
{
    vec4 u_room;        // x: half_x, y: half_z, z: height, w: floor_y (room 0)
    vec4 u_room2;       // x: center_x, y: center_z, z: half_x, w: half_z (room 1)
    vec4 u_extras;      // x: wall_thickness, y: floor_color_r0, z: floor_color_r1, w: use_wall_hue
    vec4 u_wall_colors;  // room 0: left, right, back, front
    vec4 u_wall_colors2; // room 1: left, right, back, front
    vec4 u_light_on;   // room 0: left, right, back, front (0 or 1)
    vec4 u_light_on2;  // room 1: left, right, back, front
    vec4 u_lighting;   // x: ambient, y: point_brightness, z: point_attenuation, w: switch_visual_radius
    vec4 u_moon_dir;   // xyz: direction (normalized)
    vec4 u_moon;       // rgb: color, w: intensity
    vec4 u_switch_off_0;  // x=off0.x, y=off1.x, z=off2.x, w=off3.x
    vec4 u_switch_off_1;  // x=off0.y, y=off1.y, z=off2.y, w=off3.y
    vec4 u_switch_off_2;  // x=off0.z, y=off1.z, z=off2.z, w=off3.z
    vec4 u_switch_off_3;  // x=off4.x, y=off5.x, z=off6.x, w=off7.x
    vec4 u_switch_off_4;  // x=off4.y, y=off5.y, z=off6.y, w=off7.y
    vec4 u_switch_off_5;  // x=off4.z, y=off5.z, z=off6.z, w=off7.z
} room;

// --- SDF Primitives ---
// Signed distance: <0 inside, =0 on surface, >0 outside (distance to surface)
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

// Wall color from color ID (0=R,1=G,2=B,3=Y)
vec3 wallColorFromId(float c)
{
    if (c < 0.5) return vec3(0.8, 0.2, 0.2);
    if (c < 1.5) return vec3(0.2, 0.8, 0.3);
    if (c < 2.5) return vec3(0.2, 0.4, 0.9);
    return vec3(0.95, 0.85, 0.2);
}

// SDF for one room at origin with given params
float sdRoomLocal(vec3 p, float halfX, float halfZ, float height, float floorY, float wallThickness)
{
    float floorDist = p.y - floorY;
    float wallCenterY = floorY + height * 0.5;
    float ht = wallThickness * 0.5;
    float leftWall  = sdBox(p - vec3(-halfX - ht, wallCenterY, 0.0), vec3(ht, height * 0.5, halfZ));
    float rightWall = sdBox(p - vec3(halfX + ht, wallCenterY, 0.0), vec3(ht, height * 0.5, halfZ));
    float backWall  = sdBox(p - vec3(0.0, wallCenterY, -halfZ - ht), vec3(halfX, height * 0.5, ht));
    float frontWall = sdBox(p - vec3(0.0, wallCenterY, halfZ + ht), vec3(halfX, height * 0.5, ht));
    float walls = min(min(leftWall, rightWall), min(frontWall, backWall));
    return min(floorDist, walls);
}

// map(p) = distance to nearest surface. Room 0 at origin, room 1 at u_room2.xy.
float map(vec3 p)
{
    float roomHalfX = room.u_room.x, roomHalfZ = room.u_room.y, roomHeight = room.u_room.z, floorY = room.u_room.w;
    float wallThickness = room.u_extras.x;
    float wallCenterY = floorY + roomHeight * 0.5;

    float d0 = sdRoomLocal(p, roomHalfX, roomHalfZ, roomHeight, floorY, wallThickness);

    vec3 p1 = p - vec3(room.u_room2.x, 0.0, room.u_room2.y);
    float d1 = sdRoomLocal(p1, room.u_room2.z, room.u_room2.w, roomHeight, floorY, wallThickness);

    float roomShell = min(d0, d1);

    vec3 playerPos = p - ubo.u_ball.xyz;
    float playerSphere = sdSphere(playerPos, ubo.u_ball.w);

    float d = min(roomShell, playerSphere);
    if (ubo.u_projectile.w > 0.0) {
        d = min(d, sdSphere(p - ubo.u_projectile.xyz, ubo.u_projectile.w));
    }
    for (int i = 0; i < 8; i++) {
        if (ubo.u_projectiles[i].w > 0.0) {
            d = min(d, sdSphere(p - ubo.u_projectiles[i].xyz, ubo.u_projectiles[i].w));
        }
    }
    // Switch spheres on wall surfaces (material 12). Base + offset from JSON.
    vec3 switchPos[8];
    switchPos[0] = vec3(-roomHalfX, wallCenterY, 0.0) + vec3(room.u_switch_off_0.x, room.u_switch_off_1.x, room.u_switch_off_2.x);
    switchPos[1] = vec3(roomHalfX, wallCenterY, 0.0) + vec3(room.u_switch_off_0.y, room.u_switch_off_1.y, room.u_switch_off_2.y);
    switchPos[2] = vec3(0.0, wallCenterY, -roomHalfZ) + vec3(room.u_switch_off_0.z, room.u_switch_off_1.z, room.u_switch_off_2.z);
    switchPos[3] = vec3(0.0, wallCenterY, roomHalfZ) + vec3(room.u_switch_off_0.w, room.u_switch_off_1.w, room.u_switch_off_2.w);
    float cx = room.u_room2.x, cz = room.u_room2.y, hx1 = room.u_room2.z, hz1 = room.u_room2.w;
    switchPos[4] = vec3(cx - hx1, wallCenterY, cz) + vec3(room.u_switch_off_3.x, room.u_switch_off_4.x, room.u_switch_off_5.x);
    switchPos[5] = vec3(cx + hx1, wallCenterY, cz) + vec3(room.u_switch_off_3.y, room.u_switch_off_4.y, room.u_switch_off_5.y);
    switchPos[6] = vec3(cx, wallCenterY, cz - hz1) + vec3(room.u_switch_off_3.z, room.u_switch_off_4.z, room.u_switch_off_5.z);
    switchPos[7] = vec3(cx, wallCenterY, cz + hz1) + vec3(room.u_switch_off_3.w, room.u_switch_off_4.w, room.u_switch_off_5.w);
    float switchR = room.u_lighting.w;
    if (switchR < 0.01) switchR = 0.15;
    for (int i = 0; i < 8; i++) {
        d = min(d, sdSphere(p - switchPos[i], switchR));
    }
    return d;
}

// getHitMaterial: 0=floor r0, 1-4=walls r0, 5=floor r1, 6-9=walls r1, 10=player, 11=projectile, 12=switch.
float getHitMaterial(vec3 p)
{
    float roomHalfX = room.u_room.x, roomHalfZ = room.u_room.y, roomHeight = room.u_room.z;
    float floorY = room.u_room.w, wallThickness = room.u_extras.x;
    float wallCenterY = floorY + roomHeight * 0.5;
    float ht = wallThickness * 0.5;
    float floorDist = p.y - floorY;
    float eps = 0.01;
    float leftWall0  = sdBox(p - vec3(-roomHalfX - ht, wallCenterY, 0.0), vec3(ht, roomHeight * 0.5, roomHalfZ));
    float rightWall0 = sdBox(p - vec3(roomHalfX + ht, wallCenterY, 0.0), vec3(ht, roomHeight * 0.5, roomHalfZ));
    float backWall0  = sdBox(p - vec3(0.0, wallCenterY, -roomHalfZ - ht), vec3(roomHalfX, roomHeight * 0.5, ht));
    float frontWall0 = sdBox(p - vec3(0.0, wallCenterY, roomHalfZ + ht), vec3(roomHalfX, roomHeight * 0.5, ht));
    vec3 p1 = p - vec3(room.u_room2.x, 0.0, room.u_room2.y);
    float hx1 = room.u_room2.z, hz1 = room.u_room2.w;
    float leftWall1  = sdBox(p1 - vec3(-hx1 - ht, wallCenterY, 0.0), vec3(ht, roomHeight * 0.5, hz1));
    float rightWall1 = sdBox(p1 - vec3(hx1 + ht, wallCenterY, 0.0), vec3(ht, roomHeight * 0.5, hz1));
    float backWall1  = sdBox(p1 - vec3(0.0, wallCenterY, -hz1 - ht), vec3(hx1, roomHeight * 0.5, ht));
    float frontWall1 = sdBox(p1 - vec3(0.0, wallCenterY, hz1 + ht), vec3(hx1, roomHeight * 0.5, ht));
    float playerSphere = sdSphere(p - ubo.u_ball.xyz, ubo.u_ball.w);

    // Switch spheres (check before walls - they're on the surface)
    vec3 switchPos[8];
    switchPos[0] = vec3(-roomHalfX, wallCenterY, 0.0) + vec3(room.u_switch_off_0.x, room.u_switch_off_1.x, room.u_switch_off_2.x);
    switchPos[1] = vec3(roomHalfX, wallCenterY, 0.0) + vec3(room.u_switch_off_0.y, room.u_switch_off_1.y, room.u_switch_off_2.y);
    switchPos[2] = vec3(0.0, wallCenterY, -roomHalfZ) + vec3(room.u_switch_off_0.z, room.u_switch_off_1.z, room.u_switch_off_2.z);
    switchPos[3] = vec3(0.0, wallCenterY, roomHalfZ) + vec3(room.u_switch_off_0.w, room.u_switch_off_1.w, room.u_switch_off_2.w);
    float cx = room.u_room2.x, cz = room.u_room2.y;
    switchPos[4] = vec3(cx - hx1, wallCenterY, cz) + vec3(room.u_switch_off_3.x, room.u_switch_off_4.x, room.u_switch_off_5.x);
    switchPos[5] = vec3(cx + hx1, wallCenterY, cz) + vec3(room.u_switch_off_3.y, room.u_switch_off_4.y, room.u_switch_off_5.y);
    switchPos[6] = vec3(cx, wallCenterY, cz - hz1) + vec3(room.u_switch_off_3.z, room.u_switch_off_4.z, room.u_switch_off_5.z);
    switchPos[7] = vec3(cx, wallCenterY, cz + hz1) + vec3(room.u_switch_off_3.w, room.u_switch_off_4.w, room.u_switch_off_5.w);
    float switchR = room.u_lighting.w;
    if (switchR < 0.01) switchR = 0.15;
    for (int i = 0; i < 8; i++) {
        if (abs(sdSphere(p - switchPos[i], switchR)) < eps) return 12.0;
    }
    if (ubo.u_projectile.w > 0.0) {
        if (abs(sdSphere(p - ubo.u_projectile.xyz, ubo.u_projectile.w)) < eps) return 11.0;
    }
    for (int i = 0; i < 8; i++) {
        if (ubo.u_projectiles[i].w > 0.0) {
            if (abs(sdSphere(p - ubo.u_projectiles[i].xyz, ubo.u_projectiles[i].w)) < eps) return 11.0;
        }
    }
    if (abs(playerSphere) < eps) return 10.0;
    if (abs(floorDist) < eps) {
        bool inR0 = abs(p.x) < roomHalfX && abs(p.z) < roomHalfZ;
        bool inR1 = abs(p.x - room.u_room2.x) < hx1 && abs(p.z - room.u_room2.y) < hz1;
        if (inR1) return 5.0;
        return 0.0;
    }
    if (abs(leftWall0) < eps) return 1.0;
    if (abs(rightWall0) < eps) return 2.0;
    if (abs(backWall0) < eps) return 3.0;
    if (abs(frontWall0) < eps) return 4.0;
    if (abs(leftWall1) < eps) return 6.0;
    if (abs(rightWall1) < eps) return 7.0;
    if (abs(backWall1) < eps) return 8.0;
    if (abs(frontWall1) < eps) return 9.0;
    return 0.0;  // default
}

// Finite-difference normal from SDF gradient.
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
    // NDC-like UV from pixel coords (-1..1 on short axis)
    vec2 res = ubo.u_screen.xy; 
    vec2 uv = (gl_FragCoord.xy * 2.0 - res) / res.y;
    uv.y = -uv.y; 
    
    // Build ray: ro = origin, rd = direction from camera basis
    vec3 ro = ubo.u_cam_pos.xyz;
    vec3 cam_forward = normalize(ubo.u_cam_forward.xyz);
    vec3 cam_right   = normalize(ubo.u_cam_right.xyz);
    vec3 cam_up      = normalize(ubo.u_cam_up.xyz);

    vec3 rd = normalize(cam_forward + uv.x * cam_right + uv.y * cam_up);
    
    // Sphere tracing: step along ray by SDF distance until hit or max distance
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
        
        // Point lights: one per wall, positions from room params
        float roomHalfX = room.u_room.x, roomHalfZ = room.u_room.y, roomHeight = room.u_room.z, floorY = room.u_room.w;
        float wallThickness = room.u_extras.x;
        float ht = wallThickness * 0.5;
        float wallCenterY = floorY + roomHeight * 0.5;
        
        vec3 lightPos[8];
        lightPos[0] = vec3(-roomHalfX - ht, wallCenterY, 0.0);           // r0 left
        lightPos[1] = vec3(roomHalfX + ht, wallCenterY, 0.0);          // r0 right
        lightPos[2] = vec3(0.0, wallCenterY, -roomHalfZ - ht);         // r0 back
        lightPos[3] = vec3(0.0, wallCenterY, roomHalfZ + ht);          // r0 front
        float cx = room.u_room2.x, cz = room.u_room2.y, hx1 = room.u_room2.z, hz1 = room.u_room2.w;
        lightPos[4] = vec3(cx - hx1 - ht, wallCenterY, cz);             // r1 left
        lightPos[5] = vec3(cx + hx1 + ht, wallCenterY, cz);             // r1 right
        lightPos[6] = vec3(cx, wallCenterY, cz - hz1 - ht);             // r1 back
        lightPos[7] = vec3(cx, wallCenterY, cz + hz1 + ht);             // r1 front
        
        float ambient = room.u_lighting.x;
        if (ambient < 0.001) ambient = 0.02;
        float pointBright = room.u_lighting.y;
        if (pointBright < 0.001) pointBright = 1.0;
        float pointAtten = room.u_lighting.z;
        if (pointAtten < 0.001) pointAtten = 0.3;
        bool useWallHue = room.u_extras.w > 0.5;
        
        // Moonlight: soft directional light (cool blue tint)
        vec3 moonDir = normalize(room.u_moon_dir.xyz);
        vec3 moonColor = room.u_moon.rgb;
        float moonIntensity = room.u_moon.w;
        float moonDiff = max(dot(n, moonDir), 0.0) * moonIntensity;
        
        // Accumulate lighting as vec3 for colored point lights (wall hue)
        vec3 lightAccum = vec3(ambient) + moonDiff * moonColor;
        for (int i = 0; i < 8; i++) {
            float on = (i < 4) ? room.u_light_on[i] : room.u_light_on2[i - 4];
            if (on > 0.5) {
                vec3 toLight = lightPos[i] - p;
                float dist = length(toLight);
                vec3 lightDir = toLight / max(dist, 0.001);
                float atten = pointBright / (1.0 + pointAtten * dist * dist);
                vec3 lightTint = useWallHue ? wallColorFromId((i < 4) ? room.u_wall_colors[i] : room.u_wall_colors2[i - 4]) : vec3(1.0);
                lightAccum += max(dot(n, lightDir), 0.0) * atten * lightTint;
            }
        }
        
        vec3 viewDir = normalize(ro - p);
        vec3 reflectDir = reflect(-moonDir, n);
        float spec = pow(max(dot(viewDir, reflectDir), 0.0), 32.0);
        
        // Material colors: floor from u_extras.y, walls from u_wall_colors, player from u_box.x
        float mat = getHitMaterial(p);
        vec3 baseColor = vec3(1.0, 0.5, 0.1);  // default
        // Color IDs: 0=Red, 1=Green, 2=Blue, 3=Yellow (matches main.odin WALL_COLOR_*)
        if (mat == 0.0) {
            float fc = room.u_extras.y;
            if (fc < 0.5) baseColor = vec3(0.8, 0.2, 0.2);
            else if (fc < 1.5) baseColor = vec3(0.2, 0.8, 0.3);
            else if (fc < 2.5) baseColor = vec3(0.2, 0.4, 0.9);
            else baseColor = vec3(0.95, 0.85, 0.2);
        } else if (mat == 5.0) {
            float fc = room.u_extras.z;  // floor room 1
            if (fc < 0.5) baseColor = vec3(0.8, 0.2, 0.2);
            else if (fc < 1.5) baseColor = vec3(0.2, 0.8, 0.3);
            else if (fc < 2.5) baseColor = vec3(0.2, 0.4, 0.9);
            else baseColor = vec3(0.95, 0.85, 0.2);
        } else if (mat == 10.0) {
            float pc = ubo.u_box.x;
            if (pc < 0.5) baseColor = vec3(0.9, 0.2, 0.2);      // Red
            else if (pc < 1.5) baseColor = vec3(0.2, 0.8, 0.3);   // Green
            else if (pc < 2.5) baseColor = vec3(0.2, 0.4, 0.9);   // Blue
            else baseColor = vec3(0.95, 0.85, 0.2);               // Yellow
            lightAccum = max(lightAccum, vec3(0.6));  // player stays visible in dark areas
        } else if (mat >= 1.0 && mat <= 4.0) {
            float wc = (mat < 1.5) ? room.u_wall_colors.x : (mat < 2.5) ? room.u_wall_colors.y : (mat < 3.5) ? room.u_wall_colors.z : room.u_wall_colors.w;
            if (wc < 0.5) baseColor = vec3(0.8, 0.2, 0.2);
            else if (wc < 1.5) baseColor = vec3(0.2, 0.8, 0.3);
            else if (wc < 2.5) baseColor = vec3(0.2, 0.4, 0.9);
            else baseColor = vec3(0.95, 0.85, 0.2);
        } else if (mat >= 6.0 && mat <= 9.0) {
            float wc = (mat < 6.5) ? room.u_wall_colors2.x : (mat < 7.5) ? room.u_wall_colors2.y : (mat < 8.5) ? room.u_wall_colors2.z : room.u_wall_colors2.w;
            if (wc < 0.5) baseColor = vec3(0.8, 0.2, 0.2);
            else if (wc < 1.5) baseColor = vec3(0.2, 0.8, 0.3);
            else if (wc < 2.5) baseColor = vec3(0.2, 0.4, 0.9);
            else baseColor = vec3(0.95, 0.85, 0.2);
        } else if (mat == 11.0) {
            baseColor = vec3(1.0, 0.75, 0.0);  // bright yellow/orange projectile
            lightAccum = vec3(1.0);  // full brightness (emissive glow)
        } else if (mat == 12.0) {
            baseColor = vec3(0.5, 0.5, 0.55);  // switch: gray/metallic
        }
        
        vec3 color = (lightAccum * baseColor) + (spec * 0.8);
        color *= exp(-0.05 * t);
        if (mat == 11.0) color += vec3(0.4, 0.3, 0.0);  // emissive glow so projectile stands out
        fragColor = vec4(color, 1.0);
    }
    else  // Miss: background
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

/*
Key for understanding the SDF shader, these names are used like this:

sd (prefix in function names)
Signed Distance. Used in sdSphere, sdBox, sdPlane. Each function returns the signed distance from a point to a shape: negative inside, zero on the surface, positive outside.
a, b (in smin)
The two distance values being blended. a and b are the distances from the same point to two different shapes. smin(a, b, k) combines them into a smooth blend instead of a sharp min(a, b).
k (in smin)
Kernel / smoothing factor. Controls how strong the blend is. Larger k = more blending; smaller k = sharper transition. It sets the width of the smooth region between the two surfaces.
h (in smin)
Helper / height. An intermediate value in the polynomial smooth-min formula. It’s a weight in [0, 1] that depends on how close a and b are. Used to compute the smooth blend.
e (in calcNormal)
Epsilon. A small offset (e.g. 0.001) for finite-difference normal estimation. The normal is approximated by sampling map() at p ± e along each axis. Too small = numerical noise; too large = inaccurate normals.
r (in sdSphere)
Radius. The sphere’s radius.
b (in sdBox)
Box half-extents. The half-size of the box along each axis (half-width, half-height, half-depth). The box is centered at the origin and extends from -b to +b.
ro
Ray origin. The start of the ray (camera position). The ray is ro + t * rd.
rd
Ray direction. The normalized direction of the ray. Each pixel gets a ray from ro in direction rd.
t
Travel / time along the ray. The distance along the ray from ro. The point on the ray is ro + rd * t. In sphere tracing, t is increased by the SDF value at each step.
p
Point. A 3D position in world space. Used as the argument to SDFs (map(p), sdSphere(p, r)) and for the hit point (p = ro + rd * t).
q (in sdBox)
Query point in box space. After shifting by the box center, q = abs(p) - b is the distance from the point to the box faces. Used to compute the box SDF.
*/