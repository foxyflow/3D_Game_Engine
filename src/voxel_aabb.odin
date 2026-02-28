// voxel_aabb.odin
// Voxel grid + AABB tree (BVH) collision for room walls.
// Pipeline: voxelize walls -> collect AABBs -> build tree -> sphere vs tree (with merge-through).
// Room geometry comes from LevelData (loaded from levels/level1.json).
package main

import "core:math"
import "core:mem"

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

// AABB tree node: either leaf (voxel) or internal (has left/right children)
AABBNode :: struct
{
    box:    AABB,
    left:   i32,  // index into nodes array, -1 if none
    right:  i32,
    wall_id: i32, // -1 = internal node; 0-3 = wall, 4 = floor
}

// Box with wall ID for merge-through-walls
VoxelBox :: struct
{
    aabb:   AABB,
    wall_id: i32,
}

VoxelAABBTree :: struct
{
    grid_nx:     int,
    grid_ny:     int,
    grid_nz:     int,
    grid_origin: [3]f32,  // world-space min corner of grid
    voxel_size:  f32,
    voxels:      []bool,
    wall_ids:    []i32,
    boxes:       [dynamic]VoxelBox,
    nodes:       [dynamic]AABBNode,
}

// Compute grid dimensions from all rooms. Call before voxelize_room.
init_voxel_tree :: proc(level: ^LevelData, allocator := context.allocator) -> VoxelAABBTree
{
    wt := level.wall_thickness
    vs := level.voxel_size
    pad := wt * 2.0

    min_x, max_x: f32 = 1e9, -1e9
    min_z, max_z: f32 = 1e9, -1e9
    max_height: f32 = 0
    floor_y: f32 = -1

    for room_def in level.rooms
    {
        r := room_def.room
        if r.floor_y < floor_y do floor_y = r.floor_y
        if r.height > max_height do max_height = r.height
        rx_min := r.center_x - r.half_x - pad
        rx_max := r.center_x + r.half_x + pad
        rz_min := r.center_z - r.half_z - pad
        rz_max := r.center_z + r.half_z + pad
        if rx_min < min_x do min_x = rx_min
        if rx_max > max_x do max_x = rx_max
        if rz_min < min_z do min_z = rz_min
        if rz_max > max_z do max_z = rz_max
    }

    extent_x := max_x - min_x
    extent_z := max_z - min_z
    extent_y := max_height + pad

    grid_nx := int(extent_x / vs) + 1
    grid_ny := int(extent_y / vs) + 1
    grid_nz := int(extent_z / vs) + 1

    total := grid_nx * grid_ny * grid_nz
    voxels := make([]bool, total, allocator)
    wall_ids := make([]i32, total, allocator)

    return VoxelAABBTree{
        grid_nx     = grid_nx,
        grid_ny     = grid_ny,
        grid_nz     = grid_nz,
        grid_origin = { min_x, floor_y - wt, min_z },
        voxel_size  = vs,
        voxels      = voxels,
        wall_ids    = wall_ids,
    }
}

// Convert grid coords (ix, iy, iz) to flat index. Returns -1 if out of bounds.
voxel_index :: proc(tree: ^VoxelAABBTree, x, y, z: int) -> int
{
    if x < 0 || x >= tree.grid_nx do return -1
    if y < 0 || y >= tree.grid_ny do return -1
    if z < 0 || z >= tree.grid_nz do return -1
    return x * tree.grid_ny * tree.grid_nz + y * tree.grid_nz + z
}

// Convert world position to voxel cell coordinates.
world_to_voxel :: proc(tree: ^VoxelAABBTree, wx, wy, wz: f32) -> (ix, iy, iz: i32)
{
    ox, oy, oz := tree.grid_origin[0], tree.grid_origin[1], tree.grid_origin[2]
    vs := tree.voxel_size
    ix = i32((wx - ox) / vs)
    iy = i32((wy - oy) / vs)
    iz = i32((wz - oz) / vs)
    return
}

