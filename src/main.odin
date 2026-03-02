// main.odin
// 3D SDF raymarcher with voxel AABB tree collision and merge-through-walls.
// Controls: WASD move, Space/B jump, arrows orbit, G/B/Y/X change color. F/A = fire (yellow). P/Y = pause.
// L1/LShift = duck (red). R1/H = gravel hook (green, placeholder). See levels/controls.json to rebind.
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
    box:        [4]f32, // [player_color, squash_horizontal 0-1, squash_vertical 0-1, _unused]
    cam_pos:    [4]f32, // camera code: [x, y, z, _unused]
    cam_forward:[4]f32, // camera code: forward basis vector
    cam_right:  [4]f32, // camera code: right   basis vector
    cam_up:     [4]f32, // camera code: up      basis vector
    projectile:  [4]f32,  // [pos_x, pos_y, pos_z, radius] — active projectile
    projectiles: [8][4]f32, // stuck projectiles [pos_x, pos_y, pos_z, radius], radius 0 = empty
}

// Yellow fire ability: projectile constants
PROJECTILE_SPEED  :: 12.0
PROJECTILE_RADIUS :: 0.3   // larger for visibility (was 0.15)
PROJECTILE_MAX_RANGE :: 20.0

Projectile :: struct
{
    pos:    [3]f32,  // world position
    vel:    [3]f32,  // velocity (normalized direction * speed)
    radius: f32,     // visual radius
    active: bool,    // false = not in flight
}

StuckProjectile :: struct { pos: [3]f32, radius: f32 }
MAX_STUCK_PROJECTILES :: 8

PROJECTILE_YELLOW_SLOWDOWN :: 0.82   // multiply vel each frame when inside yellow wall (slower pass-through)
PROJECTILE_YELLOW_MIN_SPEED :: 1.2   // minimum speed in yellow so we still make it through
PROJECTILE_STUCK_DEPTH :: 0.9       // how far into wall (0.5=half, 1.0=full radius)

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
// gap_bottom: height of gap at floor (pancake can fit under). gap_slit: width of vertical slit (pill can fit through).
// gap_hole_*: rectangular hole to jump through when small (0 = none)
WallDef :: struct
{
    type:           string,
    color:          string,
    gap_bottom:     f32,  // height of gap between floor and wall (0 = none)
    gap_slit:       f32,  // width of vertical slit in wall center (0 = none)
    gap_hole_width:   f32,  // horizontal size of jump-through hole (0 = none)
    gap_hole_height:  f32,  // vertical size of hole
    gap_hole_bottom:  f32,  // Y offset from floor to hole bottom
    gap_hole_offset:  f32,  // offset along wall (left/right: Z; back/front: X). 0 = centered
    gap_hole_offset_y:f32,  // vertical offset: moves hole up (+) or down (-) from gap_hole_bottom
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
    move_speed:   f32,  // max WASD units/sec; default 6.0 if 0 or missing
    move_accel:   f32,  // acceleration units/sec²; default 25 if 0 or missing
    move_decel:   f32,  // deceleration when releasing; default 18 if 0 or missing
    rot_speed:    f32,  // camera orbit rad/sec; default 0.6 if 0 or missing
}

// SwitchDef: per-wall switch config. Index 0-3 = room 0 (left,right,back,front), 4-7 = room 1.
SwitchDef :: struct
{
    label:    string,  // optional: e.g. "Main Room - Left" (for JSON readability only)
    start_on: bool,    // light starts on (default true)
    offset_x: f32,     // offset from default position
    offset_y: f32,
    offset_z: f32,
}

// MoonDef: directional moonlight.
MoonDef :: struct
{
    direction: [3]f32,  // [x, y, z] normalized in shader
    color:     [3]f32,  // [r, g, b] cool blue tint
    intensity: f32,
}

// LightingDef: loaded from JSON "lighting" section.
LightingDef :: struct
{
    ambient:             f32,        // dark ambient (default 0.02)
    moon:                MoonDef,
    point_brightness:   f32,        // multiplier for point lights (default 1.0)
    point_attenuation:  f32,        // 1/(1 + k*d^2) (default 0.3)
    use_wall_hue:       bool,       // tint point lights by wall color (default true)
    switch_radius:      f32,        // collision radius for bullet (default 0.25)
    switch_visual_radius: f32,      // SDF sphere size (default 0.15)
    switches:           [8]SwitchDef,
}

// ActionBind: one key + one button + optional axis (e.g. trigger). Strings from JSON, parsed at runtime.
ActionBind :: struct
{
    key:    string,
    button: string,
    axis:   string,  // e.g. "LEFT_TRIGGER", "RIGHT_TRIGGER"
}

// PlayerRedDef: red player squash controls. squash_exclusive: when true, horizontal blocks vertical and vice versa.
PlayerRedDef :: struct
{
    horizontal:       ActionBind,
    vertical:         ActionBind,
    squash_exclusive: bool,
}

// ControlsDef: loaded from levels/controls.json. All bindings + player + edit_mode configurable.
// Use "_comment" keys in JSON for notes (e.g. "_comment_edit_mode": "Toggle edit mode...") - they are ignored when loading.
ControlsDef :: struct
{
    jump:        ActionBind,
    fire:        ActionBind,
    duck_horizontal: ActionBind,  // L1/LShift: pancake (compress Y) - fit under gaps
    duck_vertical:   ActionBind,  // R1/V: pill (compress XZ) - fit through cracks
    player_red:      PlayerRedDef,  // red player squash; overrides duck_* when red
    gravel_hook: ActionBind,
    pause:       ActionBind,
    // Movement: key + button (e.g. D-pad). move_stick = "LEFT" or "RIGHT" for analog.
    move_forward: ActionBind,
    move_back:    ActionBind,
    move_left:    ActionBind,
    move_right:   ActionBind,
    move_stick:   string,  // "LEFT" or "RIGHT", which stick for analog movement
    // Camera orbit: key + button. cam_stick = "LEFT" or "RIGHT" for analog.
    cam_yaw_left:  ActionBind,
    cam_yaw_right: ActionBind,
    cam_pitch_up:   ActionBind,
    cam_pitch_down: ActionBind,
    cam_stick:      string,  // "LEFT" or "RIGHT", which stick for analog camera
    // Player and edit mode (moved from level JSON)
    edit_mode: bool,
    player:    PlayerDef,
}

// LevelData: whole level in one struct. Loaded from levels/level1.json.
// edit_mode and player are in controls.json, not level.
LevelData :: struct
{
    wall_thickness: f32,
    voxel_size:     f32,
    rooms:          [dynamic]RoomDef,
    lighting:       LightingDef,
}

