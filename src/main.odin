// main.odin
// 3D SDF raymarcher with voxel AABB tree collision and merge-through-walls.
// Controls: WASD move (camera-relative), Space jump, arrows orbit, R/G/B/Y change color.
// Edit mode (JSON edit_mode:true): Q/E roll, CTRL/ALT camera height. Game mode: WASD + arrows only.
package main

import sdl "vendor:sdl3"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"

// --- Shader Loading ---
// Compile .frag to .spv before running: glslangValidator --target-env vulkan1.1 -V shaders/sdf_test.frag -o shaders/sdf_test.frag.spv
// This program is our minimal \"engine shell\" that:
// - boots SDL3 and the GPU device
// - sends a small block of scene data to the fragment shader every frame
// - draws a full‑screen triangle that the SDF ray marcher shades
VERT_SRC :: #load("../shaders/quad.vert.spv")
FRAG_SRC :: #load("../shaders/sdf_test.frag.spv")

// SceneData is the CPU‑side description of what we send to the GPU each frame.
// In graphics terms this is a Uniform Buffer Object (UBO):
// - We fill out this struct on the CPU.
// - SDL3 copies its raw bytes into a GPU uniform buffer.
// - The GLSL shader has a matching layout (see SceneBlock in sdf_test.frag).
// std140 just means the fields are tightly and predictably packed in memory.
// If you change this layout, you must mirror the change in the GLSL UBO.
SceneData :: struct
{
    screen:     [4]f32, // [width, height, time, _unused]
    ball:       [4]f32, // player: [pos_x, pos_y, pos_z, radius]
    box:        [4]f32, // [player_color 0/1/2/3, _unused, _unused, _unused]
    cam_pos:    [4]f32, // camera code: [x, y, z, _unused]
    cam_forward:[4]f32, // camera code: forward basis vector
    cam_right:  [4]f32, // camera code: right   basis vector
    cam_up:     [4]f32, // camera code: up      basis vector
}

// RoomData is a separate struct (not in UBO) for level geometry. Loaded from JSON.
RoomData :: struct
{
    center_x: f32,
    center_z: f32,
    half_x:   f32,
    half_z:   f32,
    height:   f32,
    floor_y:  f32,
}

RoomDef :: struct
{
    label: string,
    room:  RoomData,
    floor: FloorDef,
    walls: [dynamic]WallDef,
}

// WallDef: each wall has type (left/right/back/front) and color string.
WallDef :: struct
{
    type:  string,
    color: string,
}

// FloorDef: floor color for merge-through (red fury sinks through when matching).
FloorDef :: struct
{
    color: string,
}

// PlayerDef: loaded from JSON "player" section. Optional; defaults used if missing.
PlayerDef :: struct
{
    color:        string,
    spawn_x:      f32,
    spawn_z:      f32,
    spawn_height: f32,  // units above floor_y; default 3.0 if 0 or missing
}

// LevelData: whole level in one struct. Loaded from levels/level1.json.
LevelData :: struct
{
    wall_thickness: f32,
    voxel_size:     f32,
    edit_mode:      bool,  // true = full 6-axis camera (Q/E/CTRL/ALT), false = game controls only (WASD + arrows)
    player:         PlayerDef,
    rooms:          [dynamic]RoomDef,
}

// RoomBlock: separate UBO for room params. Room 0 at origin, room 1 at center.
RoomBlock :: struct
{
    room:         [4]f32, // [half_x, half_z, height, floor_y] room 0
    room2:        [4]f32, // [center_x, center_z, half_x, half_z] room 1
    extras:       [4]f32, // x=wall_thickness, y=floor_color_r0, z=floor_color_r1
    wall_colors:  [4]f32, // room 0: [left, right, back, front]
    wall_colors2: [4]f32, // room 1: [left, right, back, front]
}

// Color IDs for merge-through-walls. String -> ID mapping.
WALL_COLOR_RED    :: 0
WALL_COLOR_GREEN   :: 1
WALL_COLOR_BLUE  :: 2
WALL_COLOR_YELLOW :: 3