// Convert voxel cell (ix, iy, iz) to world-space AABB.
voxel_to_aabb :: proc(tree: ^VoxelAABBTree, ix, iy, iz: int) -> AABB
{
    ox, oy, oz := tree.grid_origin[0], tree.grid_origin[1], tree.grid_origin[2]
    vs := tree.voxel_size
    min_x := ox + f32(ix) * vs
    min_y := oy + f32(iy) * vs
    min_z := oz + f32(iz) * vs
    return AABB{
        min = { min_x, min_y, min_z },
        max = { min_x + vs, min_y + vs, min_z + vs },
    }
}

// Test if two AABBs overlap (used for voxel vs wall).
aabb_overlap :: proc(a, b: AABB) -> bool
{
    if a.min[0] > b.max[0] || a.max[0] < b.min[0] do return false
    if a.min[1] > b.max[1] || a.max[1] < b.min[1] do return false
    if a.min[2] > b.max[2] || a.max[2] < b.min[2] do return false
    return true
}

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
    wt := level.wall_thickness
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
        max = { max_x, floor_y, max_z },
    }
}

// Step 1: For each voxel, check overlap with all rooms' walls and floors. wall_id = room_idx*6 + surface_type.
voxelize_room :: proc(tree: ^VoxelAABBTree, level: ^LevelData)
{
    wt := level.wall_thickness
    level_floor := level_floor_aabb(level)

    for ix := 0; ix < tree.grid_nx; ix += 1
    {
        for iy := 0; iy < tree.grid_ny; iy += 1
        {
            for iz := 0; iz < tree.grid_nz; iz += 1
            {
                vbox := voxel_to_aabb(tree, ix, iy, iz)
                first_surf: i32 = -1
                overlap_count: int = 0

                for room_def, room_idx in level.rooms
                {
                    r := &level.rooms[room_idx].room
                    base := i32(room_idx) * SURFACES_PER_ROOM

                    walls: [4]AABB = {
                        left_wall_aabb(r, wt),
                        right_wall_aabb(r, wt),
                        back_wall_aabb(r, wt),
                        front_wall_aabb(r, wt),
                    }
                    for w in 0 ..< 4
                    {
                        if aabb_overlap(vbox, walls[w])
                        {
                            overlap_count += 1
                            if first_surf < 0 do first_surf = base + i32(w)
                        }
                    }
                    floor_inner := floor_inner_aabb(r, wt)
                    if aabb_overlap(vbox, floor_inner)
                    {
                        overlap_count += 1
                        if first_surf < 0 do first_surf = base + FLOOR_INNER
                    }
                    fo_left, fo_right, fo_back, fo_front := floor_outer_aabb(r, wt)
                    if aabb_overlap(vbox, fo_left)  { overlap_count += 1; if first_surf < 0 do first_surf = base + FLOOR_OUTER }
                    if aabb_overlap(vbox, fo_right) { overlap_count += 1; if first_surf < 0 do first_surf = base + FLOOR_OUTER }
                    if aabb_overlap(vbox, fo_back)  { overlap_count += 1; if first_surf < 0 do first_surf = base + FLOOR_OUTER }
                    if aabb_overlap(vbox, fo_front) { overlap_count += 1; if first_surf < 0 do first_surf = base + FLOOR_OUTER }
                }
                // Fill gaps between rooms: level floor covers full extent, always solid
                if overlap_count == 0 && aabb_overlap(vbox, level_floor)
                {
                    overlap_count = 1
                    first_surf = FLOOR_OUTER  // room 0 floor_outer = solid
                }

                if overlap_count > 0
                {
                    idx := voxel_index(tree, ix, iy, iz)
                    if idx >= 0
                    {
                        tree.voxels[idx] = true
                        // Use first_surf even when overlapping (wall+floor) so merge-through works for walls
                        tree.wall_ids[idx] = first_surf
                    }
                }
            }
        }
    }
}

