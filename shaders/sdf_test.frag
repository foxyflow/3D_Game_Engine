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
    vec4 u_box;        // x: player_color, y: squash_horizontal (pancake), z: squash_vertical (pill)
    vec4 u_cam_pos;    // camera position (xyz)
    vec4 u_cam_forward;// forward basis vector
    vec4 u_cam_right;  // right basis vector
    vec4 u_cam_up;     // up basis vector
    vec4 u_projectile;  // xyz position, w radius (0 = inactive) - active projectile
    vec4 u_projectiles[8]; // stuck projectiles
    vec4 u_debug;       // x: show_collision_wireframe (0 or 1)
} ubo;

// --- Room UBO: room 0 at origin, room 1 at (center_x, center_z) ---
layout(set = 3, binding = 1, std140) uniform RoomBlock
{
    vec4 u_room;        // x: half_x, y: half_z, z: height, w: floor_y (room 0)
    vec4 u_room2;       // x: center_x, y: center_z, z: half_x, w: half_z (room 1)
    vec4 u_room3;       // x: center_x, y: center_z, z: half_x, w: half_z (room 2, Hole Practice)
    vec4 u_room3_extras;// x: floor_color_r2
    vec4 u_extras;      // x: wall_thickness, y: floor_color_r0, z: floor_color_r1, w: use_wall_hue
    vec4 u_wall_colors;  // room 0: left, right, back, front
    vec4 u_wall_colors2; // room 1: left, right, back, front
    vec4 u_wall_colors3; // room 2: left, right, back, front
    vec4 u_light_on;   // room 0: left, right, back, front (0 or 1)
    vec4 u_light_on2;  // room 1: left, right, back, front
    vec4 u_light_on3;  // room 2: always 1
    vec4 u_lighting;   // x: ambient, y: point_brightness, z: point_attenuation, w: switch_visual_radius
    vec4 u_moon_dir;   // xyz: direction (normalized)
    vec4 u_moon;       // rgb: color, w: intensity
    vec4 u_switch_off_0;  // x=off0.x, y=off1.x, z=off2.x, w=off3.x
    vec4 u_switch_off_1;  // x=off0.y, y=off1.y, z=off2.y, w=off3.y
    vec4 u_switch_off_2;  // x=off0.z, y=off1.z, z=off2.z, w=off3.z
    vec4 u_switch_off_3;  // x=off4.x, y=off5.x, z=off6.x, w=off7.x
    vec4 u_switch_off_4;  // x=off4.y, y=off5.y, z=off6.y, w=off7.y
    vec4 u_switch_off_5;  // x=off4.z, y=off5.z, z=off6.z, w=off7.z
    vec4 u_room_gaps_0;   // room 0: left_bottom, left_slit, right_bottom, right_slit
    vec4 u_room_gaps_0b;  // room 0: back_bottom, back_slit, front_bottom, front_slit
    vec4 u_room_gaps_1;   // room 1: left_bottom, left_slit, right_bottom, right_slit
    vec4 u_room_gaps_1b;  // room 1: back_bottom, back_slit, front_bottom, front_slit
    vec4 u_room_gaps_2;   // room 2: left_bottom, left_slit, right_bottom, right_slit
    vec4 u_room_gaps_2b;  // room 2: back_bottom, back_slit, front_bottom, front_slit
    vec4 u_room_gaps_0_hole;   // room 0: left_w, left_h, left_b, right_w
    vec4 u_room_gaps_0_hole2;  // room 0: right_h, right_b, back_w, back_h
    vec4 u_room_gaps_0_hole3;  // room 0: back_b, front_w, front_h, front_b
    vec4 u_room_gaps_1_hole;   // room 1: same
    vec4 u_room_gaps_1_hole2;
    vec4 u_room_gaps_1_hole3;
    vec4 u_room_gaps_2_hole;   // room 2: same
    vec4 u_room_gaps_2_hole2;
    vec4 u_room_gaps_2_hole3;
    vec4 u_room_gaps_0_hole_off;    // room 0: left, right, back, front hole offset (horizontal)
    vec4 u_room_gaps_0_hole_off_y;  // room 0: hole offset Y (vertical)
    vec4 u_room_gaps_1_hole_off;
    vec4 u_room_gaps_1_hole_off_y;
    vec4 u_room_gaps_2_hole_off;
    vec4 u_room_gaps_2_hole_off_y;
    vec4 u_standalone_wall_center; // xyz center, w=color id
    vec4 u_standalone_wall_half;   // xyz half extents
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

// Ellipsoid SDF: r = (rx, ry, rz) radii per axis
float sdEllipsoid(vec3 p, vec3 r)
{
    vec3 k0 = p / r;
    vec3 k1 = p / (r * r);
    float k2 = length(k0);
    float k3 = length(k1);
    return k2 * (k2 - 1.0) / k3;
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

// --- Collision wireframe: distance from point to AABB edges (for debug overlay) ---
float distToSegment(vec3 p, vec3 a, vec3 b)
{
    vec3 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

float distToAABBEdges(vec3 p, vec3 bmin, vec3 bmax)
{
    float mx = bmin.x, my = bmin.y, mz = bmin.z;
    float Mx = bmax.x, My = bmax.y, Mz = bmax.z;
    float d = 1000.0;
    d = min(d, distToSegment(p, vec3(mx, my, mz), vec3(Mx, my, mz)));
    d = min(d, distToSegment(p, vec3(mx, my, mz), vec3(mx, My, mz)));
    d = min(d, distToSegment(p, vec3(mx, my, mz), vec3(mx, my, Mz)));
    d = min(d, distToSegment(p, vec3(Mx, my, mz), vec3(Mx, My, mz)));
    d = min(d, distToSegment(p, vec3(Mx, my, mz), vec3(Mx, my, Mz)));
    d = min(d, distToSegment(p, vec3(mx, My, mz), vec3(Mx, My, mz)));
    d = min(d, distToSegment(p, vec3(mx, My, mz), vec3(mx, My, Mz)));
    d = min(d, distToSegment(p, vec3(mx, my, Mz), vec3(Mx, my, Mz)));
    d = min(d, distToSegment(p, vec3(mx, my, Mz), vec3(mx, My, Mz)));
    d = min(d, distToSegment(p, vec3(Mx, My, mz), vec3(Mx, My, Mz)));
    d = min(d, distToSegment(p, vec3(Mx, my, Mz), vec3(Mx, My, Mz)));
    d = min(d, distToSegment(p, vec3(mx, My, Mz), vec3(Mx, My, Mz)));
    return d;
}

// Minimum distance from p to any collision AABB edge (room walls + standalone). Matches CPU collision boxes.
float minDistToCollisionEdges(vec3 p)
{
    float roomHalfX = room.u_room.x, roomHalfZ = room.u_room.y, roomHeight = room.u_room.z, floorY = room.u_room.w;
    float wt = room.u_extras.x;
    float d = 1000.0;
    // Room 0: 4 walls
    d = min(d, distToAABBEdges(p, vec3(-roomHalfX - wt, floorY, -roomHalfZ), vec3(-roomHalfX, floorY + roomHeight, roomHalfZ)));
    d = min(d, distToAABBEdges(p, vec3(roomHalfX, floorY, -roomHalfZ), vec3(roomHalfX + wt, floorY + roomHeight, roomHalfZ)));
    d = min(d, distToAABBEdges(p, vec3(-roomHalfX, floorY, -roomHalfZ - wt), vec3(roomHalfX, floorY + roomHeight, -roomHalfZ)));
    d = min(d, distToAABBEdges(p, vec3(-roomHalfX, floorY, roomHalfZ), vec3(roomHalfX, floorY + roomHeight, roomHalfZ + wt)));
    // Room 1
    float cx = room.u_room2.x, cz = room.u_room2.y, hx1 = room.u_room2.z, hz1 = room.u_room2.w;
    d = min(d, distToAABBEdges(p, vec3(cx - hx1 - wt, floorY, cz - hz1), vec3(cx - hx1, floorY + roomHeight, cz + hz1)));
    d = min(d, distToAABBEdges(p, vec3(cx + hx1, floorY, cz - hz1), vec3(cx + hx1 + wt, floorY + roomHeight, cz + hz1)));
    d = min(d, distToAABBEdges(p, vec3(cx - hx1, floorY, cz - hz1 - wt), vec3(cx + hx1, floorY + roomHeight, cz - hz1)));
    d = min(d, distToAABBEdges(p, vec3(cx - hx1, floorY, cz + hz1), vec3(cx + hx1, floorY + roomHeight, cz + hz1 + wt)));
    // Room 2 (if active)
    if (room.u_room3.z > 0.001) {
        float cx2 = room.u_room3.x, cz2 = room.u_room3.y, hx2 = room.u_room3.z, hz2 = room.u_room3.w;
        d = min(d, distToAABBEdges(p, vec3(cx2 - hx2 - wt, floorY, cz2 - hz2), vec3(cx2 - hx2, floorY + roomHeight, cz2 + hz2)));
        d = min(d, distToAABBEdges(p, vec3(cx2 + hx2, floorY, cz2 - hz2), vec3(cx2 + hx2 + wt, floorY + roomHeight, cz2 + hz2)));
        d = min(d, distToAABBEdges(p, vec3(cx2 - hx2, floorY, cz2 - hz2 - wt), vec3(cx2 + hx2, floorY + roomHeight, cz2 - hz2)));
        d = min(d, distToAABBEdges(p, vec3(cx2 - hx2, floorY, cz2 + hz2), vec3(cx2 + hx2, floorY + roomHeight, cz2 + hz2 + wt)));
    }
    // Standalone wall
    if (room.u_standalone_wall_half.x > 0.0) {
        vec3 c = room.u_standalone_wall_center.xyz;
        vec3 h = room.u_standalone_wall_half.xyz;
        d = min(d, distToAABBEdges(p, c - h, c + h));
    }
    return d;
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

// SDF for one wall with optional gaps. gapBottom: gap at floor. gapSlit: vertical slit. holeW/H/B: jump-through hole.
// holeOffset: offset along wall (left/right: Z; back/front: X). holeOffsetY: vertical offset (up +, down -).
// slitAxis: 0=X (back/front), 2=Z (left/right).
float sdWallWithGaps(vec3 p, vec3 center, vec3 halfSize, float gapBottom, float gapSlit, float floorY, int slitAxis, float holeW, float holeH, float holeB, float holeOffset, float holeOffsetY)
{
    vec3 h = halfSize;
    vec3 c = center;

    if (gapBottom > 0.001) {
        float remainH = halfSize.y - gapBottom * 0.5;
        if (remainH < 0.01) return 1000.0;
        h.y = remainH;
        c.y = floorY + gapBottom + remainH;
    }

    float wallSdf;
    if (gapSlit < 0.001) {
        wallSdf = sdBox(p - c, h);
    } else {
        // Vertical slit: two wall segments
        float ext = (slitAxis == 0) ? halfSize.x : halfSize.z;
        float segHalf = (ext - gapSlit * 0.5) * 0.5;
        if (segHalf < 0.01) return 1000.0;
        float segOffset = ext * 0.5 + gapSlit * 0.25;
        vec3 halfSeg = h;
        if (slitAxis == 0) halfSeg.x = segHalf;
        else halfSeg.z = segHalf;
        vec3 c1 = c, c2 = c;
        if (slitAxis == 0) { c1.x -= segOffset; c2.x += segOffset; }
        else { c1.z -= segOffset; c2.z += segOffset; }
        wallSdf = min(sdBox(p - c1, halfSeg), sdBox(p - c2, halfSeg));
    }

    // Carve out jump-through hole (max = subtract). holeW = horizontal extent along wall, holeH = vertical.
    // slitAxis 0: back/front walls (extend in X) -> holeOffset in X. slitAxis 2: left/right -> holeOffset in Z.
    // holeOffsetY: moves hole up (+) or down (-) from base position.
    if (holeW > 0.001 && holeH > 0.001) {
        float holeY = floorY + holeB + holeH * 0.5 + holeOffsetY;
        vec3 holeCenter = c;
        holeCenter.y = holeY;
        if (slitAxis == 0) holeCenter.x += holeOffset;
        else holeCenter.z += holeOffset;
        vec3 holeHalf;
        if (slitAxis == 0) {
            holeHalf = vec3(halfSize.x + 0.01, holeH * 0.5, holeW * 0.5);  // depth, height, width
        } else {
            holeHalf = vec3(halfSize.x + 0.01, holeH * 0.5, holeW * 0.5);  // depth, height, width (was bug: hole spanned full wall)
        }
        float holeSdf = sdBox(p - holeCenter, holeHalf);
        wallSdf = max(wallSdf, -holeSdf);
    }
    return wallSdf;
}

// SDF for one room. gaps/gapsB: bottom+slit. hole/hole2/hole3: (left_w,h,b, right_w), (right_h,b, back_w,h), (back_b, front_w,h,b). holeOff/holeOffY: (left, right, back, front).
float sdRoomLocal(vec3 p, float halfX, float halfZ, float height, float floorY, float wallThickness, vec4 gaps, vec4 gapsB, vec4 hole, vec4 hole2, vec4 hole3, vec4 holeOff, vec4 holeOffY)
{
    float floorDist = p.y - floorY;
    float wallCenterY = floorY + height * 0.5;
    float ht = wallThickness * 0.5;

    float leftWall  = sdWallWithGaps(p, vec3(-halfX - ht, wallCenterY, 0.0), vec3(ht, height * 0.5, halfZ), gaps.x, gaps.y, floorY, 2, hole.x, hole.y, hole.z, holeOff.x, holeOffY.x);
    float rightWall = sdWallWithGaps(p, vec3(halfX + ht, wallCenterY, 0.0), vec3(ht, height * 0.5, halfZ), gaps.z, gaps.w, floorY, 2, hole.w, hole2.x, hole2.y, holeOff.y, holeOffY.y);
    float backWall  = sdWallWithGaps(p, vec3(0.0, wallCenterY, -halfZ - ht), vec3(halfX, height * 0.5, ht), gapsB.x, gapsB.y, floorY, 0, hole2.z, hole2.w, hole3.x, holeOff.z, holeOffY.z);
    float frontWall = sdWallWithGaps(p, vec3(0.0, wallCenterY, halfZ + ht), vec3(halfX, height * 0.5, ht), gapsB.z, gapsB.w, floorY, 0, hole3.y, hole3.z, hole3.w, holeOff.w, holeOffY.w);

    float walls = min(min(leftWall, rightWall), min(frontWall, backWall));
    return min(floorDist, walls);
}

// map(p) = distance to nearest surface. Room 0 at origin, room 1 at u_room2.xy.
float map(vec3 p)
{
    float roomHalfX = room.u_room.x, roomHalfZ = room.u_room.y, roomHeight = room.u_room.z, floorY = room.u_room.w;
    float wallThickness = room.u_extras.x;
    float wallCenterY = floorY + roomHeight * 0.5;

    vec4 gaps0 = room.u_room_gaps_0;
    vec4 gaps0b = room.u_room_gaps_0b;
    vec4 gaps1 = room.u_room_gaps_1;
    vec4 gaps1b = room.u_room_gaps_1b;
    vec4 hole0 = room.u_room_gaps_0_hole;
    vec4 hole0b = room.u_room_gaps_0_hole2;
    vec4 hole0c = room.u_room_gaps_0_hole3;
    vec4 holeOff0 = room.u_room_gaps_0_hole_off;
    vec4 holeOff0y = room.u_room_gaps_0_hole_off_y;
    vec4 hole1 = room.u_room_gaps_1_hole;
    vec4 hole1b = room.u_room_gaps_1_hole2;
    vec4 hole1c = room.u_room_gaps_1_hole3;
    vec4 holeOff1 = room.u_room_gaps_1_hole_off;
    vec4 holeOff1y = room.u_room_gaps_1_hole_off_y;
    float d0 = sdRoomLocal(p, roomHalfX, roomHalfZ, roomHeight, floorY, wallThickness, gaps0, gaps0b, hole0, hole0b, hole0c, holeOff0, holeOff0y);

    vec3 p1 = p - vec3(room.u_room2.x, 0.0, room.u_room2.y);
    float d1 = sdRoomLocal(p1, room.u_room2.z, room.u_room2.w, roomHeight, floorY, wallThickness, gaps1, gaps1b, hole1, hole1b, hole1c, holeOff1, holeOff1y);

    float roomShell = min(d0, d1);
    if (room.u_room3.z > 0.001) {
        vec4 gaps2 = room.u_room_gaps_2;
        vec4 gaps2b = room.u_room_gaps_2b;
        vec4 hole2 = room.u_room_gaps_2_hole;
        vec4 hole2b = room.u_room_gaps_2_hole2;
        vec4 hole2c = room.u_room_gaps_2_hole3;
        vec4 holeOff2 = room.u_room_gaps_2_hole_off;
        vec4 holeOff2y = room.u_room_gaps_2_hole_off_y;
        vec3 p2 = p - vec3(room.u_room3.x, 0.0, room.u_room3.y);
        float d2 = sdRoomLocal(p2, room.u_room3.z, room.u_room3.w, roomHeight, floorY, wallThickness, gaps2, gaps2b, hole2, hole2b, hole2c, holeOff2, holeOff2y);
        roomShell = min(roomShell, d2);
    }

    float standaloneWall = 1000.0;
    if (room.u_standalone_wall_half.x > 0.0) {
        standaloneWall = sdBox(p - room.u_standalone_wall_center.xyz, room.u_standalone_wall_half.xyz);
    }

    vec3 playerPos = p - ubo.u_ball.xyz;
    float baseR = ubo.u_ball.w;
    float squashH = ubo.u_box.y;
    float squashV = ubo.u_box.z;
    // Horizontal: compress Y to 25% (pancake). Vertical: compress XZ to 50% (billboard pill)
    vec3 r = vec3(
        baseR * (1.0 - squashV * 0.5),
        baseR * (1.0 - squashH * 0.75),
        baseR * (1.0 - squashV * 0.5)
    );
    r = max(r, vec3(0.1, 0.05, 0.1));
    float playerShape = (squashH > 0.001 || squashV > 0.001)
        ? sdEllipsoid(playerPos, r)
        : sdSphere(playerPos, baseR);

    float geom = min(roomShell, standaloneWall);
    float d = min(geom, playerShape);
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
    float standaloneWall = 1000.0;
    if (room.u_standalone_wall_half.x > 0.0) {
        standaloneWall = sdBox(p - room.u_standalone_wall_center.xyz, room.u_standalone_wall_half.xyz);
    }
    float rightWall0 = sdBox(p - vec3(roomHalfX + ht, wallCenterY, 0.0), vec3(ht, roomHeight * 0.5, roomHalfZ));
    float backWall0  = sdBox(p - vec3(0.0, wallCenterY, -roomHalfZ - ht), vec3(roomHalfX, roomHeight * 0.5, ht));
    float frontWall0 = sdBox(p - vec3(0.0, wallCenterY, roomHalfZ + ht), vec3(roomHalfX, roomHeight * 0.5, ht));
    vec3 p1 = p - vec3(room.u_room2.x, 0.0, room.u_room2.y);
    float hx1 = room.u_room2.z, hz1 = room.u_room2.w;
    float leftWall1  = sdBox(p1 - vec3(-hx1 - ht, wallCenterY, 0.0), vec3(ht, roomHeight * 0.5, hz1));
    float rightWall1 = sdBox(p1 - vec3(hx1 + ht, wallCenterY, 0.0), vec3(ht, roomHeight * 0.5, hz1));
    float backWall1  = sdBox(p1 - vec3(0.0, wallCenterY, -hz1 - ht), vec3(hx1, roomHeight * 0.5, ht));
    float frontWall1 = sdBox(p1 - vec3(0.0, wallCenterY, hz1 + ht), vec3(hx1, roomHeight * 0.5, ht));
    float leftWall2 = 1000.0, rightWall2 = 1000.0, backWall2 = 1000.0, frontWall2 = 1000.0;
    if (room.u_room3.z > 0.001) {
        vec3 p2 = p - vec3(room.u_room3.x, 0.0, room.u_room3.y);
        float hx2 = room.u_room3.z, hz2 = room.u_room3.w;
        leftWall2  = sdBox(p2 - vec3(-hx2 - ht, wallCenterY, 0.0), vec3(ht, roomHeight * 0.5, hz2));
        rightWall2 = sdBox(p2 - vec3(hx2 + ht, wallCenterY, 0.0), vec3(ht, roomHeight * 0.5, hz2));
        backWall2  = sdBox(p2 - vec3(0.0, wallCenterY, -hz2 - ht), vec3(hx2, roomHeight * 0.5, ht));
        frontWall2 = sdBox(p2 - vec3(0.0, wallCenterY, hz2 + ht), vec3(hx2, roomHeight * 0.5, ht));
    }
    float baseR = ubo.u_ball.w;
    float squashH = ubo.u_box.y;
    float squashV = ubo.u_box.z;
    // Horizontal: compress Y to 25% (pancake). Vertical: compress XZ to 50% (billboard pill)
    vec3 r = vec3(
        baseR * (1.0 - squashV * 0.5),
        baseR * (1.0 - squashH * 0.75),
        baseR * (1.0 - squashV * 0.5)
    );
    r = max(r, vec3(0.1, 0.05, 0.1));
    float playerShape = (squashH > 0.001 || squashV > 0.001)
        ? sdEllipsoid(p - ubo.u_ball.xyz, r)
        : sdSphere(p - ubo.u_ball.xyz, baseR);

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
    if (abs(playerShape) < eps) return 10.0;
    if (abs(floorDist) < eps) {
        bool inR0 = abs(p.x) < roomHalfX && abs(p.z) < roomHalfZ;
        bool inR1 = abs(p.x - room.u_room2.x) < hx1 && abs(p.z - room.u_room2.y) < hz1;
        bool inR2 = room.u_room3.z > 0.001 && abs(p.x - room.u_room3.x) < room.u_room3.z && abs(p.z - room.u_room3.y) < room.u_room3.w;
        if (inR2) return 13.0;  // floor room 2
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
    if (abs(leftWall2) < eps) return 14.0;
    if (abs(rightWall2) < eps) return 15.0;
    if (abs(backWall2) < eps) return 16.0;
    if (abs(frontWall2) < eps) return 17.0;
    if (abs(standaloneWall) < eps) return 18.0;
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
        
        vec3 lightPos[12];
        lightPos[0] = vec3(-roomHalfX - ht, wallCenterY, 0.0);           // r0 left
        lightPos[1] = vec3(roomHalfX + ht, wallCenterY, 0.0);          // r0 right
        lightPos[2] = vec3(0.0, wallCenterY, -roomHalfZ - ht);         // r0 back
        lightPos[3] = vec3(0.0, wallCenterY, roomHalfZ + ht);          // r0 front
        float cx = room.u_room2.x, cz = room.u_room2.y, hx1 = room.u_room2.z, hz1 = room.u_room2.w;
        lightPos[4] = vec3(cx - hx1 - ht, wallCenterY, cz);             // r1 left
        lightPos[5] = vec3(cx + hx1 + ht, wallCenterY, cz);             // r1 right
        lightPos[6] = vec3(cx, wallCenterY, cz - hz1 - ht);             // r1 back
        lightPos[7] = vec3(cx, wallCenterY, cz + hz1 + ht);             // r1 front
        float cx2 = room.u_room3.x, cz2 = room.u_room3.y, hx2 = room.u_room3.z, hz2 = room.u_room3.w;
        lightPos[8] = vec3(cx2 - hx2 - ht, wallCenterY, cz2);             // r2 left
        lightPos[9] = vec3(cx2 + hx2 + ht, wallCenterY, cz2);             // r2 right
        lightPos[10] = vec3(cx2, wallCenterY, cz2 - hz2 - ht);             // r2 back
        lightPos[11] = vec3(cx2, wallCenterY, cz2 + hz2 + ht);             // r2 front
        
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
        for (int i = 0; i < 12; i++) {
            if (i >= 8 && room.u_room3.z < 0.001) continue;  // skip room 2 lights when disabled
            float on = (i < 4) ? room.u_light_on[i] : (i < 8) ? room.u_light_on2[i - 4] : room.u_light_on3[i - 8];
            if (on > 0.5) {
                vec3 toLight = lightPos[i] - p;
                float dist = length(toLight);
                vec3 lightDir = toLight / max(dist, 0.001);
                float atten = pointBright / (1.0 + pointAtten * dist * dist);
                float wc = (i < 4) ? room.u_wall_colors[i] : (i < 8) ? room.u_wall_colors2[i - 4] : room.u_wall_colors3[i - 8];
                vec3 lightTint = useWallHue ? wallColorFromId(wc) : vec3(1.0);
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
        } else if (mat == 13.0) {
            float fc = room.u_room3_extras.x;  // floor room 2
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
        } else if (mat >= 14.0 && mat <= 17.0) {
            float wc = (mat < 14.5) ? room.u_wall_colors3.x : (mat < 15.5) ? room.u_wall_colors3.y : (mat < 16.5) ? room.u_wall_colors3.z : room.u_wall_colors3.w;
            if (wc < 0.5) baseColor = vec3(0.8, 0.2, 0.2);
            else if (wc < 1.5) baseColor = vec3(0.2, 0.8, 0.3);
            else if (wc < 2.5) baseColor = vec3(0.2, 0.4, 0.9);
            else baseColor = vec3(0.95, 0.85, 0.2);
        } else if (mat == 11.0) {
            baseColor = vec3(1.0, 0.75, 0.0);  // bright yellow/orange projectile
            lightAccum = vec3(1.0);  // full brightness (emissive glow)
        } else if (mat == 18.0) {
            float wc = room.u_standalone_wall_center.w;
            if (wc < 0.5) baseColor = vec3(0.8, 0.2, 0.2);
            else if (wc < 1.5) baseColor = vec3(0.2, 0.8, 0.3);
            else if (wc < 2.5) baseColor = vec3(0.2, 0.4, 0.9);
            else baseColor = vec3(0.95, 0.85, 0.2);
        } else if (mat == 12.0) {
            baseColor = vec3(0.5, 0.5, 0.55);  // switch: gray/metallic
        }
        
        vec3 color = (lightAccum * baseColor) + (spec * 0.8);
        color *= exp(-0.05 * t);
        if (mat == 11.0) color += vec3(0.4, 0.3, 0.0);  // emissive glow so projectile stands out

        // Collision wireframe overlay (toggle with C): wall AABB edges + player ball collision outline
        if (ubo.u_debug.x > 0.5) {
            vec3 wireColor = vec3(0.2, 1.0, 0.3);

            // World collision AABBs (walls + standalone)
            float edgeDist = minDistToCollisionEdges(p);
            float wireframeThickness = 0.02;
            if (edgeDist < wireframeThickness) {
                float t_w = 1.0 - smoothstep(0.0, wireframeThickness, edgeDist);
                color = mix(color, wireColor, t_w);
            }

            // Ball collision wireframe: spherical shell at player radius (approx Jolt collision)
            if (mat == 10.0) {
                float d_ball = abs(length(p - ubo.u_ball.xyz) - ubo.u_ball.w);
                float ballThickness = 0.03;
                if (d_ball < ballThickness) {
                    float t_b = 1.0 - smoothstep(0.0, ballThickness, d_ball);
                    color = mix(color, wireColor, max(t_b, 0.7));
                }
            }
        }
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