color_string_to_id :: proc(s: string) -> i32
{
    switch s
    {
    case "red":    return WALL_COLOR_RED
    case "green":  return WALL_COLOR_GREEN
    case "blue":   return WALL_COLOR_BLUE
    case "yellow": return WALL_COLOR_YELLOW
    case:          return WALL_COLOR_RED
    }
}

// Wall type string -> index (0=left, 1=right, 2=back, 3=front)
wall_type_to_index :: proc(s: string) -> i32
{
    switch s
    {
    case "left":  return 0
    case "right": return 1
    case "back":  return 2
    case "front": return 3
    case:         return 0
    }
}

// Safe key check: avoids crash if keys slice is empty or scancode out of bounds.
key_pressed :: proc(keys: []bool, sc: sdl.Scancode) -> bool
{
    idx := int(sc)
    if idx < 0 || idx >= len(keys) do return false
    return keys[idx]
}

load_level :: proc(path: string, allocator := context.allocator) -> (level: LevelData, ok: bool)
{
    data, read_ok := os.read_entire_file(path, allocator)
    defer delete(data)
    if !read_ok
    {
        fmt.eprintln("Failed to read level:", path)
        return
    }

    err := json.unmarshal(data, &level, .JSON, allocator)
    if err != nil
    {
        fmt.eprintln("Failed to parse level JSON:", path, err)
        return
    }
    if len(level.rooms) == 0
    {
        fmt.eprintln("Level has no rooms:", path)
        return
    }
    ok = true
    return
}

// ------------------------------- Player --------------------------------

Player :: struct
{
    pos:              [3]f32, // world position (center of sphere)
    vel_y:            f32,    // vertical velocity (gravity + jump)
    radius:           f32,    // visual radius (for SDF rendering)
    collision_radius: f32,    // collision radius (smaller for tighter feel)
    color:            i32,    // 0=Red, 1=Blue, 2=Green (merge-through when matches wall)
}

// ------------------------------- Camera --------------------------------

Camera :: struct
{
    pos:     [3]f32, // camera world position
    forward: [3]f32, // basis: direction camera is looking
    right:   [3]f32, // basis: local +X
    up:      [3]f32, // basis: local +Y

    yaw:   f32, // rotation around world up (Y axis)
    pitch: f32, // rotation around local X (look up/down)
    roll:  f32, // roll around view direction
}

vec3_normalize :: proc(v: [3]f32) -> [3]f32
{
    x := v[0]
    y := v[1]
    z := v[2]

    len_sq := x*x + y*y + z*z
    if len_sq <= 0.0
    {
        return v
    }

    inv_len := 1.0 / math.sqrt(len_sq)
    return [3]f32{ x * inv_len, y * inv_len, z * inv_len }
}

vec3_cross :: proc(a, b: [3]f32) -> [3]f32
{
    return [3]f32{
        a[1]*b[2] - a[2]*b[1],
        a[2]*b[0] - a[0]*b[2],
        a[0]*b[1] - a[1]*b[0],
    }
}

// Rebuild camera basis vectors from yaw/pitch/roll.
camera_rebuild_basis :: proc(cam: ^Camera)
{
    // Build a forward vector from yaw and pitch
    cy := math.cos(cam.yaw)
    sy := math.sin(cam.yaw)
    cp := math.cos(cam.pitch)
    sp := math.sin(cam.pitch)

    forward := [3]f32{
        sy * cp,
        sp,
        cy * cp,
    }
    forward = vec3_normalize(forward)

    world_up := [3]f32{ 0.0, 1.0, 0.0 }

    // Build right and up from world up and forward
    right := vec3_cross(world_up, forward)
    right = vec3_normalize(right)

    up := vec3_cross(forward, right)
    up = vec3_normalize(up)

    // Apply roll: rotate right/up around the forward axis
    if cam.roll != 0.0
    {
        cr := math.cos(cam.roll)
        sr := math.sin(cam.roll)

        // newRight  = right * cos(r) + up * sin(r)
        // newUp     = -right * sin(r) + up * cos(r)
        new_right := [3]f32{
            right[0]*cr + up[0]*sr,
            right[1]*cr + up[1]*sr,
            right[2]*cr + up[2]*sr,
        }
        new_up := [3]f32{
            -right[0]*sr + up[0]*cr,
            -right[1]*sr + up[1]*cr,
            -right[2]*sr + up[2]*cr,
        }

        right = vec3_normalize(new_right)
        up    = vec3_normalize(new_up)
    }

    cam.forward = forward
    cam.right   = right
    cam.up      = up
}