// Step 2: Build list of VoxelBox (AABB + wall_id) for each occupied voxel.
collect_boxes :: proc(tree: ^VoxelAABBTree)
{
    clear(&tree.boxes)
    for ix := 0; ix < tree.grid_nx; ix += 1
    {
        for iy := 0; iy < tree.grid_ny; iy += 1
        {
            for iz := 0; iz < tree.grid_nz; iz += 1
            {
                idx := voxel_index(tree, ix, iy, iz)
                if idx >= 0 && tree.voxels[idx]
                {
                    append(&tree.boxes, VoxelBox{
                        aabb    = voxel_to_aabb(tree, ix, iy, iz),
                        wall_id = tree.wall_ids[idx],
                    })
                }
            }
        }
    }
}

// Compute bounding AABB that contains both a and b.
aabb_merge :: proc(a, b: AABB) -> AABB
{
    return AABB{
        min = {
            math.min(a.min[0], b.min[0]),
            math.min(a.min[1], b.min[1]),
            math.min(a.min[2], b.min[2]),
        },
        max = {
            math.max(a.max[0], b.max[0]),
            math.max(a.max[1], b.max[1]),
            math.max(a.max[2], b.max[2]),
        },
    }
}

// Recursive BVH build: split by longest axis, partition boxes, recurse.
// Leaf nodes store wall_id; internal nodes have wall_id = -1.
build_tree_rec :: proc(tree: ^VoxelAABBTree, voxboxes: []VoxelBox, allocator: mem.Allocator) -> i32
{
    if len(voxboxes) == 0
    {
        return -1
    }
    if len(voxboxes) == 1
    {
        node_idx := i32(len(tree.nodes))
        append(&tree.nodes, AABBNode{
            box     = voxboxes[0].aabb,
            left    = -1,
            right   = -1,
            wall_id = voxboxes[0].wall_id,
        })
        return node_idx
    }

    // Compute merged AABB of all boxes in this node
    merged := voxboxes[0].aabb
    for i in 1 ..< len(voxboxes)
    {
        merged = aabb_merge(merged, voxboxes[i].aabb)
    }

    // Pick longest axis for split (better tree balance)
    dx := merged.max[0] - merged.min[0]
    dy := merged.max[1] - merged.min[1]
    dz := merged.max[2] - merged.min[2]
    axis: int = 0
    if dy > dx && dy > dz do axis = 1
    if dz > dx && dz > dy do axis = 2

    // Partition: boxes with center < mid go left, else right
    mid := (merged.min[axis] + merged.max[axis]) * 0.5
    left := make([dynamic]VoxelBox, 0, len(voxboxes)/2 + 1, allocator)
    defer delete(left)
    right := make([dynamic]VoxelBox, 0, len(voxboxes)/2 + 1, allocator)
    defer delete(right)

    for vb in voxboxes
    {
        c := (vb.aabb.min[axis] + vb.aabb.max[axis]) * 0.5
        if c < mid
        {
            append(&left, vb)
        }
        else
        {
            append(&right, vb)
        }
    }

    if len(left) == 0
    {
        append(&left, voxboxes[len(voxboxes)-1])
        pop(&right)
    }
    else if len(right) == 0
    {
        append(&right, left[len(left)-1])
        pop(&left)
    }

    left_idx := build_tree_rec(tree, left[:], allocator)
    right_idx := build_tree_rec(tree, right[:], allocator)

    node_idx := i32(len(tree.nodes))
    append(&tree.nodes, AABBNode{ box = merged, left = left_idx, right = right_idx, wall_id = -1 })
    return node_idx
}

// Step 3: Build BVH from tree.boxes. Returns root node index.
build_tree :: proc(tree: ^VoxelAABBTree, allocator: mem.Allocator) -> i32
{
    clear(&tree.nodes)
    if len(tree.boxes) == 0 do return -1
    return build_tree_rec(tree, tree.boxes[:], allocator)
}

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
    inv := 1.0 / dist
    return true, [3]f32{ dx * inv * push_mag, dy * inv * push_mag, dz * inv * push_mag }
}