// RoomBlock: separate UBO for room params. Room 0 at origin, room 1+2 at center. Room 3 disabled when room3.z (half_x) == 0.
RoomBlock :: struct
{
    room:         [4]f32, // [half_x, half_z, height, floor_y] room 0
    room2:        [4]f32, // [center_x, center_z, half_x, half_z] room 1
    room3:        [4]f32, // [center_x, center_z, half_x, half_z] room 2 (Hole Practice)
    room3_extras: [4]f32, // x=floor_color_r2, yzw unused
    extras:       [4]f32, // x=wall_thickness, y=floor_color_r0, z=floor_color_r1, w=use_wall_hue
    wall_colors:  [4]f32, // room 0: [left, right, back, front]
    wall_colors2: [4]f32, // room 1: [left, right, back, front]
    wall_colors3: [4]f32, // room 2: [left, right, back, front]
    light_on:     [4]f32, // room 0: left, right, back, front (0 or 1)
    light_on2:    [4]f32, // room 1: left, right, back, front
    light_on3:    [4]f32, // room 2: always 1 (no switches)
    lighting:     [4]f32, // x=ambient, y=point_brightness, z=point_attenuation, w=switch_visual_radius
    moon_dir:     [4]f32, // xyz direction (normalized)
    moon:         [4]f32, // rgb color, w=intensity
    switch_off_0: [4]f32, // x=off0.x, y=off1.x, z=off2.x, w=off3.x
    switch_off_1: [4]f32, // x=off0.y, y=off1.y, z=off2.y, w=off3.y
    switch_off_2: [4]f32, // x=off0.z, y=off1.z, z=off2.z, w=off3.z
    switch_off_3: [4]f32, // x=off4.x, y=off5.x, z=off6.x, w=off7.x
    switch_off_4: [4]f32, // x=off4.y, y=off5.y, z=off6.y, w=off7.y
    switch_off_5: [4]f32, // x=off4.z, y=off5.z, z=off6.z, w=off7.z
    room_gaps_0:  [4]f32, // room 0: left_bottom, left_slit, right_bottom, right_slit
    room_gaps_0b: [4]f32, // room 0: back_bottom, back_slit, front_bottom, front_slit
    room_gaps_1:  [4]f32, // room 1: left_bottom, left_slit, right_bottom, right_slit
    room_gaps_1b: [4]f32, // room 1: back_bottom, back_slit, front_bottom, front_slit
    room_gaps_2:  [4]f32, // room 2: left_bottom, left_slit, right_bottom, right_slit
    room_gaps_2b: [4]f32, // room 2: back_bottom, back_slit, front_bottom, front_slit
    room_gaps_0_hole:  [4]f32, // room 0: left_w, left_h, left_b, right_w
    room_gaps_0_hole2: [4]f32, // room 0: right_h, right_b, back_w, back_h
    room_gaps_0_hole3: [4]f32, // room 0: back_b, front_w, front_h, front_b
    room_gaps_1_hole:  [4]f32, // room 1: same layout
    room_gaps_1_hole2: [4]f32,
    room_gaps_1_hole3: [4]f32,
    room_gaps_2_hole:  [4]f32, // room 2: same layout
    room_gaps_2_hole2: [4]f32,
    room_gaps_2_hole3: [4]f32,
    room_gaps_0_hole_off:   [4]f32, // room 0: left, right, back, front hole offset (horizontal)
    room_gaps_0_hole_off_y: [4]f32, // room 0: hole offset Y (vertical)
    room_gaps_1_hole_off:   [4]f32,
    room_gaps_1_hole_off_y: [4]f32,
    room_gaps_2_hole_off:   [4]f32,
    room_gaps_2_hole_off_y: [4]f32,
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

// Get gap_bottom and gap_slit for wall index (0=left,1=right,2=back,3=front). Returns (bottom, slit).
get_wall_gaps :: proc(room_def: ^RoomDef, wall_idx: int) -> (bottom: f32, slit: f32)
{
    type_str := "left" if wall_idx == 0 else "right" if wall_idx == 1 else "back" if wall_idx == 2 else "front"
    for w in room_def.walls
    {
        if w.type == type_str do return w.gap_bottom, w.gap_slit
    }
    return 0, 0
}

// Get gap_hole for wall index. Returns (width, height, bottom, offset, offset_y). 0 width = no hole.
get_wall_hole :: proc(room_def: ^RoomDef, wall_idx: int) -> (width: f32, height: f32, bottom: f32, offset: f32, offset_y: f32)
{
    type_str := "left" if wall_idx == 0 else "right" if wall_idx == 1 else "back" if wall_idx == 2 else "front"
    for w in room_def.walls
    {
        if w.type == type_str do return w.gap_hole_width, w.gap_hole_height, w.gap_hole_bottom, w.gap_hole_offset, w.gap_hole_offset_y
    }
    return 0, 0, 0, 0, 0
}

// Returns 8 switch positions: room 0 walls 0-3, room 1 walls 4-7. Base + offset from lighting.switches.
get_switch_positions :: proc(level: ^LevelData, out: ^[8][3]f32)
{
    r0 := level.rooms[0].room if len(level.rooms) > 0 else RoomData{ 0, 0, 4, 6, 3, -1 }
    r1 := level.rooms[1].room if len(level.rooms) > 1 else RoomData{ center_x = 8, center_z = 0, half_x = 2, half_z = 3, height = 3, floor_y = -1 }
    wall_cy0 := r0.floor_y + r0.height * 0.5
    wall_cy1 := r1.floor_y + r1.height * 0.5
    sw := &level.lighting.switches
    out[0] = [3]f32{ -r0.half_x + sw[0].offset_x, wall_cy0 + sw[0].offset_y, 0 + sw[0].offset_z }
    out[1] = [3]f32{ r0.half_x + sw[1].offset_x, wall_cy0 + sw[1].offset_y, 0 + sw[1].offset_z }
    out[2] = [3]f32{ 0 + sw[2].offset_x, wall_cy0 + sw[2].offset_y, -r0.half_z + sw[2].offset_z }
    out[3] = [3]f32{ 0 + sw[3].offset_x, wall_cy0 + sw[3].offset_y, r0.half_z + sw[3].offset_z }
    out[4] = [3]f32{ r1.center_x - r1.half_x + sw[4].offset_x, wall_cy1 + sw[4].offset_y, r1.center_z + sw[4].offset_z }
    out[5] = [3]f32{ r1.center_x + r1.half_x + sw[5].offset_x, wall_cy1 + sw[5].offset_y, r1.center_z + sw[5].offset_z }
    out[6] = [3]f32{ r1.center_x + sw[6].offset_x, wall_cy1 + sw[6].offset_y, r1.center_z - r1.half_z + sw[6].offset_z }
    out[7] = [3]f32{ r1.center_x + sw[7].offset_x, wall_cy1 + sw[7].offset_y, r1.center_z + r1.half_z + sw[7].offset_z }
}

// Safe key check: avoids crash if keys slice is empty or scancode out of bounds.
key_pressed :: proc(keys: []bool, sc: sdl.Scancode) -> bool
{
    idx := int(sc)
    if idx < 0 || idx >= len(keys) do return false
    return keys[idx]
}

scancode_from_string :: proc(s: string) -> (sc: sdl.Scancode, ok: bool)
{
    switch s
    {
    case "SPACE":   return .SPACE, true
    case "F":       return .F, true
    case "P":       return .P, true
    case "R":       return .R, true
    case "H":       return .H, true
    case "V":       return .V, true
    case "LSHIFT": return .LSHIFT, true
    case "W":       return .W, true
    case "A":       return .A, true
    case "S":       return .S, true
    case "D":       return .D, true
    case "UP":      return .UP, true
    case "DOWN":   return .DOWN, true
    case "LEFT":   return .LEFT, true
    case "RIGHT":  return .RIGHT, true
    case "Q":      return .Q, true
    case "E":      return .E, true
    case "LCTRL":  return .LCTRL, true
    case "RCTRL":  return .RCTRL, true
    case "LALT":   return .LALT, true
    case "RALT":   return .RALT, true
    case "G":      return .G, true
    case "B":      return .B, true
    case "Y":      return .Y, true
    case:          return .A, false
    }
}

gamepad_button_from_string :: proc(s: string) -> (btn: sdl.GamepadButton, ok: bool)
{
    switch s
    {
    case "SOUTH":          return .SOUTH, true
    case "EAST":           return .EAST, true
    case "WEST":           return .WEST, true
    case "NORTH":          return .NORTH, true
    case "LEFT_SHOULDER":  return .LEFT_SHOULDER, true
    case "RIGHT_SHOULDER": return .RIGHT_SHOULDER, true
    case "DPAD_LEFT":      return .DPAD_LEFT, true
    case "DPAD_RIGHT":     return .DPAD_RIGHT, true
    case "DPAD_UP":        return .DPAD_UP, true
    case "DPAD_DOWN":      return .DPAD_DOWN, true
    case:                  return .INVALID, false
    }
}

// Returns true if any binding in act is pressed.
action_pressed :: proc(act: ActionBind, keys: []bool, key_ok: bool, gamepad: ^sdl.Gamepad) -> bool
{
    if act.key != ""
    {
        if sc, ok := scancode_from_string(act.key); ok && key_ok && key_pressed(keys, sc) do return true
    }
    if act.button != "" && gamepad != nil
    {
        if btn, ok := gamepad_button_from_string(act.button); ok && btn != .INVALID && sdl.GetGamepadButton(gamepad, btn) do return true
    }
    if act.axis != "" && gamepad != nil
    {
        axis: sdl.GamepadAxis = .INVALID
        switch act.axis
        {
        case "LEFT_TRIGGER":  axis = .LEFT_TRIGGER
        case "RIGHT_TRIGGER": axis = .RIGHT_TRIGGER
        case:
        }
        if axis != .INVALID && sdl.GetGamepadAxis(gamepad, axis) > 16384 do return true
    }
    return false
}

// Returns 1.0 if pressed, 0.0 otherwise. For movement/camera direction input.
// use_buttons: when false (e.g. edit mode), only keyboard key is checked (D-pad stays for camera).
action_value :: proc(act: ActionBind, keys: []bool, key_ok: bool, gamepad: ^sdl.Gamepad, use_buttons: bool = true) -> f32
{
    if act.key != ""
    {
        if sc, ok := scancode_from_string(act.key); ok && key_ok && key_pressed(keys, sc) do return 1.0
    }
    if use_buttons && act.button != "" && gamepad != nil
    {
        if btn, ok := gamepad_button_from_string(act.button); ok && btn != .INVALID && sdl.GetGamepadButton(gamepad, btn) do return 1.0
    }
    if use_buttons && act.axis != "" && gamepad != nil
    {
        axis: sdl.GamepadAxis = .INVALID
        switch act.axis
        {
        case "LEFT_TRIGGER":  axis = .LEFT_TRIGGER
        case "RIGHT_TRIGGER": axis = .RIGHT_TRIGGER
        case:
        }
        if axis != .INVALID && sdl.GetGamepadAxis(gamepad, axis) > 16384 do return 1.0
    }
    return 0.0
}

// Returns (move_x, move_z) from gamepad stick. move_stick "LEFT" or "RIGHT". Ly up = forward (positive z).
get_stick_move :: proc(gamepad: ^sdl.Gamepad, stick: string, deadzone: i16 = 8000) -> (x: f32, z: f32)
{
    if gamepad == nil do return 0.0, 0.0
    axis_x: sdl.GamepadAxis = .LEFTX
    axis_y: sdl.GamepadAxis = .LEFTY
    if stick == "RIGHT"
    {
        axis_x = .RIGHTX
        axis_y = .RIGHTY
    }
    lx := sdl.GetGamepadAxis(gamepad, axis_x)
    ly := sdl.GetGamepadAxis(gamepad, axis_y)
    if lx > deadzone || lx < -deadzone do x = f32(lx) / 32768.0
    if ly > deadzone || ly < -deadzone do z = -f32(ly) / 32768.0  // stick up = negative Y = forward
    return
}

// Returns (yaw, pitch) raw axis values for camera. cam_stick "LEFT" or "RIGHT".
get_stick_cam :: proc(gamepad: ^sdl.Gamepad, stick: string, deadzone: i16 = 8000) -> (yaw: f32, pitch: f32)
{
    if gamepad == nil do return 0.0, 0.0
    axis_x: sdl.GamepadAxis = .LEFTX
    axis_y: sdl.GamepadAxis = .LEFTY
    if stick == "RIGHT"
    {
        axis_x = .RIGHTX
        axis_y = .RIGHTY
    }
    rx := sdl.GetGamepadAxis(gamepad, axis_x)
    ry := sdl.GetGamepadAxis(gamepad, axis_y)
    if rx > deadzone || rx < -deadzone do yaw = f32(rx) / 32768.0
    if ry > deadzone || ry < -deadzone do pitch = -f32(ry) / 32768.0  // stick up = look up
    return
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
    // Apply lighting defaults when zero/missing
    lighting_was_empty := level.lighting.ambient == 0.0
    if level.lighting.ambient == 0.0 do level.lighting.ambient = 0.02
    if lighting_was_empty { for i in 0 ..< 8 do level.lighting.switches[i].start_on = true }
    if level.lighting.moon.intensity == 0.0
    {
        level.lighting.moon.direction = [3]f32{ 1.0, 3.0, -2.0 }
        level.lighting.moon.color = [3]f32{ 0.5, 0.55, 0.8 }
        level.lighting.moon.intensity = 0.12
    }
    if level.lighting.point_brightness == 0.0 do level.lighting.point_brightness = 1.0
    if level.lighting.point_attenuation == 0.0 do level.lighting.point_attenuation = 0.3
    if level.lighting.switch_radius == 0.0 do level.lighting.switch_radius = 0.25
    if level.lighting.switch_visual_radius == 0.0 do level.lighting.switch_visual_radius = 0.15
    ok = true
    return
}

load_controls :: proc(path: string, allocator := context.allocator) -> (ctrl: ControlsDef, ok: bool)
{
    data, read_ok := os.read_entire_file(path, allocator)
    defer delete(data)
    if !read_ok
    {
        fmt.eprintln("[Controls] File not found, using defaults:", path)
        ctrl = default_controls()
        ok = true
        return
    }
    err := json.unmarshal(data, &ctrl, .JSON, allocator)
    if err != nil
    {
        fmt.eprintln("[Controls] Parse error:", path, err)
        ctrl = default_controls()
        ok = true
        return
    }
    // Apply defaults for missing movement/camera bindings
    def := default_controls()
    if ctrl.move_forward.key == "" && ctrl.move_forward.button == "" do ctrl.move_forward = def.move_forward
    if ctrl.move_back.key == "" && ctrl.move_back.button == "" do ctrl.move_back = def.move_back
    if ctrl.move_left.key == "" && ctrl.move_left.button == "" do ctrl.move_left = def.move_left
    if ctrl.move_right.key == "" && ctrl.move_right.button == "" do ctrl.move_right = def.move_right
    if ctrl.move_stick == "" do ctrl.move_stick = "LEFT"
    if ctrl.duck_horizontal.key == "" && ctrl.duck_horizontal.button == "" do ctrl.duck_horizontal = def.duck_horizontal
    if ctrl.duck_vertical.key == "" && ctrl.duck_vertical.button == "" do ctrl.duck_vertical = def.duck_vertical
    if ctrl.player_red.horizontal.key == "" && ctrl.player_red.horizontal.button == "" do ctrl.player_red = def.player_red
    if ctrl.cam_yaw_left.key == "" && ctrl.cam_yaw_left.button == "" do ctrl.cam_yaw_left = def.cam_yaw_left
    if ctrl.cam_yaw_right.key == "" && ctrl.cam_yaw_right.button == "" do ctrl.cam_yaw_right = def.cam_yaw_right
    if ctrl.cam_pitch_up.key == "" && ctrl.cam_pitch_up.button == "" do ctrl.cam_pitch_up = def.cam_pitch_up
    if ctrl.cam_pitch_down.key == "" && ctrl.cam_pitch_down.button == "" do ctrl.cam_pitch_down = def.cam_pitch_down
    if ctrl.cam_stick == "" do ctrl.cam_stick = "RIGHT"
    if ctrl.player.color == "" do ctrl.player = def.player
    ok = true
    return
}

default_controls :: proc() -> ControlsDef
{
    return ControlsDef{
        jump         = { "SPACE", "SOUTH", "LEFT_TRIGGER" },
        fire         = { "F", "EAST", "RIGHT_TRIGGER" },
        duck_horizontal = { "LSHIFT", "LEFT_SHOULDER", "" },
        duck_vertical   = { "V", "RIGHT_SHOULDER", "" },
        player_red      = { horizontal = { "LSHIFT", "LEFT_SHOULDER", "" }, vertical = { "V", "RIGHT_SHOULDER", "" }, squash_exclusive = true },
        gravel_hook  = { "H", "RIGHT_SHOULDER", "" },
        pause        = { "P", "NORTH", "" },
        move_forward = { "W", "DPAD_UP", "" },
        move_back    = { "S", "DPAD_DOWN", "" },
        move_left    = { "A", "DPAD_LEFT", "" },
        move_right   = { "D", "DPAD_RIGHT", "" },
        move_stick   = "LEFT",
        cam_yaw_left  = { "LEFT", "", "" },
        cam_yaw_right = { "RIGHT", "", "" },
        cam_pitch_up   = { "UP", "", "" },
        cam_pitch_down = { "DOWN", "", "" },
        cam_stick      = "RIGHT",
        edit_mode     = false,
        player        = { color = "yellow", spawn_x = 0.125, spawn_z = 0.125, spawn_height = 2, move_speed = 10, move_accel = 25, move_decel = 18, rot_speed = 0.9 },
    }
}

// ------------------------------- Player --------------------------------

Player :: struct
{
    pos:              [3]f32, // world position (center of sphere)
    vel_x:            f32,    // horizontal velocity X (gradual accel/decel)
    vel_z:            f32,    // horizontal velocity Z
    vel_y:            f32,    // vertical velocity (gravity + jump)
    radius:           f32,    // visual radius (for SDF rendering)
    collision_radius: f32,    // collision radius (smaller for tighter feel)
    color:            i32,    // 0=Red, 1=Blue, 2=Green, 3=Yellow (merge-through when matches wall)
    squash_horizontal: f32,   // Red: 0-1, pancake (compress Y) for gaps at bottom of walls
    squash_vertical:   f32,   // Red: 0-1, pill (compress XZ) for vertical cracks
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
    if !sdl.Init({.VIDEO, .GAMEPAD})
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
        fmt.eprintln("GPU ClaimWindow Failed:", sdl.GetError())
        return
    }
    fmt.eprintln("[Engine] SDL + GPU init OK")

    // --- Gamepad (8BitDo Mario B/A, or any controller) ---
    gamepad: ^sdl.Gamepad = nil
    count: i32 = 0
    ids := sdl.GetGamepads(&count)
    if ids != nil && count > 0
    {
        gamepad = sdl.OpenGamepad(ids[0])
        if gamepad != nil do fmt.eprintln("[Engine] Gamepad opened:", sdl.GetGamepadName(gamepad))
    }
    defer if gamepad != nil do sdl.CloseGamepad(gamepad)

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
        append(&level.rooms[0].walls, WallDef{ "left",  "red", 0, 0, 0, 0, 0, 0, 0 })
        append(&level.rooms[0].walls, WallDef{ "right", "red", 0, 0, 0, 0, 0, 0, 0 })
        append(&level.rooms[0].walls, WallDef{ "back",  "red", 0, 0, 0, 0, 0, 0, 0 })
        append(&level.rooms[0].walls, WallDef{ "front", "blue", 0, 0, 0, 0, 0, 0, 0 })
    }
    fmt.eprintln("[Engine] Level loaded:", len(level.rooms), "rooms")
    defer {
        for r in level.rooms do delete(r.walls)
        delete(level.rooms)
    }

    // --- Controls Load ---
    ctrl, _ := load_controls("levels/controls.json")
    fmt.eprintln("[Engine] Controls loaded from levels/controls.json")

    // Surface colors: room_idx*6 + [left, right, back, front, floor_inner, floor_outer]. Max 3 rooms = 18.
    surface_colors: [18]i32 = { 0, 0, 0, 1, 0, -1, 0, 0, 0, 1, 0, -1, 0, 0, 0, 1, 0, -1 }
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

    // --- Jolt Physics (static world from rooms; player collision still uses voxel) ---
    jolt_ok := jolt_init(&level)
    defer if jolt_ok do jolt_shutdown()

    // --- Player Init (from controls.json player section, or defaults) ---
    player_color := color_string_to_id(ctrl.player.color != "" ? ctrl.player.color : "red")
    collision_radius: f32 = 0.3
    spawn_height: f32 = ctrl.player.spawn_height if ctrl.player.spawn_height > 0 else 3.0
    rest_y_init := floor_y + spawn_height
    player := Player{
        pos              = { ctrl.player.spawn_x, rest_y_init, ctrl.player.spawn_z },
        vel_x            = 0.0,
        vel_z            = 0.0,
        vel_y            = 0.0,
        radius           = 0.5,
        collision_radius = collision_radius,
        color            = player_color,
    }

    projectile := Projectile{
        pos    = { 0, 0, 0 },
        vel    = { 0, 0, 0 },
        radius = PROJECTILE_RADIUS,
        active = false,
    }
    stuck_projectiles: [dynamic]StuckProjectile
    defer delete(stuck_projectiles)

    // Wall lights: one per wall, toggled by projectile hitting switch. Init from level.lighting.switches
    light_on: [8]bool
    for i in 0 ..< 8 do light_on[i] = level.lighting.switches[i].start_on
    switch_overlapping: [8]bool = {}  // was projectile overlapping last frame (toggle on enter only)

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
    prev_x_pressed: bool = false  // for X button cycle (edge detect)
    prev_pause_pressed: bool = false
    game_paused: bool = false    // P/Y toggles (placeholder for in-game menu)

    // Orbit distance and height for 3rd-person camera
    cam_distance: f32 = 5.0
    cam_height:   f32 = 2.0


    fmt.eprintln("[Engine] Entering main loop")
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

        // Pause: P or Y button toggles (placeholder for in-game menu)
        pause_pressed := action_pressed(ctrl.pause, keys, key_ok, gamepad)
        if pause_pressed && !prev_pause_pressed do game_paused = !game_paused
        prev_pause_pressed = pause_pressed

        move_speed: f32 = ctrl.player.move_speed if ctrl.player.move_speed > 0 else 6.0
        move_accel: f32 = ctrl.player.move_accel if ctrl.player.move_accel > 0 else 25.0
        move_decel: f32 = ctrl.player.move_decel if ctrl.player.move_decel > 0 else 18.0
        edit_mode := ctrl.edit_mode
        rot_speed: f32 = ctrl.player.rot_speed if ctrl.player.rot_speed > 0 else (edit_mode ? 0.5 : 0.6)
        gravity:    f32 = 12.0  // downward acceleration
        jump_vel:   f32 = 8.0   // upward velocity on jump
        floor_clearance: f32 = 0.04  // match collide_floor_planes; ball slightly above floor
        // When squashed, rest_y uses squashed ry so ball sits on floor.
        // Same lerp style for both: ry_squashed + (player.radius - ry_squashed) * (1 - squash).
        // Horizontal: ry = collision (pancake). Vertical: ry = visual (pill keeps full height).
        effective_floor_r := player.radius
        if player.color == WALL_COLOR_RED
        {
            if player.squash_horizontal > 0.001
            {
                ry := player.collision_radius * (1.0 - player.squash_horizontal * 0.75)
                if ry < 0.05 do ry = 0.05
                effective_floor_r = ry + (player.radius - ry) * (1.0 - player.squash_horizontal)
            }
            else if player.squash_vertical > 0.001
            {
                ry := player.radius  // pill keeps full Y height (visual)
                effective_floor_r = ry + (player.radius - ry) * (1.0 - player.squash_vertical)
            }
        }
        rest_y := floor_y + effective_floor_r + floor_clearance
        matching_floor := (player.color == surface_colors[4]) || (player.color == surface_colors[10]) || (len(level.rooms) > 2 && player.color == surface_colors[16])

        if !game_paused
        {
        // Jump: from controls (Space/B/L2)
        space_pressed := action_pressed(ctrl.jump, keys, key_ok, gamepad)
        on_floor := !matching_floor && player.pos[1] <= rest_y + 0.05
        on_stuck: bool = false
        for sp in stuck_projectiles
        {
            if hit, push := sphere_vs_sphere(player.pos, player.radius, sp.pos, sp.radius); hit && player.pos[1] > sp.pos[1]
            {
                on_stuck = true
                break
            }
        }
        if space_pressed && (on_floor || on_stuck)
        {
            player.vel_y = jump_vel
        }

        // Gravity: apply to velocity (skip first 2 frames to let collision settle)
        if frame_count > 2
        {
            player.vel_y -= gravity * delta_time
            player.pos[1] += player.vel_y * delta_time
        }

        // Movement: from controls (WASD + D-pad + stick). In edit mode, D-pad reserved for camera.
        move_x: f32 = 0.0
        move_z: f32 = 0.0
        use_move_buttons := !edit_mode
        move_z += action_value(ctrl.move_forward, keys, key_ok, gamepad, use_move_buttons)
        move_z -= action_value(ctrl.move_back, keys, key_ok, gamepad, use_move_buttons)
        move_x += action_value(ctrl.move_right, keys, key_ok, gamepad, use_move_buttons)
        move_x -= action_value(ctrl.move_left, keys, key_ok, gamepad, use_move_buttons)
        stick_x, stick_z := get_stick_move(gamepad, ctrl.move_stick)
        move_x += stick_x
        move_z += stick_z

        if move_x != 0.0 || move_z != 0.0
        {
            mag := math.sqrt(move_x * move_x + move_z * move_z)
            if mag > 0.0001
            {
                move_x /= mag
                move_z /= mag
                target_dx := move_z * cam.forward[0] + move_x * cam.right[0]
                target_dz := move_z * cam.forward[2] + move_x * cam.right[2]
                player.vel_x += target_dx * move_accel * delta_time
                player.vel_z += target_dz * move_accel * delta_time
            }
        }
        else
        {
            speed := math.sqrt(player.vel_x*player.vel_x + player.vel_z*player.vel_z)
            if speed > 0.0001
            {
                decel_amount := move_decel * delta_time
                if decel_amount >= speed
                {
                    player.vel_x = 0.0
                    player.vel_z = 0.0
                }
                else
                {
                    scale := (speed - decel_amount) / speed
                    player.vel_x *= scale
                    player.vel_z *= scale
                }
            }
        }

        speed := math.sqrt(player.vel_x*player.vel_x + player.vel_z*player.vel_z)
        if speed > move_speed
        {
            scale := move_speed / speed
            player.vel_x *= scale
            player.vel_z *= scale
        }
        player.pos[0] += player.vel_x * delta_time
        player.pos[2] += player.vel_z * delta_time

        // R/G/B/Y or X button: change color (Red/Green/Blue/Yellow). Match wall color to merge through.
        if key_ok
        {
            if key_pressed(keys, sdl.Scancode.R) do player.color = 0
            if key_pressed(keys, sdl.Scancode.G) do player.color = 1
            if key_pressed(keys, sdl.Scancode.B) do player.color = 2
            if key_pressed(keys, sdl.Scancode.Y) do player.color = 3
        }
        x_pressed := gamepad != nil && sdl.GetGamepadButton(gamepad, .WEST)
        if x_pressed && !prev_x_pressed
        {
            player.color = (player.color + 1) % 4  // cycle R->G->B->Y->R
        }
        prev_x_pressed = x_pressed

        // Red duck: player_red horizontal = pancake, vertical = pill. squash_exclusive: only one at a time.
        SQUASH_SPEED :: 2.5  // how fast squash lerps in/out
        if player.color == WALL_COLOR_RED
        {
            want_h := action_pressed(ctrl.player_red.horizontal, keys, key_ok, gamepad)
            want_v := action_pressed(ctrl.player_red.vertical, keys, key_ok, gamepad)
            if ctrl.player_red.squash_exclusive && want_h && want_v
            {
                // Both pressed: horizontal blocks vertical (arbitrary tie-break)
                want_v = false
            }
            player.squash_horizontal += (1.0 if want_h else 0.0 - player.squash_horizontal) * SQUASH_SPEED * delta_time
            player.squash_vertical   += (1.0 if want_v else 0.0 - player.squash_vertical)   * SQUASH_SPEED * delta_time
            if player.squash_horizontal < 0.001 do player.squash_horizontal = 0.0
            if player.squash_horizontal > 0.999 do player.squash_horizontal = 1.0
            if player.squash_vertical   < 0.001 do player.squash_vertical   = 0.0
            if player.squash_vertical   > 0.999 do player.squash_vertical   = 1.0
        }
        else
        {
            player.squash_horizontal += (0.0 - player.squash_horizontal) * SQUASH_SPEED * delta_time
            player.squash_vertical   += (0.0 - player.squash_vertical)   * SQUASH_SPEED * delta_time
            if player.squash_horizontal < 0.001 do player.squash_horizontal = 0.0
            if player.squash_vertical   < 0.001 do player.squash_vertical   = 0.0
        }

        // Gravel hook: R1/H, Green only (placeholder for future)
        if player.color == WALL_COLOR_GREEN && action_pressed(ctrl.gravel_hook, keys, key_ok, gamepad)
        {
            // TODO: implement gravel hook
        }

        // Yellow fire: from controls (F/A/R2)
        f_pressed := action_pressed(ctrl.fire, keys, key_ok, gamepad)
        if f_pressed && !(player.color == WALL_COLOR_YELLOW) do fmt.eprintln("[FIRE] F pressed but blocked: color=", player.color)
        if f_pressed && player.color == WALL_COLOR_YELLOW
        {
            projectile.active = false  // replace any in-flight projectile so we can always fire
            muzzle_offset := player.radius + projectile.radius + 0.05
            // Straight shot: horizontal only (XZ), no vertical component
            fx, fz := cam.forward[0], cam.forward[2]
            len_xz := math.sqrt(fx*fx + fz*fz)
            if len_xz < 0.001
            {
                fx, fz = 1.0, 0.0  // fallback when looking straight up/down
            }
            else
            {
                inv := 1.0 / len_xz
                fx, fz = fx * inv, fz * inv
            }
            spawn_x := player.pos[0] + fx * muzzle_offset
            spawn_z := player.pos[2] + fz * muzzle_offset
            spawn_y := player.pos[1]
            projectile.pos    = [3]f32{ spawn_x, spawn_y, spawn_z }
            projectile.vel    = [3]f32{ fx * PROJECTILE_SPEED, 0.0, fz * PROJECTILE_SPEED }  // straight = no Y
            projectile.radius = PROJECTILE_RADIUS
            projectile.active = true
        }
        // Projectile update: move, slow in yellow wall (melt through), stick on non-yellow wall
        if projectile.active
        {
            projectile.pos[0] += projectile.vel[0] * delta_time
            projectile.pos[1] += projectile.vel[1] * delta_time
            projectile.pos[2] += projectile.vel[2] * delta_time

            if projectile.pos[1] < floor_y do projectile.active = false
            dx := projectile.pos[0] - player.pos[0]
            dy := projectile.pos[1] - player.pos[1]
            dz := projectile.pos[2] - player.pos[2]
            dist_sq := dx*dx + dy*dy + dz*dz
            if dist_sq > PROJECTILE_MAX_RANGE * PROJECTILE_MAX_RANGE do projectile.active = false

            // Switch overlap: toggle light when projectile enters switch sphere
            switch_pos: [8][3]f32
            get_switch_positions(&level, &switch_pos)
            sum_r := level.lighting.switch_radius + projectile.radius
            for i in 0 ..< 8
            {
                dx := projectile.pos[0] - switch_pos[i][0]
                dy := projectile.pos[1] - switch_pos[i][1]
                dz := projectile.pos[2] - switch_pos[i][2]
                dist_sq_sw := dx*dx + dy*dy + dz*dz
                overlapping := dist_sq_sw < sum_r * sum_r
                if overlapping && !switch_overlapping[i]
                {
                    light_on[i] = !light_on[i]
                }
                switch_overlapping[i] = overlapping
            }

            if tree_root >= 0
            {
                in_yellow := projectile_in_yellow_wall(&tree, tree_root, projectile.pos, projectile.radius, surface_colors)
                if in_yellow
                {
                    projectile.vel[0] *= PROJECTILE_YELLOW_SLOWDOWN
                    projectile.vel[1] *= PROJECTILE_YELLOW_SLOWDOWN
                    projectile.vel[2] *= PROJECTILE_YELLOW_SLOWDOWN
                    speed := math.sqrt(projectile.vel[0]*projectile.vel[0] + projectile.vel[1]*projectile.vel[1] + projectile.vel[2]*projectile.vel[2])
                    if speed > 0.001 && speed < PROJECTILE_YELLOW_MIN_SPEED
                    {
                        scale := PROJECTILE_YELLOW_MIN_SPEED / speed
                        projectile.vel[0] *= scale
                        projectile.vel[1] *= scale
                        projectile.vel[2] *= scale
                    }
                }
                else
                {
                    speed := math.sqrt(projectile.vel[0]*projectile.vel[0] + projectile.vel[1]*projectile.vel[1] + projectile.vel[2]*projectile.vel[2])
                    if speed > 0.001 && speed < PROJECTILE_SPEED
                    {
                        scale := PROJECTILE_SPEED / speed
                        projectile.vel[0] *= scale
                        projectile.vel[1] *= scale
                        projectile.vel[2] *= scale
                    }
                }
                if !in_yellow
                {
                    if hit, push := projectile_hits_wall(&tree, tree_root, projectile.pos, projectile.radius, WALL_COLOR_YELLOW, surface_colors); hit
                {
                    projectile.pos[0] += push[0]
                    projectile.pos[1] += push[1]
                    projectile.pos[2] += push[2]
                    push_len := math.sqrt(push[0]*push[0] + push[1]*push[1] + push[2]*push[2])
                    if push_len > 0.001
                    {
                        inv := 1.0 / push_len
                        half_in := projectile.radius * PROJECTILE_STUCK_DEPTH
                        projectile.pos[0] -= push[0] * inv * half_in
                        projectile.pos[1] -= push[1] * inv * half_in
                        projectile.pos[2] -= push[2] * inv * half_in
                    }
                    if len(stuck_projectiles) < MAX_STUCK_PROJECTILES
                    {
                        append(&stuck_projectiles, StuckProjectile{ pos = projectile.pos, radius = projectile.radius })
                    }
                    projectile.active = false
                    }
                }
            }
        }

        // Collision: voxel for walls, floor planes for floor. Red + squashed = ellipsoid for gaps.
        // Horizontal (pancake): compress Y to 25%. Vertical (pill/billboard): compress XZ to 50% so pill stays wider.
        SQUASH_FACTOR_H :: 0.25  // pancake min
        SQUASH_FACTOR_V :: 0.5   // pill min (billboard - don't shrink to needle)
        base_r := player.collision_radius
        use_ellipsoid := player.color == WALL_COLOR_RED && (player.squash_horizontal > 0.01 || player.squash_vertical > 0.01)
        if tree_root >= 0
        {
            if use_ellipsoid
            {
                rx := base_r * (1.0 - player.squash_vertical * (1.0 - SQUASH_FACTOR_V))
                ry := base_r * (1.0 - player.squash_horizontal * (1.0 - SQUASH_FACTOR_H))
                rz := base_r * (1.0 - player.squash_vertical * (1.0 - SQUASH_FACTOR_V))
                if rx < 0.1 do rx = 0.1   // pill stays wide enough to not phase through
                if ry < 0.05 do ry = 0.05
                if rz < 0.1 do rz = 0.1
                // Vertical-only (pill): use visual height so collision covers full extent, prevents going through walls
                if player.squash_vertical > 0.01 && player.squash_horizontal <= 0.01
                {
                    ry = player.radius
                }
                resolve_collision_ellipsoid(&tree, tree_root, &player.pos, { rx, ry, rz }, player.color, surface_colors, 12)
            }
            else
            {
                resolve_collision(&tree, tree_root, &player.pos, player.collision_radius, player.color, surface_colors, 12)
            }
        }
        ry_collision := base_r * (1.0 - player.squash_horizontal * (1.0 - SQUASH_FACTOR_H))
        if ry_collision < 0.05 do ry_collision = 0.05
        floor_radius := player.radius
        if player.color == WALL_COLOR_RED
        {
            if player.squash_horizontal > 0.001
            {
                floor_radius = ry_collision + (player.radius - ry_collision) * (1.0 - player.squash_horizontal)
            }
            else if player.squash_vertical > 0.001
            {
                ry := player.radius  // pill keeps full Y height (same lerp style)
                floor_radius = ry + (player.radius - ry) * (1.0 - player.squash_vertical)
            }
        }
        collide_floor_planes(&level, &player.pos, floor_radius, player.color, surface_colors, player.vel_y)
        for _ in 0 ..< 5
        {
            any_push := false
            for sp in stuck_projectiles
            {
                if hit, push := sphere_vs_sphere(player.pos, player.radius, sp.pos, sp.radius); hit
                {
                    player.pos[0] += push[0]
                    player.pos[1] += push[1]
                    player.pos[2] += push[2]
                    if push[1] > 0 do player.vel_y = 0.0  // landed on stuck projectile
                    any_push = true
                }
            }
            if !any_push do break
        }

        // Sanity: only reset on actual NaN (position corruption)
        px, py, pz := player.pos[0], player.pos[1], player.pos[2]
        if (px != px) || (py != py) || (pz != pz)
        {
            player.pos = { ctrl.player.spawn_x, rest_y_init, ctrl.player.spawn_z }
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

        // Camera orbit: from controls (arrows + stick). In edit mode, D-pad reserved for roll/height.
        use_cam_buttons := !edit_mode
        cam_yaw   := action_value(ctrl.cam_yaw_right, keys, key_ok, gamepad, use_cam_buttons) - action_value(ctrl.cam_yaw_left, keys, key_ok, gamepad, use_cam_buttons)
        cam_pitch := action_value(ctrl.cam_pitch_up, keys, key_ok, gamepad, use_cam_buttons) - action_value(ctrl.cam_pitch_down, keys, key_ok, gamepad, use_cam_buttons)
        stick_yaw, stick_pitch := get_stick_cam(gamepad, ctrl.cam_stick)
        cam.yaw   += (cam_yaw + stick_yaw) * rot_speed * delta_time
        cam.pitch += (cam_pitch + stick_pitch) * rot_speed * delta_time

        // Edit mode: Q/E roll, CTRL camera down, ALT camera up, D-pad (6-axis)
        if edit_mode && key_ok
        {
            roll_speed: f32 = 0.5
            height_speed: f32 = 3.0
            if key_pressed(keys, sdl.Scancode.Q)     do cam.roll -= roll_speed * delta_time
            if key_pressed(keys, sdl.Scancode.E)     do cam.roll += roll_speed * delta_time
            if key_pressed(keys, sdl.Scancode.LCTRL) || key_pressed(keys, sdl.Scancode.RCTRL) do cam_height -= height_speed * delta_time
            if key_pressed(keys, sdl.Scancode.LALT)  || key_pressed(keys, sdl.Scancode.RALT)  do cam_height += height_speed * delta_time
        }
        if edit_mode && gamepad != nil
        {
            roll_speed: f32 = 0.5
            height_speed: f32 = 3.0
            if sdl.GetGamepadButton(gamepad, .DPAD_LEFT)  do cam.roll -= roll_speed * delta_time
            if sdl.GetGamepadButton(gamepad, .DPAD_RIGHT) do cam.roll += roll_speed * delta_time
            if sdl.GetGamepadButton(gamepad, .DPAD_UP)    do cam_height += height_speed * delta_time
            if sdl.GetGamepadButton(gamepad, .DPAD_DOWN)  do cam_height -= height_speed * delta_time
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
        // Edit mode: apply roll (Q/E) to right/up around forward axis
        if edit_mode && cam.roll != 0.0
        {
            cr := math.cos(cam.roll)
            sr := math.sin(cam.roll)
            new_right := [3]f32{
                cam.right[0]*cr + cam.up[0]*sr,
                cam.right[1]*cr + cam.up[1]*sr,
                cam.right[2]*cr + cam.up[2]*sr,
            }
            new_up := [3]f32{
                -cam.right[0]*sr + cam.up[0]*cr,
                -cam.right[1]*sr + cam.up[1]*cr,
                -cam.right[2]*sr + cam.up[2]*cr,
            }
            cam.right = vec3_normalize(new_right)
            cam.up    = vec3_normalize(new_up)
        }

        }  // end if !game_paused

        if swapchain_tex != nil
        {
            if frame_count == 1 do fmt.eprintln("[Engine] First frame rendering")
            // Pack scene data for UBO (matches SceneBlock in shader)
            total_time := f32(sdl.GetTicks()) / 1000.0
            w, h: i32
            sdl.GetWindowSize(window, &w, &h)
            if w < 1 do w = 1
            if h < 1 do h = 1

            proj_radius: f32 = projectile.radius if projectile.active else 0.0
            projs: [8][4]f32 = {}
            for sp, i in stuck_projectiles
            {
                if i >= 8 do break
                projs[i] = { sp.pos[0], sp.pos[1], sp.pos[2], sp.radius }
            }
            scene_struct := SceneData{
                screen      = { f32(w), f32(h), total_time, 0.0 },
                ball        = { player.pos[0], player.pos[1], player.pos[2], player.radius },
                box         = { f32(player.color), player.squash_horizontal, player.squash_vertical, 0.0 },
                cam_pos     = { cam.pos[0],     cam.pos[1],     cam.pos[2],     0.0 },
                cam_forward = { cam.forward[0], cam.forward[1], cam.forward[2], 0.0 },
                cam_right   = { cam.right[0],   cam.right[1],   cam.right[2],   0.0 },
                cam_up      = { cam.up[0],      cam.up[1],      cam.up[2],      0.0 },
                projectile  = { projectile.pos[0], projectile.pos[1], projectile.pos[2], proj_radius },
                projectiles = projs,
            }

            r0 := level.rooms[0].room if len(level.rooms) > 0 else RoomData{ 0, 0, 4, 6, 3, -1 }
            r1 := level.rooms[1].room if len(level.rooms) > 1 else RoomData{ center_x = 8, center_z = 0, half_x = 2, half_z = 3, height = 3, floor_y = -1 }
            r2 := level.rooms[2].room if len(level.rooms) > 2 else RoomData{ center_x = 0, center_z = 0, half_x = 0, half_z = 0, height = 3, floor_y = -1 }
            light_on_f: [4]f32 = { 1.0 if light_on[0] else 0.0, 1.0 if light_on[1] else 0.0, 1.0 if light_on[2] else 0.0, 1.0 if light_on[3] else 0.0 }
            light_on_f2: [4]f32 = { 1.0 if light_on[4] else 0.0, 1.0 if light_on[5] else 0.0, 1.0 if light_on[6] else 0.0, 1.0 if light_on[7] else 0.0 }
            light_on_f3: [4]f32 = { 1.0, 1.0, 1.0, 1.0 }  // room 2 always lit (no switches)
            lit := &level.lighting
            moon_dir_n := vec3_normalize(lit.moon.direction)
            g0l_b, g0l_s, g0r_b, g0r_s, g0b_b, g0b_s, g0f_b, g0f_s: f32 = 0, 0, 0, 0, 0, 0, 0, 0
            g1l_b, g1l_s, g1r_b, g1r_s, g1b_b, g1b_s, g1f_b, g1f_s: f32 = 0, 0, 0, 0, 0, 0, 0, 0
            g2l_b, g2l_s, g2r_b, g2r_s, g2b_b, g2b_s, g2f_b, g2f_s: f32 = 0, 0, 0, 0, 0, 0, 0, 0
            h0l_w, h0l_h, h0l_b, h0l_off, h0l_off_y, h0r_w, h0r_h, h0r_b, h0r_off, h0r_off_y, h0b_w, h0b_h, h0b_b, h0b_off, h0b_off_y, h0f_w, h0f_h, h0f_b, h0f_off, h0f_off_y: f32 = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            h1l_w, h1l_h, h1l_b, h1l_off, h1l_off_y, h1r_w, h1r_h, h1r_b, h1r_off, h1r_off_y, h1b_w, h1b_h, h1b_b, h1b_off, h1b_off_y, h1f_w, h1f_h, h1f_b, h1f_off, h1f_off_y: f32 = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            h2l_w, h2l_h, h2l_b, h2l_off, h2l_off_y, h2r_w, h2r_h, h2r_b, h2r_off, h2r_off_y, h2b_w, h2b_h, h2b_b, h2b_off, h2b_off_y, h2f_w, h2f_h, h2f_b, h2f_off, h2f_off_y: f32 = 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            if len(level.rooms) > 0
            {
                g0l_b, g0l_s = get_wall_gaps(&level.rooms[0], 0)
                g0r_b, g0r_s = get_wall_gaps(&level.rooms[0], 1)
                g0b_b, g0b_s = get_wall_gaps(&level.rooms[0], 2)
                g0f_b, g0f_s = get_wall_gaps(&level.rooms[0], 3)
                h0l_w, h0l_h, h0l_b, h0l_off, h0l_off_y = get_wall_hole(&level.rooms[0], 0)
                h0r_w, h0r_h, h0r_b, h0r_off, h0r_off_y = get_wall_hole(&level.rooms[0], 1)
                h0b_w, h0b_h, h0b_b, h0b_off, h0b_off_y = get_wall_hole(&level.rooms[0], 2)
                h0f_w, h0f_h, h0f_b, h0f_off, h0f_off_y = get_wall_hole(&level.rooms[0], 3)
            }
            if len(level.rooms) > 1
            {
                g1l_b, g1l_s = get_wall_gaps(&level.rooms[1], 0)
                g1r_b, g1r_s = get_wall_gaps(&level.rooms[1], 1)
                g1b_b, g1b_s = get_wall_gaps(&level.rooms[1], 2)
                g1f_b, g1f_s = get_wall_gaps(&level.rooms[1], 3)
                h1l_w, h1l_h, h1l_b, h1l_off, h1l_off_y = get_wall_hole(&level.rooms[1], 0)
                h1r_w, h1r_h, h1r_b, h1r_off, h1r_off_y = get_wall_hole(&level.rooms[1], 1)
                h1b_w, h1b_h, h1b_b, h1b_off, h1b_off_y = get_wall_hole(&level.rooms[1], 2)
                h1f_w, h1f_h, h1f_b, h1f_off, h1f_off_y = get_wall_hole(&level.rooms[1], 3)
            }
            if len(level.rooms) > 2
            {
                g2l_b, g2l_s = get_wall_gaps(&level.rooms[2], 0)
                g2r_b, g2r_s = get_wall_gaps(&level.rooms[2], 1)
                g2b_b, g2b_s = get_wall_gaps(&level.rooms[2], 2)
                g2f_b, g2f_s = get_wall_gaps(&level.rooms[2], 3)
                h2l_w, h2l_h, h2l_b, h2l_off, h2l_off_y = get_wall_hole(&level.rooms[2], 0)
                h2r_w, h2r_h, h2r_b, h2r_off, h2r_off_y = get_wall_hole(&level.rooms[2], 1)
                h2b_w, h2b_h, h2b_b, h2b_off, h2b_off_y = get_wall_hole(&level.rooms[2], 2)
                h2f_w, h2f_h, h2f_b, h2f_off, h2f_off_y = get_wall_hole(&level.rooms[2], 3)
            }
            floor_color_r2: f32 = 0.0
            if len(level.rooms) > 2 do floor_color_r2 = f32(surface_colors[16])
            room_block := RoomBlock{
                room         = { r0.half_x, r0.half_z, r0.height, r0.floor_y },
                room2        = { r1.center_x, r1.center_z, r1.half_x, r1.half_z },
                room3        = { r2.center_x, r2.center_z, r2.half_x, r2.half_z },
                room3_extras = { floor_color_r2, 0.0, 0.0, 0.0 },
                extras       = { level.wall_thickness, f32(surface_colors[4]), f32(surface_colors[10]), lit.use_wall_hue ? 1.0 : 0.0 },
                wall_colors  = { f32(surface_colors[0]), f32(surface_colors[1]), f32(surface_colors[2]), f32(surface_colors[3]) },
                wall_colors2 = { f32(surface_colors[6]), f32(surface_colors[7]), f32(surface_colors[8]), f32(surface_colors[9]) },
                wall_colors3 = { f32(surface_colors[12]), f32(surface_colors[13]), f32(surface_colors[14]), f32(surface_colors[15]) },
                light_on3    = light_on_f3,
                light_on     = light_on_f,
                light_on2    = light_on_f2,
                lighting    = { lit.ambient, lit.point_brightness, lit.point_attenuation, lit.switch_visual_radius },
                moon_dir     = { moon_dir_n[0], moon_dir_n[1], moon_dir_n[2], 0.0 },
                moon         = { lit.moon.color[0], lit.moon.color[1], lit.moon.color[2], lit.moon.intensity },
                switch_off_0 = { lit.switches[0].offset_x, lit.switches[1].offset_x, lit.switches[2].offset_x, lit.switches[3].offset_x },
                switch_off_1 = { lit.switches[0].offset_y, lit.switches[1].offset_y, lit.switches[2].offset_y, lit.switches[3].offset_y },
                switch_off_2 = { lit.switches[0].offset_z, lit.switches[1].offset_z, lit.switches[2].offset_z, lit.switches[3].offset_z },
                switch_off_3 = { lit.switches[4].offset_x, lit.switches[5].offset_x, lit.switches[6].offset_x, lit.switches[7].offset_x },
                switch_off_4 = { lit.switches[4].offset_y, lit.switches[5].offset_y, lit.switches[6].offset_y, lit.switches[7].offset_y },
                switch_off_5 = { lit.switches[4].offset_z, lit.switches[5].offset_z, lit.switches[6].offset_z, lit.switches[7].offset_z },
                room_gaps_0  = { g0l_b, g0l_s, g0r_b, g0r_s },
                room_gaps_0b = { g0b_b, g0b_s, g0f_b, g0f_s },
                room_gaps_1  = { g1l_b, g1l_s, g1r_b, g1r_s },
                room_gaps_1b = { g1b_b, g1b_s, g1f_b, g1f_s },
                room_gaps_0_hole  = { h0l_w, h0l_h, h0l_b, h0r_w },
                room_gaps_0_hole2 = { h0r_h, h0r_b, h0b_w, h0b_h },
                room_gaps_0_hole3 = { h0b_b, h0f_w, h0f_h, h0f_b },
                room_gaps_1_hole  = { h1l_w, h1l_h, h1l_b, h1r_w },
                room_gaps_1_hole2 = { h1r_h, h1r_b, h1b_w, h1b_h },
                room_gaps_1_hole3 = { h1b_b, h1f_w, h1f_h, h1f_b },
                room_gaps_2  = { g2l_b, g2l_s, g2r_b, g2r_s },
                room_gaps_2b = { g2b_b, g2b_s, g2f_b, g2f_s },
                room_gaps_2_hole  = { h2l_w, h2l_h, h2l_b, h2r_w },
                room_gaps_2_hole2 = { h2r_h, h2r_b, h2b_w, h2b_h },
                room_gaps_2_hole3 = { h2b_b, h2f_w, h2f_h, h2f_b },
                room_gaps_0_hole_off   = { h0l_off, h0r_off, h0b_off, h0f_off },
                room_gaps_0_hole_off_y = { h0l_off_y, h0r_off_y, h0b_off_y, h0f_off_y },
                room_gaps_1_hole_off   = { h1l_off, h1r_off, h1b_off, h1f_off },
                room_gaps_1_hole_off_y = { h1l_off_y, h1r_off_y, h1b_off_y, h1f_off_y },
                room_gaps_2_hole_off   = { h2l_off, h2r_off, h2b_off, h2f_off },
                room_gaps_2_hole_off_y = { h2l_off_y, h2r_off_y, h2b_off_y, h2f_off_y },
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