camera_move :: proc(cam: ^Camera, dir: [3]f32, amount: f32)
{
    cam.pos[0] += dir[0] * amount
    cam.pos[1] += dir[1] * amount
    cam.pos[2] += dir[2] * amount
}

main :: proc()
{
    fmt.eprintln("[Engine] Starting...")
    // --- SDL3 + GPU Init ---
    if !sdl.Init({.VIDEO})
    {
        fmt.eprintln("SDL Init Failed:", sdl.GetError())
        return
    }
    defer sdl.Quit()

    window := sdl.CreateWindow("Voxel AABB Tree SDF Engine", 1280, 720, {})
    if window == nil
    {
        fmt.eprintln("Window Failed:", sdl.GetError())
        return
    }
    defer sdl.DestroyWindow(window)

    gpu := sdl.CreateGPUDevice({.SPIRV}, true, nil)
    if gpu == nil
    {
        fmt.eprintln("GPU Device Failed:", sdl.GetError())
        return
    }
    defer sdl.DestroyGPUDevice(gpu)

    if !sdl.ClaimWindowForGPUDevice(gpu, window)
    {
        fmt.eprintln("GPU Claim Failed:", sdl.GetError())
        return
    }
    fmt.eprintln("[Engine] SDL + GPU init OK")

    // --- Shader Creation ---
    // Create the GPU shader objects from the pre‑compiled SPIR‑V blobs.
    // These are long‑lived objects; we create them once and reuse them every frame.
    vert_shader_info := sdl.GPUShaderCreateInfo{
        code        = raw_data(VERT_SRC),
        code_size   = uint(len(VERT_SRC)),
        entrypoint  = "main",
        format      = {.SPIRV},
        stage       = .VERTEX,
        props       = 0,
    }
    vert_shader := sdl.CreateGPUShader(gpu, vert_shader_info)
    if vert_shader == nil
    {
        fmt.eprintln("Vertex Shader Failed:", sdl.GetError())
        return
    }

    frag_shader_info := sdl.GPUShaderCreateInfo{
        code        = raw_data(FRAG_SRC),
        code_size   = uint(len(FRAG_SRC)),
        entrypoint  = "main",
        format      = {.SPIRV},
        stage       = .FRAGMENT,
        num_uniform_buffers = 2, // SceneBlock + RoomBlock
        props       = 0,
    }
    frag_shader := sdl.CreateGPUShader(gpu, frag_shader_info)
    if frag_shader == nil
    {
        fmt.eprintln("Fragment Shader Failed:", sdl.GetError())
        return
    }

    // --- Pipeline Creation ---
    // A graphics pipeline describes how vertices and fragments are processed.
    // Here we build a very simple pipeline:
    // - one color target (the swapchain image)
    // - a full‑screen triangle as input
    // - our SDF fragment shader as the only fragment stage
    pip_info := sdl.GPUGraphicsPipelineCreateInfo{
        target_info = {
            num_color_targets = 1,
            color_target_descriptions = &sdl.GPUColorTargetDescription{
                format = sdl.GetGPUSwapchainTextureFormat(gpu, window),
            },
        },
        vertex_shader = vert_shader,
        fragment_shader = frag_shader,
        primitive_type = .TRIANGLELIST,
    }
    pipeline := sdl.CreateGPUGraphicsPipeline(gpu, pip_info)
    if pipeline == nil
    {
        fmt.eprintln("Pipeline Failed:", sdl.GetError())
        return
    }
    fmt.eprintln("[Engine] Shaders + pipeline OK")

    // --- Level Load ---
    level, level_ok := load_level("levels/level1.json")
    if !level_ok
    {
        fmt.eprintln("Failed to load level, using defaults")
        level = LevelData{
            wall_thickness = 0.25,
            voxel_size     = 0.25,
            rooms          = {},
        }
        append(&level.rooms, RoomDef{
            label = "Main Room",
            room  = RoomData{ center_x = 0, center_z = 0, half_x = 4, half_z = 6, height = 3, floor_y = -1 },
            floor = FloorDef{ color = "red" },
            walls = {},
        })
        append(&level.rooms[0].walls, WallDef{ "left",  "red" })
        append(&level.rooms[0].walls, WallDef{ "right", "red" })
        append(&level.rooms[0].walls, WallDef{ "back",  "red" })
        append(&level.rooms[0].walls, WallDef{ "front", "blue" })
    }
    fmt.eprintln("[Engine] Level loaded:", len(level.rooms), "rooms")
    defer {
        for r in level.rooms do delete(r.walls)
        delete(level.rooms)
    }

    // Surface colors: room_idx*6 + [left, right, back, front, floor_inner, floor_outer]. Max 2 rooms = 12.
    surface_colors: [12]i32 = { 0, 0, 0, 1, 0, -1, 0, 0, 0, 1, 0, -1 }
    for room_def, room_idx in level.rooms
    {
        base := room_idx * 6
        for w in room_def.walls
        {
            idx := wall_type_to_index(w.type)
            if idx >= 0 && idx < 4 do surface_colors[base + int(idx)] = color_string_to_id(w.color)
        }
        surface_colors[base + 4] = color_string_to_id(room_def.floor.color != "" ? room_def.floor.color : "red")
    }
    floor_y: f32 = -1.0
    if len(level.rooms) > 0 do floor_y = level.rooms[0].room.floor_y

    // --- Player Init (from JSON player section, or defaults) ---
    player_color := color_string_to_id(level.player.color != "" ? level.player.color : "red")
    collision_radius: f32 = 0.2
    spawn_height: f32 = level.player.spawn_height if level.player.spawn_height > 0 else 3.0
    rest_y_init := floor_y + spawn_height
    player := Player{
        pos              = { level.player.spawn_x, rest_y_init, level.player.spawn_z },
        vel_y            = 0.0,
        radius           = 0.5,
        collision_radius = collision_radius,
        color            = player_color,
    }

    // --- Voxel AABB Tree (collision) ---
    tree := init_voxel_tree(&level)
    defer delete(tree.voxels)
    defer delete(tree.wall_ids)
    defer mem.delete_dynamic_array(tree.boxes)
    defer mem.delete_dynamic_array(tree.nodes)

    voxelize_room(&tree, &level)
    collect_boxes(&tree)
    tree_root := build_tree(&tree, context.allocator)
    fmt.eprintln("[Engine] Voxel tree built, root:", tree_root)

    // --- Camera Init (3rd-person follow) ---
    cam := Camera{
        pos     = { 0.0, 1.0, -5.0 },
        forward = { 0.0, 0.0, 1.0 },
        right   = { 1.0, 0.0, 0.0 },
        up      = { 0.0, 1.0, 0.0 },
        yaw     = 0.0,
        pitch   = 0.2,  // slight look-down at player
        roll    = 0.0,
    }
    camera_rebuild_basis(&cam)

    last_ticks := sdl.GetTicks()
    frame_count: int = 0
    fmt.eprintln("[Engine] Entering main loop")

    // Orbit distance and height for 3rd-person camera
    cam_distance: f32 = 5.0
    cam_height:   f32 = 2.0

    // --- Main Loop ---
    // Acquire swapchain first - only update game when we can render (prevents lightning speed from multiple updates/frame)
    running := true 
    for running
    {
        cmd_buffer := sdl.AcquireGPUCommandBuffer(gpu)
        if cmd_buffer == nil 
        { 
            fmt.eprintln("Failed to acquire command buffer:", sdl.GetError())
            continue 
        }

        swapchain_tex: ^sdl.GPUTexture
        if !sdl.AcquireGPUSwapchainTexture(cmd_buffer, window, &swapchain_tex, nil, nil)
        {
            if !sdl.SubmitGPUCommandBuffer(cmd_buffer)
            {
                fmt.eprintln("Critical failure during empty submit:", sdl.GetError())
                return 
            }
            continue  // skip game update when swapchain unavailable
        }

        // Delta time - fix for high fps (GetTicks has 1ms resolution; 0 = many frames/ms)
        current_ticks := sdl.GetTicks()
        delta_time := f32(current_ticks - last_ticks) / 1000.0
        if delta_time <= 0.0 do delta_time = 0.001  // high fps: assume 1000fps, not 60
        if delta_time > 0.05 do delta_time = 0.05   // cap spikes
        last_ticks = current_ticks
        frame_count += 1

        event: sdl.Event
        for sdl.PollEvent(&event)
        {
            if event.type == .QUIT
            {
                running = false
            }
        }

        // Keyboard state (bounds-check to avoid crash if SDL returns invalid state)
        num_keys: i32
        keys_ptr := sdl.GetKeyboardState(&num_keys)
        keys: []bool
        if keys_ptr != nil && num_keys > 0
        {
            keys = mem.slice_ptr(keys_ptr, int(num_keys))
        }
        else
        {
            keys = []bool{}  // empty - no key input this frame
        }
        key_ok := len(keys) > 0

        move_speed: f32 = 4.0   // units per second
        edit_mode := level.edit_mode
        rot_speed: f32 = edit_mode ? 0.25 : 0.4   // orbit speed
        gravity:    f32 = 12.0  // downward acceleration
        jump_vel:   f32 = 8.0   // upward velocity on jump
        floor_clearance: f32 = 0.04  // match collide_floor_planes
        rest_y := floor_y + player.collision_radius + floor_clearance
        matching_floor := (player.color == surface_colors[4]) || (player.color == surface_colors[10])

        // Jump: Space when on solid floor (not matching color)
        space_pressed := key_ok && key_pressed(keys, sdl.Scancode.SPACE)
        on_floor := !matching_floor && player.pos[1] <= rest_y + 0.05
        if space_pressed && on_floor
        {
            player.vel_y = jump_vel
        }

        // Gravity: apply to velocity (skip first 2 frames to let collision settle)
        if frame_count > 2
        {
            player.vel_y -= gravity * delta_time
            player.pos[1] += player.vel_y * delta_time
        }

        // WASD: move in camera-relative XZ (forward = cam.forward, right = cam.right)
        move_x: f32 = 0.0
        move_z: f32 = 0.0
        if key_ok
        {
            if key_pressed(keys, sdl.Scancode.W) do move_z += 1.0
            if key_pressed(keys, sdl.Scancode.S) do move_z -= 1.0
            if key_pressed(keys, sdl.Scancode.D) do move_x += 1.0
            if key_pressed(keys, sdl.Scancode.A) do move_x -= 1.0
        }

        if move_x != 0.0 || move_z != 0.0
        {
            mag := math.sqrt(move_x * move_x + move_z * move_z)
            if mag > 0.0001  // avoid div-by-zero
            {
                move_x /= mag
                move_z /= mag
                // Camera-relative: forward = cam.forward (XZ), right = cam.right (XZ)
                dx := move_z * cam.forward[0] + move_x * cam.right[0]
                dz := move_z * cam.forward[2] + move_x * cam.right[2]
                player.pos[0] += dx * move_speed * delta_time
                player.pos[2] += dz * move_speed * delta_time
            }
        }

        // R/G/B/Y: change color (Red/Blue/Green/Yellow). Match wall color to merge through.
        if key_ok
        {
            if key_pressed(keys, sdl.Scancode.R) do player.color = 0
            if key_pressed(keys, sdl.Scancode.G) do player.color = 1
            if key_pressed(keys, sdl.Scancode.B) do player.color = 2
            if key_pressed(keys, sdl.Scancode.Y) do player.color = 3
        }

        // Collision: hybrid - voxel for walls, floor planes for floor (SDF-precise, no voxel gaps)
        if tree_root >= 0
        {
            resolve_collision(&tree, tree_root, &player.pos, player.collision_radius, player.color, surface_colors, 12)
        }
        collide_floor_planes(&level, &player.pos, player.collision_radius, player.color, surface_colors)

        // Sanity: only reset on actual NaN (position corruption)
        px, py, pz := player.pos[0], player.pos[1], player.pos[2]
        if (px != px) || (py != py) || (pz != pz)
        {
            player.pos = { level.player.spawn_x, rest_y_init, level.player.spawn_z }
            player.vel_y = 0.0
        }

        // Floor snap: when resting on solid floor, snap to reduce shake. Zero vel_y when landed.
        if !matching_floor
        {
            if player.pos[1] >= rest_y - 0.02 && player.pos[1] <= rest_y + 0.02
            {
                player.pos[1] = rest_y
                player.vel_y = 0.0
            }
        }

        // Arrow keys: orbit camera around player
        if key_ok
        {
            if key_pressed(keys, sdl.Scancode.RIGHT) do cam.yaw += rot_speed * delta_time
            if key_pressed(keys, sdl.Scancode.LEFT)  do cam.yaw -= rot_speed * delta_time
            if key_pressed(keys, sdl.Scancode.UP)    do cam.pitch += rot_speed * delta_time
            if key_pressed(keys, sdl.Scancode.DOWN)  do cam.pitch -= rot_speed * delta_time

            // Edit mode: Q/E roll, CTRL camera down, ALT camera up (6-axis)
            if edit_mode
            {
                roll_speed: f32 = 0.5
                height_speed: f32 = 3.0
                if key_pressed(keys, sdl.Scancode.Q)     do cam.roll -= roll_speed * delta_time
                if key_pressed(keys, sdl.Scancode.E)     do cam.roll += roll_speed * delta_time
                if key_pressed(keys, sdl.Scancode.LCTRL) || key_pressed(keys, sdl.Scancode.RCTRL) do cam_height -= height_speed * delta_time
                if key_pressed(keys, sdl.Scancode.LALT)  || key_pressed(keys, sdl.Scancode.RALT)  do cam_height += height_speed * delta_time
            }
        }
        if cam_height < 0.5  do cam_height = 0.5   // clamp camera height
        if cam_height > 8.0  do cam_height = 8.0

        // Clamp pitch to avoid camera flip
        max_pitch: f32 = 89.0 * (math.PI / 180.0)
        if cam.pitch > max_pitch
        {
            cam.pitch = max_pitch
        }
        if cam.pitch < -max_pitch
        {
            cam.pitch = -max_pitch
        }

        // 3rd-person: position camera behind and above player
        cy := math.cos(cam.yaw)
        sy := math.sin(cam.yaw)
        cp := math.cos(cam.pitch)
        sp := math.sin(cam.pitch)
        offset := [3]f32{
            -sy * cp * cam_distance,
            sp * cam_distance + cam_height,
            -cy * cp * cam_distance,
        }
        cam.pos[0] = player.pos[0] + offset[0]
        cam.pos[1] = player.pos[1] + offset[1]
        cam.pos[2] = player.pos[2] + offset[2]

        // Look at player, rebuild basis for next frame rays
        to_player := [3]f32{
            player.pos[0] - cam.pos[0],
            player.pos[1] - cam.pos[1],
            player.pos[2] - cam.pos[2],
        }
        cam.forward = vec3_normalize(to_player)
        world_up := [3]f32{ 0.0, 1.0, 0.0 }
        cam.right = vec3_normalize(vec3_cross(world_up, cam.forward))
        cam.up    = vec3_normalize(vec3_cross(cam.forward, cam.right))

        if swapchain_tex != nil
        {
            if frame_count == 1 do fmt.eprintln("[Engine] First frame rendering")
            // Pack scene data for UBO (matches SceneBlock in shader)
            total_time := f32(sdl.GetTicks()) / 1000.0
            w, h: i32
            sdl.GetWindowSize(window, &w, &h)
            if w < 1 do w = 1
            if h < 1 do h = 1

            scene_struct := SceneData{
                screen      = { f32(w), f32(h), total_time, 0.0 },
                ball        = { player.pos[0], player.pos[1], player.pos[2], player.radius },
                box         = { f32(player.color), 0.0, 0.0, 0.0 },
                cam_pos     = { cam.pos[0],     cam.pos[1],     cam.pos[2],     0.0 },
                cam_forward = { cam.forward[0], cam.forward[1], cam.forward[2], 0.0 },
                cam_right   = { cam.right[0],   cam.right[1],   cam.right[2],   0.0 },
                cam_up      = { cam.up[0],      cam.up[1],      cam.up[2],      0.0 },
            }

            r0 := level.rooms[0].room if len(level.rooms) > 0 else RoomData{ 0, 0, 4, 6, 3, -1 }
            r1 := level.rooms[1].room if len(level.rooms) > 1 else RoomData{ center_x = 8, center_z = 0, half_x = 2, half_z = 3, height = 3, floor_y = -1 }
            room_block := RoomBlock{
                room         = { r0.half_x, r0.half_z, r0.height, r0.floor_y },
                room2        = { r1.center_x, r1.center_z, r1.half_x, r1.half_z },
                extras       = { level.wall_thickness, f32(surface_colors[4]), f32(surface_colors[10]), 0.0 },
                wall_colors  = { f32(surface_colors[0]), f32(surface_colors[1]), f32(surface_colors[2]), f32(surface_colors[3]) },
                wall_colors2 = { f32(surface_colors[6]), f32(surface_colors[7]), f32(surface_colors[8]), f32(surface_colors[9]) },
            }

            // Render pass
            color_target := sdl.GPUColorTargetInfo{
                texture = swapchain_tex,
                clear_color = {0.05, 0.05, 0.1, 1.0},
                load_op = .CLEAR,
                store_op = .STORE,
            }
            
            render_pass := sdl.BeginGPURenderPass(cmd_buffer, &color_target, 1, nil)
            
            // Upload UBOs to GPU (SceneData -> SceneBlock, RoomBlock -> RoomBlock)
            sdl.PushGPUFragmentUniformData(cmd_buffer, 0, &scene_struct, size_of(SceneData))
            sdl.PushGPUFragmentUniformData(cmd_buffer, 1, &room_block, size_of(RoomBlock))

            sdl.BindGPUGraphicsPipeline(render_pass, pipeline)
            sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0) 

            sdl.EndGPURenderPass(render_pass)
        }

        // Submit command buffer
        if !sdl.SubmitGPUCommandBuffer(cmd_buffer)
        {
            fmt.eprintln("Submit Failed:", sdl.GetError())
            running = false 
        }

        // Cap at ~60fps for consistent delta_time and input feel
        elapsed_ms := sdl.GetTicks() - current_ticks
        if elapsed_ms < 16 do sdl.Delay(u32(16 - elapsed_ms))
    }

    // --- Cleanup ---
    fmt.eprintln("[Engine] Exiting main loop, cleaning up")
    sdl.ReleaseGPUShader(gpu, vert_shader)
    sdl.ReleaseGPUShader(gpu, frag_shader)
    sdl.ReleaseGPUGraphicsPipeline(gpu, pipeline)
}