// Fast overlap test: sphere vs AABB. Used to cull tree branches during traversal.
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

// Traverse BVH: at leaves, test sphere vs AABB. wall_id = room*6 + surface_type.
// Floor outer (type 5): never merge. Floor inner (type 4): match color (same as walls). Walls (0-3): match color.
sphere_vs_tree :: proc(
    tree: ^VoxelAABBTree,
    root: i32,
    center: [3]f32,
    radius: f32,
    player_color: i32,
    surface_colors: [12]i32,
) -> (push: [3]f32)
{
    if root < 0 do return [3]f32{}
    if root >= i32(len(tree.nodes)) do return [3]f32{}

    node := tree.nodes[root]
    if !sphere_intersects_aabb(center, radius, node.box) do return [3]f32{}

    if node.left < 0 && node.right < 0
    {
        wid := node.wall_id
        if wid >= 0 && wid < 12
        {
            surf_type := wid % SURFACES_PER_ROOM
            // Hybrid: skip floor voxels - floor handled by collide_floor_planes (SDF-precise)
            if surf_type == FLOOR_OUTER || surf_type == FLOOR_INNER do return [3]f32{}
            if surf_type < 4
            {
                if player_color == surface_colors[wid] do return [3]f32{}  // walls: match color = merge through
            }
        }
        hit, p := sphere_vs_aabb(center, radius, node.box)
        if hit do return p
        return [3]f32{}
    }

    total_push := [3]f32{}
    n := i32(len(tree.nodes))
    if node.left >= 0 && node.left < n
    {
        p := sphere_vs_tree(tree, node.left, center, radius, player_color, surface_colors)
        total_push[0] += p[0]
        total_push[1] += p[1]
        total_push[2] += p[2]
    }
    if node.right >= 0 && node.right < n
    {
        p := sphere_vs_tree(tree, node.right, center, radius, player_color, surface_colors)
        total_push[0] += p[0]
        total_push[1] += p[1]
        total_push[2] += p[2]
    }
    return total_push
}

// Step 4 (per frame): Iteratively push player out of walls and floors. Up to max_iter passes.
resolve_collision :: proc(
    tree: ^VoxelAABBTree,
    root: i32,
    pos: ^[3]f32,
    radius: f32,
    player_color: i32,
    surface_colors: [12]i32,
    max_iter: int,
)
{
    for _ in 0 ..< max_iter
    {
        push := sphere_vs_tree(tree, root, pos^, radius, player_color, surface_colors)
        if push[0] == 0 && push[1] == 0 && push[2] == 0 do break
        pos[0] += push[0]
        pos[1] += push[1]
        pos[2] += push[2]
    }
}

// Floor plane collision: exact plane test per room + level extent for gaps.
// Merge-through when player color matches floor. Gaps between rooms always solid.
collide_floor_planes :: proc(
    level: ^LevelData,
    pos: ^[3]f32,
    radius: f32,
    player_color: i32,
    surface_colors: [12]i32,
)
{
    dead_zone: f32 = 0.002
    floor_clearance: f32 = 0.04  // keep player slightly above floor (reduces visual sink)
    target_y: f32 = 1e9  // will be set by room or gap

    level_floor := level_floor_aabb(level)
    in_level_xz := pos[0] >= level_floor.min[0] && pos[0] <= level_floor.max[0] && pos[2] >= level_floor.min[2] && pos[2] <= level_floor.max[2]
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

    // Gap between rooms: solid floor, no merge-through
    if !in_any_room && in_level_xz
    {
        target_y = floor_y + radius + floor_clearance
    }

    if target_y < 1e8
    {
        penetration := target_y - pos[1]
        if penetration > dead_zone
        {
            pos[1] += penetration
        }
    }
}
