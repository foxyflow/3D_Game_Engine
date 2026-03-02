// aabb_collision.odin
// Room / wall collision helpers shared by the engine and Jolt.
// - Defines simple axis-aligned boxes (AABB) for room walls, floors and standalone walls.
// - Provides CPU-side collision helpers (player vs walls, projectiles vs walls, floor planes).
// - No voxel grid / BVH anymore: everything is expressed directly in terms of AABBs.
package main

import "core:math"

// Surface indices per room: wall_id = room_idx*6 + surface_type
// surface_type: 0=left, 1=right, 2=back, 3=front, 4=floor_inner, 5=floor_outer
WALL_LEFT   :: 0
WALL_RIGHT  :: 1
WALL_BACK   :: 2
WALL_FRONT  :: 3
FLOOR_INNER :: 4  // only red sinks when floor is red
FLOOR_OUTER :: 5  // solid, never sink
SURFACES_PER_ROOM :: 6

AABB :: struct
{
    min: [3]f32,
    max: [3]f32,
}

// AABB helpers and room-based wall/floor shapes used by collision and Jolt.

// Wall AABBs: take room + wt, offset by room center.
left_wall_aabb  :: proc(r: ^RoomData, wt: f32) -> AABB {
    return AABB{
        min = { r.center_x - r.half_x - wt, r.floor_y, r.center_z - r.half_z },
        max = { r.center_x - r.half_x,      r.floor_y + r.height, r.center_z + r.half_z },
    }
}
right_wall_aabb :: proc(r: ^RoomData, wt: f32) -> AABB {
    return AABB{
        min = { r.center_x + r.half_x,       r.floor_y, r.center_z - r.half_z },
        max = { r.center_x + r.half_x + wt, r.floor_y + r.height, r.center_z + r.half_z },
    }
}
back_wall_aabb  :: proc(r: ^RoomData, wt: f32) -> AABB {
    return AABB{
        min = { r.center_x - r.half_x, r.floor_y, r.center_z - r.half_z - wt },
        max = { r.center_x + r.half_x, r.floor_y + r.height, r.center_z - r.half_z },
    }
}
front_wall_aabb :: proc(r: ^RoomData, wt: f32) -> AABB {
    return AABB{
        min = { r.center_x - r.half_x, r.floor_y, r.center_z + r.half_z },
        max = { r.center_x + r.half_x, r.floor_y + r.height, r.center_z + r.half_z + wt },
    }
}

floor_inner_aabb :: proc(r: ^RoomData, wt: f32) -> AABB {
    return AABB{
        min = { r.center_x - r.half_x, r.floor_y - wt, r.center_z - r.half_z },
        max = { r.center_x + r.half_x, r.floor_y,      r.center_z + r.half_z },
    }
}

floor_outer_aabb :: proc(r: ^RoomData, wt: f32) -> (left, right, back, front: AABB) {
    pad := wt * 2.0
    left  = AABB{ min = { r.center_x - r.half_x - pad, r.floor_y - wt, r.center_z - r.half_z - pad }, max = { r.center_x - r.half_x,      r.floor_y, r.center_z + r.half_z + pad } }
    right = AABB{ min = { r.center_x + r.half_x,       r.floor_y - wt, r.center_z - r.half_z - pad }, max = { r.center_x + r.half_x + pad, r.floor_y, r.center_z + r.half_z + pad } }
    back  = AABB{ min = { r.center_x - r.half_x - pad, r.floor_y - wt, r.center_z - r.half_z - pad }, max = { r.center_x + r.half_x + pad, r.floor_y, r.center_z - r.half_z } }
    front = AABB{ min = { r.center_x - r.half_x - pad, r.floor_y - wt, r.center_z + r.half_z },       max = { r.center_x + r.half_x + pad, r.floor_y, r.center_z + r.half_z + pad } }
    return
}

// Level floor AABB: full extent at floor_y to fill gaps between rooms. Always solid.
level_floor_aabb :: proc(level: ^LevelData) -> AABB
{
    wt  := level.wall_thickness
    pad := wt * 2.0
    min_x, max_x: f32 = 1e9, -1e9
    min_z, max_z: f32 = 1e9, -1e9
    floor_y: f32 = -1

    for room_def in level.rooms
    {
        r := room_def.room
        if r.floor_y < floor_y do floor_y = r.floor_y
        rx_min := r.center_x - r.half_x - pad
        rx_max := r.center_x + r.half_x + pad
        rz_min := r.center_z - r.half_z - pad
        rz_max := r.center_z + r.half_z + pad
        if rx_min < min_x do min_x = rx_min
        if rx_max > max_x do max_x = rx_max
        if rz_min < min_z do min_z = rz_min
        if rz_max > max_z do max_z = rz_max
    }

    return AABB{
        min = { min_x, floor_y - wt, min_z },
        max = { max_x, floor_y,      max_z },
    }
}

