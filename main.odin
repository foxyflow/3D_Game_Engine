package main

import "core:math"
import "core:os"
import "core:mem"      
import sdl "vendor:sdl3"

// --- Data Structures ---

// A point on the 2D floor map
World_Coordinate :: [2]f32

Camera :: struct {
    world_position: [2]f32,
    view_angle:     f32, 
}

// --- The Projection Logic ---

// This proc converts a 3D point in the world into a 2D pixel on your screen.
project_to_screen :: proc(
    point_on_map:   World_Coordinate, 
    vert_altitude:  f32, 
    camera:         Camera,
) -> (screen_x: f32, screen_y: f32, is_visible: bool) {

    // 1. DISTANCE CALCULATION (Relative to Player)
    // We find how far the object is from the player's world position.
    dist_x := point_on_map.x - camera.world_position.x
    dist_y := point_on_map.y - camera.world_position.y

    // 2. ROTATION (Camera Space Transformation)
    // We calculate the Sine and Cosine of the camera's angle.
    // 'sin' and 'cos' act as a "rotation matrix" to spin the world around us.
    angle_sin := math.sin(-camera.view_angle)
    angle_cos := math.cos(-camera.view_angle)
    
    // transformed_x: How far Left or Right the point is in our "Field of View"
    transformed_x := dist_x * angle_cos - dist_y * angle_sin
    
    // transformed_depth: How far Forward the point is (The Z-axis)
    transformed_depth := dist_x * angle_sin + dist_y * angle_cos

    // 3. NEAR-PLANE CLIPPING
    // If transformed_depth is less than 1.0, it's behind the camera or too close to see.
    if transformed_depth < 1.0 do return 0, 0, false

    // 4. PERSPECTIVE DIVIDE (The 3D Illusion)
    // We take the horizontal position and divide it by depth.
    // As depth increases, the point moves closer to the center of the screen (shrinks).
    focal_length : f32 = 1000.0
    
    // sx/sy: Screen X and Screen Y (The actual pixel coordinates)
    sx := (transformed_x / transformed_depth) * focal_length + (1920 / 2)
    sy := (vert_altitude  / transformed_depth) * focal_length + (1080 / 2)

    return sx, sy, true
}

main :: proc() {
    if !sdl.Init({.VIDEO}) {
        os.exit(1)
    }
    defer sdl.Quit()

    window := sdl.CreateWindow("Build 3: Descriptive Learning", 1920, 1080, nil)
    renderer := sdl.CreateRenderer(window, nil)
    defer sdl.DestroyRenderer(renderer)

    cam := Camera{ world_position = {0, 0}, view_angle = 0 }

    // World Space Triangle (Defined on the 2D floor map)
    v_left   := World_Coordinate{ -150, 600 } 
    v_right  := World_Coordinate{  150, 600 } 
    v_center := World_Coordinate{    0, 600 } 

    last_frame_ticks := sdl.GetTicks()

    running := true
    for running {
        event: sdl.Event
        for sdl.PollEvent(&event) {
            if event.type == .QUIT do running = false
        }

        // --- DELTA TIME ---
        current_ticks := sdl.GetTicks()
        // delta_time is the "slice of a second" since the last frame.
        delta_time := f32(current_ticks - last_frame_ticks) / 1000.0
        last_frame_ticks = current_ticks

        // --- INPUT HANDLING ---
        num_keys: i32
        keys_ptr := sdl.GetKeyboardState(&num_keys)
        keys := mem.slice_ptr(keys_ptr, int(num_keys))

        // Update camera angle (Turning)
        if bool(keys[int(sdl.Scancode.A)]) do cam.view_angle += 2.0 * delta_time
        if bool(keys[int(sdl.Scancode.D)]) do cam.view_angle -= 2.0 * delta_time
        
        // Find movement direction based on current angle
        move_dir := [2]f32{math.sin(cam.view_angle), math.cos(cam.view_angle)}
        
        if bool(keys[int(sdl.Scancode.W)]) do cam.world_position += move_dir * 500.0 * delta_time
        if bool(keys[int(sdl.Scancode.S)]) do cam.world_position -= move_dir * 500.0 * delta_time

        // --- RENDERING ---
        sdl.SetRenderDrawColor(renderer, 10, 10, 15, 255) 
        sdl.RenderClear(renderer)

        // Project the 3 vertices into screen space
        // v_left and v_right are on the "floor" (altitude 150)
        // v_center is the "peak" (altitude -150)
        x1, y1, visible1 := project_to_screen(v_left,   150, cam)
        x2, y2, visible2 := project_to_screen(v_right,  150, cam)
        x3, y3, visible3 := project_to_screen(v_center, -150, cam)

        if visible1 && visible2 && visible3 {
            triangle_color := sdl.FColor{0.1, 0.7, 0.3, 1.0} // Emerald Green
            
            // Build the geometry for the GPU
            screen_geometry := [3]sdl.Vertex{
                { {x1, y1}, triangle_color, {0,0} },
                { {x2, y2}, triangle_color, {0,0} },
                { {x3, y3}, triangle_color, {0,0} },
            }
            
            sdl.RenderGeometry(renderer, nil, &screen_geometry[0], 3, nil, 0)
        }

        sdl.RenderPresent(renderer)
    }
}