// Wall type string for index w (0=left, 1=right, 2=back, 3=front)
wall_type_for_index :: proc(w: int) -> string
{
    switch w
    {
    case 0: return "left"
    case 1: return "right"
    case 2: return "back"
    case 3: return "front"
    case:   return "left"
    }
}

// Collision slit is smaller than visual so ball must squash to fit. 0.55 = collision slit 55% of visual.
COLLISION_SLIT_SCALE :: 0.55

// Sphere vs AABB: find closest point on box to sphere center.
// If distance < radius, return penetration and push vector to resolve.
sphere_vs_aabb :: proc(center: [3]f32, radius: f32, box: AABB) -> (hit: bool, push: [3]f32)
{
    closest_x := math.clamp(center[0], box.min[0], box.max[0])
    closest_y := math.clamp(center[1], box.min[1], box.max[1])
    closest_z := math.clamp(center[2], box.min[2], box.max[2])

    dx := center[0] - closest_x
    dy := center[1] - closest_y
    dz := center[2] - closest_z

    dist_sq := dx*dx + dy*dy + dz*dz
    if dist_sq >= radius * radius do return false, [3]f32{}

    dist := math.sqrt(dist_sq)
    if dist < 0.0001
    {
        // Center inside AABB: push out along shortest penetration axis
        pen_x := (box.max[0] - box.min[0]) * 0.5 - math.abs(center[0] - (box.min[0]+box.max[0])*0.5)
        pen_y := (box.max[1] - box.min[1]) * 0.5 - math.abs(center[1] - (box.min[1]+box.max[1])*0.5)
        pen_z := (box.max[2] - box.min[2]) * 0.5 - math.abs(center[2] - (box.min[2]+box.max[2])*0.5)
        if pen_x <= pen_y && pen_x <= pen_z
        {
            sign: f32 = 1 if center[0] > (box.min[0]+box.max[0])*0.5 else -1
            return true, [3]f32{ (radius + pen_x) * sign, 0, 0 }
        }
        if pen_y <= pen_x && pen_y <= pen_z
        {
            sign: f32 = 1 if center[1] > (box.min[1]+box.max[1])*0.5 else -1
            return true, [3]f32{ 0, (radius + pen_y) * sign, 0 }
        }
        sign: f32 = 1 if center[2] > (box.min[2]+box.max[2])*0.5 else -1
        return true, [3]f32{ 0, 0, (radius + pen_z) * sign }
    }

    push_mag := radius - dist
    inv      := 1.0 / dist
    return true, [3]f32{ dx * inv * push_mag, dy * inv * push_mag, dz * inv * push_mag }
}

// Sphere vs sphere: push to separate. Used for player vs stuck projectiles.
sphere_vs_sphere :: proc(center_a: [3]f32, radius_a: f32, center_b: [3]f32, radius_b: f32) -> (hit: bool, push: [3]f32)
{
    dx := center_b[0] - center_a[0]
    dy := center_b[1] - center_a[1]
    dz := center_b[2] - center_a[2]
    dist_sq := dx*dx + dy*dy + dz*dz
    sum_r   := radius_a + radius_b
    if dist_sq >= sum_r * sum_r || dist_sq < 0.0001 do return false, [3]f32{}

    dist     := math.sqrt(dist_sq)
    push_mag := sum_r - dist
    inv      := 1.0 / dist
    return true, [3]f32{ -dx * inv * push_mag, -dy * inv * push_mag, -dz * inv * push_mag }  // push A away from B
}

// Fast overlap test: sphere vs AABB.
sphere_intersects_aabb :: proc(center: [3]f32, radius: f32, box: AABB) -> bool
{
    closest_x := math.clamp(center[0], box.min[0], box.max[0])
    closest_y := math.clamp(center[1], box.min[1], box.max[1])
    closest_z := math.clamp(center[2], box.min[2], box.max[2])

    dx := center[0] - closest_x
    dy := center[1] - closest_y
    dz := center[2] - closest_z

    return (dx*dx + dy*dy + dz*dz) < radius * radius
}

// Ellipsoid vs AABB via transform space: scale to unit sphere, test, unscale push.
// radii: (rx, ry, rz) - use min 0.05 to avoid div by zero.
ellipsoid_vs_aabb :: proc(center: [3]f32, radii: [3]f32, box: AABB) -> (hit: bool, push: [3]f32)
{
    rx := math.max(radii[0], 0.05)
    ry := math.max(radii[1], 0.05)
    rz := math.max(radii[2], 0.05)

    // Transform to ellipsoid space (ellipsoid becomes unit sphere)
    c_scaled := [3]f32{ center[0] / rx, center[1] / ry, center[2] / rz }
    box_scaled := AABB{
        min = { box.min[0] / rx, box.min[1] / ry, box.min[2] / rz },
        max = { box.max[0] / rx, box.max[1] / ry, box.max[2] / rz },
    }

    ok, p := sphere_vs_aabb(c_scaled, 1.0, box_scaled)
    if !ok do return false, [3]f32{}

    // Unscale push to world space (push was in ellipsoid space)
    return true, [3]f32{ p[0] * rx, p[1] * ry, p[2] * rz }
}

ellipsoid_intersects_aabb :: proc(center: [3]f32, radii: [3]f32, box: AABB) -> bool
{
    rx := math.max(radii[0], 0.05)
    ry := math.max(radii[1], 0.05)
    rz := math.max(radii[2], 0.05)

    c_scaled := [3]f32{ center[0] / rx, center[1] / ry, center[2] / rz }
    box_scaled := AABB{
        min = { box.min[0] / rx, box.min[1] / ry, box.min[2] / rz },
        max = { box.max[0] / rx, box.max[1] / ry, box.max[2] / rz },
    }
    return sphere_intersects_aabb(c_scaled, 1.0, box_scaled)
}

// Collide the player sphere against all walls in the level.
// - Room walls respect merge-through by color (player_color == wall_color => no collision).
// - Standalone walls are always solid (color is visual only for now).
collide_player_with_room_walls :: proc
(
    level          : ^LevelData,
    pos            : ^[3]f32,
    radius         : f32,
    player_color   : i32,
    surface_colors : [18]i32,
    max_iter       : int,
)
{
    wt := level.wall_thickness

    for _ in 0 ..< max_iter
    {
        total_push := [3]f32{}

        // Per-room walls: left / right / back / front.
        for room_idx in 0 ..< len(level.rooms)
        {
            room_def := &level.rooms[room_idx]
            r        := &room_def.room
            base     := room_idx * SURFACES_PER_ROOM

            walls : [4]AABB =
            {
                left_wall_aabb(r, wt),
                right_wall_aabb(r, wt),
                back_wall_aabb(r, wt),
                front_wall_aabb(r, wt),
            }

            for w in 0 ..< 4
            {
                wall_color := surface_colors[base + w]

                // Color match = merge-through for room walls.
                if player_color == wall_color do continue

                if hit, push := sphere_vs_aabb(pos^, radius, walls[w]); hit
                {
                    total_push[0] += push[0]
                    total_push[1] += push[1]
                    total_push[2] += push[2]
                }
            }
        }

        // Standalone walls: arbitrary AABBs defined in level.standalone_walls. Always solid.
        for sw in level.standalone_walls
        {
            aabb := AABB{
                min = { sw.center_x - sw.half_x, sw.center_y - sw.half_y, sw.center_z - sw.half_z },
                max = { sw.center_x + sw.half_x, sw.center_y + sw.half_y, sw.center_z + sw.half_z },
            }

            if hit, push := sphere_vs_aabb(pos^, radius, aabb); hit
            {
                total_push[0] += push[0]
                total_push[1] += push[1]
                total_push[2] += push[2]
            }
        }

        if total_push[0] == 0 && total_push[1] == 0 && total_push[2] == 0 do break

        pos[0] += total_push[0]
        pos[1] += total_push[1]
        pos[2] += total_push[2]
    }
}

// Returns true if projectile sphere overlaps any yellow wall AABB
// (room or standalone). Used to slow down the yellow projectile while "melting".
projectile_in_yellow_rooms :: proc
(
    level          : ^LevelData,
    center         : [3]f32,
    radius         : f32,
    surface_colors : [18]i32,
) -> bool
{
    wt := level.wall_thickness

    // Room walls.
    for room_idx in 0 ..< len(level.rooms)
    {
        room_def := &level.rooms[room_idx]
        r        := &room_def.room
        base     := room_idx * SURFACES_PER_ROOM

        walls: [4]AABB =
        {
            left_wall_aabb(r, wt),
            right_wall_aabb(r, wt),
            back_wall_aabb(r, wt),
            front_wall_aabb(r, wt),
        }

        for w in 0 ..< 4
        {
            if surface_colors[base + w] != WALL_COLOR_YELLOW do continue
            if sphere_intersects_aabb(center, radius, walls[w]) do return true
        }
    }

    // Standalone yellow walls.
    for sw in level.standalone_walls
    {
        if color_string_to_id(sw.color) != WALL_COLOR_YELLOW do continue
        aabb := AABB{
            min = { sw.center_x - sw.half_x, sw.center_y - sw.half_y, sw.center_z - sw.half_z },
            max = { sw.center_x + sw.half_x, sw.center_y + sw.half_y, sw.center_z + sw.half_z },
        }
        if sphere_intersects_aabb(center, radius, aabb) do return true
    }

    return false
}

// Returns (hit, push) for the first non-matching-color wall AABB
// (room or standalone). Used to stick the projectile into walls.
projectile_hits_wall_rooms :: proc
(
    level           : ^LevelData,
    center          : [3]f32,
    radius          : f32,
    projectile_color: i32,
    surface_colors  : [18]i32,
) -> (hit: bool, push: [3]f32)
{
    wt := level.wall_thickness

    // Room walls.
    for room_idx in 0 ..< len(level.rooms)
    {
        room_def := &level.rooms[room_idx]
        r        := &room_def.room
        base     := room_idx * SURFACES_PER_ROOM

        walls: [4]AABB =
        {
            left_wall_aabb(r, wt),
            right_wall_aabb(r, wt),
            back_wall_aabb(r, wt),
            front_wall_aabb(r, wt),
        }

        for w in 0 ..< 4
        {
            wall_color := surface_colors[base + w]

            // Match color = merge-through for walls (projectile passes through same-color walls).
            if projectile_color == wall_color do continue

            if hit, p := sphere_vs_aabb(center, radius, walls[w]); hit
            {
                return true, p
            }
        }
    }

    // Standalone walls.
    for sw in level.standalone_walls
    {
        wall_color := color_string_to_id(sw.color)
        if projectile_color == wall_color do continue

        aabb := AABB{
            min = { sw.center_x - sw.half_x, sw.center_y - sw.half_y, sw.center_z - sw.half_z },
            max = { sw.center_x + sw.half_x, sw.center_y + sw.half_y, sw.center_z + sw.half_z },
        }

        if hit, p := sphere_vs_aabb(center, radius, aabb); hit
        {
            return true, p
        }
    }

    return false, [3]f32{}
}

// Floor plane collision: exact plane test per room + level extent for gaps.
// Merge-through when player color matches floor. Gaps between rooms always solid.
collide_floor_planes :: proc
(
    level          : ^LevelData,
    pos            : ^[3]f32,
    radius         : f32,
    player_color   : i32,
    surface_colors : [18]i32,
    vel_y          : f32 = 0,  // if > 0 (jumping), skip push-down to avoid canceling jump
)
{
    dead_zone      : f32 = 0.002
    floor_clearance: f32 = 0.04  // keep player slightly above floor (reduces visual sink)
    target_y       : f32 = 1e9   // will be set by room or gap

    level_floor := level_floor_aabb(level)
    in_level_xz := pos[0] >= level_floor.min[0] && pos[0] <= level_floor.max[0] &&
                   pos[2] >= level_floor.min[2] && pos[2] <= level_floor.max[2]
    floor_y := level_floor.max[1]  // top of floor plane

    in_any_room := false

    for room_idx in 0 ..< len(level.rooms)
    {
        r := level.rooms[room_idx].room
        if pos[0] < r.center_x - r.half_x || pos[0] > r.center_x + r.half_x do continue
        if pos[2] < r.center_z - r.half_z || pos[2] > r.center_z + r.half_z do continue

        in_any_room = true
        floor_color := surface_colors[room_idx * SURFACES_PER_ROOM + FLOOR_INNER]
        if player_color == floor_color do continue  // merge through

        target_y = floor_y + radius + floor_clearance
        break
    }

    // Gap between rooms: solid floor, no merge-through.
    if !in_any_room && in_level_xz
    {
        target_y = floor_y + radius + floor_clearance
    }

    if target_y < 1e8
    {
        penetration := target_y - pos[1]

        if penetration > dead_zone
        {
            pos[1] += penetration  // push up when below floor
        }
        else if penetration < -dead_zone && vel_y <= 0 && -penetration < 0.08
        {
            pos[1] = target_y  // push down only when slightly floating (squash transition), not when jumping/falling
        }
    }
}

