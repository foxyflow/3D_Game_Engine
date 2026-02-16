package main

import sdl "vendor:sdl3"
import "core:fmt"

// The ".." tells Odin to step out of "src" and look in the root folder
VERT_SRC :: #load("../shaders/quad.vert.spv")
FRAG_SRC :: #load("../shaders/sdf_test.frag.spv")


TimeData :: struct ////time added for sphere animation
{
    time: f32,
    _padding: [3]f32, // GPU buffers like to be aligned to 16 bytes
}


main :: proc() {
    if !sdl.Init({.VIDEO}) {
        fmt.eprintln("SDL Init Failed:", sdl.GetError())
        return
    }
    defer sdl.Quit()

    window := sdl.CreateWindow("SDF Raymarcher", 800, 600, {})
    if window == nil {
        fmt.eprintln("Window Failed:", sdl.GetError())
        return
    }
    defer sdl.DestroyWindow(window)

    gpu := sdl.CreateGPUDevice({.SPIRV}, true, nil)
    if gpu == nil {
        fmt.eprintln("GPU Device Failed:", sdl.GetError())
        return
    }
    defer sdl.DestroyGPUDevice(gpu)

    if !sdl.ClaimWindowForGPUDevice(gpu, window) {
        fmt.eprintln("GPU Claim Failed:", sdl.GetError())
        return
    }


        // 1. Create the Shader Modules
    // We wrap your #load data into SDL GPU Shader objects
    // 1. Create the Vertex Shader Module
    // Define these before the loop
    
    // Vertex Shader (no resources)
    vert_shader_info := sdl.GPUShaderCreateInfo{
        code                 = raw_data(VERT_SRC),
        code_size            = uint(len(VERT_SRC)),
        entrypoint           = "main",
        format               = {.SPIRV},
        stage                = .VERTEX,
        num_samplers         = 0,
        num_storage_textures = 0,
        num_storage_buffers  = 0,
        num_uniform_buffers  = 0,
        props                = 0,  // ← Critical! SDL expects this
    }
    vert_shader := sdl.CreateGPUShader(gpu, vert_shader_info)
    if vert_shader == nil {
        fmt.eprintln("Vertex Shader Failed:", sdl.GetError())
        return
    }

    // Fragment Shader (1 uniform buffer at set=3, binding=0)
    frag_shader_info := sdl.GPUShaderCreateInfo{
        code                 = raw_data(FRAG_SRC),
        code_size            = uint(len(FRAG_SRC)),
        entrypoint           = "main",
        format               = {.SPIRV},
        stage                = .FRAGMENT,
        num_samplers         = 0,
        num_storage_textures = 0,
        num_storage_buffers  = 0,
        num_uniform_buffers  = 1,
        props                = 0,  // ← Critical!
    }
    frag_shader := sdl.CreateGPUShader(gpu, frag_shader_info)
    if frag_shader == nil {
        fmt.eprintln("Fragment Shader Failed:", sdl.GetError())
        return
    }

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


        running := true // main loop
        for running 
        {
            event: sdl.Event
            for sdl.PollEvent(&event) 
            {
                if event.type == .QUIT {
                    running = false
                }
            }

        cmd_buffer := sdl.AcquireGPUCommandBuffer(gpu)
        if cmd_buffer == nil { continue }

        swapchain_tex: ^sdl.GPUTexture
        if !sdl.AcquireGPUSwapchainTexture(cmd_buffer, window, &swapchain_tex, nil, nil) {
            _ = sdl.SubmitGPUCommandBuffer(cmd_buffer) 
            continue
        }

        if swapchain_tex != nil
                {
                    color_target := sdl.GPUColorTargetInfo{
                        texture = swapchain_tex,
                        clear_color = {0.05, 0.05, 0.1, 1.0},
                        load_op = .CLEAR,
                        store_op = .STORE,
                    }
                    // ONLY ONE Begin call
                    render_pass := sdl.BeginGPURenderPass(cmd_buffer, &color_target, 1, nil)
                    // Get time in seconds // PUSH UNIFORMS HERE (inside render pass!)
                    total_time := f32(sdl.GetTicks()) / 1000.0 
                    time_struct := TimeData{ time = total_time }
                    //time added for sphere animation
                    // Upload the time to the GPU (put this before BeginGPURenderPass)
                    sdl.PushGPUVertexUniformData(cmd_buffer, 0, &time_struct, size_of(TimeData))  // harmless
                    sdl.PushGPUFragmentUniformData(cmd_buffer, 0, &time_struct, size_of(TimeData))  // slot 0 = binding 0


                    sdl.BindGPUGraphicsPipeline(render_pass, pipeline)
                    sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0) 

                    // ONLY ONE End call
                    sdl.EndGPURenderPass(render_pass)
                }

        // Must handle the result of Submit
        if !sdl.SubmitGPUCommandBuffer(cmd_buffer) {
            fmt.eprintln("Submit Failed:", sdl.GetError())
        }
    }
        // Cleanup shaders and pipeline after the loop
    sdl.ReleaseGPUShader(gpu, vert_shader)
    sdl.ReleaseGPUShader(gpu, frag_shader)
    sdl.ReleaseGPUGraphicsPipeline(gpu, pipeline)
}


// Commented out Sector/portal code for now. We will return to it after we have the SDF raymarcher working.
// package main
// import sdl "vendor:sdl3"
// import "core:fmt"

// FRAG_SRC :: #load("shaders/sdf_test.glsl")

// main :: proc() {
//     // 1. Corrected Init (Handling the result)
//     if !sdl.Init({.VIDEO}) {
//         fmt.eprintln("SDL could not initialize! SDL_Error:", sdl.GetError())
//         return
//     }
//     defer sdl.Quit()

//     window := sdl.CreateWindow("SDF Raymarcher", 800, 600, {})
//     if window == nil {
//         fmt.eprintln("Window could not be created! SDL_Error:", sdl.GetError())
//         return
//     }
//     defer sdl.DestroyWindow(window)

//     renderer := sdl.CreateRenderer(window, nil)
//     if renderer == nil {
//         fmt.eprintln("Renderer could not be created! SDL_Error:", sdl.GetError())
//         return
//     }
//     defer sdl.DestroyRenderer(renderer)

//     running := true
//     for running {
//         event: sdl.Event
//         for sdl.PollEvent(&event) {
//             if event.type == .QUIT {
//                 running = false
//             }
//         }

//         sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
//         sdl.RenderClear(renderer)
        
//         // This is where you will eventually call your SDF logic
        
//         sdl.RenderPresent(renderer)
//     }
// }


// // --- Data Structures ---

// // A point on the 2D floor map
// World_Coordinate :: [2]f32

// Camera :: struct
// {
//     world_position: [2]f32,
//     view_angle:     f32, 
//     pitch:          f32, // 0 is straigh ahead, positive looks up, negative looks down
// }

// // A Wall is a line segment on the 2D floor map
// Wall :: struct
// {
//     a, b:      [2]f32,    // Start and End points (x, y)
//     color:     sdl.FColor,
//     portal_to: i32,       // -1 = solid wall, 0+ = ID of the sector it leads to
// }

// // A Sector is a room with a specific floor and ceiling height
// Sector :: struct
// {
//     walls:          [dynamic]Wall,
//     floor_height:   f32,
//     ceiling_height: f32,
// }

// // --- The Projection Logic ---

// // This proc converts a 3D point in the world into a 2D pixel on your screen.
// project_to_screen :: proc(
//     point_on_map:   World_Coordinate, 
//     vert_altitude:  f32, 
//     camera:         Camera,
// ) -> (screen_x: f32, screen_y: f32, is_visible: bool)
// {
//     // 1. DISTANCE CALCULATION (Relative to Player)
//     // We find how far the object is from the player's world position.
//     dist_x := point_on_map.x - camera.world_position.x
//     dist_y := point_on_map.y - camera.world_position.y

//     // 2. ROTATION (Camera Space Transformation)
//     // We calculate the Sine and Cosine of the camera's angle.
//     // 'sin' and 'cos' act as a "rotation matrix" to spin the world around us.
//     angle_sin := math.sin(-camera.view_angle)
//     angle_cos := math.cos(-camera.view_angle)
    
//     // transformed_x: How far Left or Right the point is in our "Field of View"
//     transformed_x := dist_x * angle_cos - dist_y * angle_sin
    
//     // transformed_depth: How far Forward the point is (The Z-axis)
//     transformed_depth := dist_x * angle_sin + dist_y * angle_cos

//     // 3. NEAR-PLANE CLIPPING
//     // If transformed_depth is less than 1.0, it's behind the camera or too close to see.
//     if transformed_depth < 1.0 do return 0, 0, false

//     // 4. PERSPECTIVE DIVIDE (The 3D Illusion)
//     // We take the horizontal position and divide it by depth.
//     // As depth increases, the point moves closer to the center of the screen (shrinks).
//     focal_length : f32 = 1000.0
    
//     // sx/sy: Screen X and Screen Y (The actual pixel coordinates)
//     sx := (transformed_x / transformed_depth) * focal_length + (1920 / 2)
//     //sy := (vert_altitude  / transformed_depth) * focal_length + (1080 / 2)
//     sy := ((vert_altitude + camera.pitch) / transformed_depth) * focal_length + (1080 / 2) //pitch up down arrows
//     return sx, sy, true
// }

// main :: proc()
// {
//     if !sdl.Init({.VIDEO}) {
//         os.exit(1)
//     }
//     defer sdl.Quit()

//     window := sdl.CreateWindow("Build 3: Descriptive Learning", 1920, 1080, nil)
//     renderer := sdl.CreateRenderer(window, nil)
//     defer sdl.DestroyRenderer(renderer)

//     cam := Camera{ world_position = {0, 0}, view_angle = 0 }

//     // World Space Triangle (Defined on the 2D floor map)
//     v_left   := World_Coordinate{ -150, 600 } 
//     v_right  := World_Coordinate{  150, 600 } 
//     v_center := World_Coordinate{    0, 600 } 

//     last_frame_ticks := sdl.GetTicks()

//     running := true //draw loop
//     for running
//     {
//         event: sdl.Event
//         for sdl.PollEvent(&event)
//         {
//             if event.type == .QUIT do running = false
//         }

//         // --- DELTA TIME ---
//         current_ticks := sdl.GetTicks()
//         // delta_time is the "slice of a second" since the last frame.
//         delta_time := f32(current_ticks - last_frame_ticks) / 1000.0
//         last_frame_ticks = current_ticks

//         // --- INPUT HANDLING ---
//         num_keys: i32
//         keys_ptr := sdl.GetKeyboardState(&num_keys)
//         keys := mem.slice_ptr(keys_ptr, int(num_keys))

//         // Update camera angle (Turning)
//         if bool(keys[int(sdl.Scancode.A)]) do cam.view_angle += 2.0 * delta_time
//         if bool(keys[int(sdl.Scancode.D)]) do cam.view_angle -= 2.0 * delta_time
//         // pitch up and down (looking up and down)
//         if bool(keys[int(sdl.Scancode.UP)])   do cam.pitch += 500.0 * delta_time
//         if bool(keys[int(sdl.Scancode.DOWN)]) do cam.pitch -= 500.0 * delta_time
        
        
//         // Find movement direction based on current angle
//         move_dir := [2]f32{math.sin(cam.view_angle), math.cos(cam.view_angle)}
        
//         if bool(keys[int(sdl.Scancode.W)]) do cam.world_position += move_dir * 500.0 * delta_time
//         if bool(keys[int(sdl.Scancode.S)]) do cam.world_position -= move_dir * 500.0 * delta_time

//         // // --- RENDERING ---
//         //hello triangle
//         // sdl.SetRenderDrawColor(renderer, 10, 10, 15, 255) 
//         // sdl.RenderClear(renderer)
//         // // Project the 3 vertices into screen space
//         // // v_left and v_right are on the "floor" (altitude 150)
//         // // v_center is the "peak" (altitude -150)
//         // x1, y1, visible1 := project_to_screen(v_left,   150, cam)
//         // x2, y2, visible2 := project_to_screen(v_right,  150, cam)
//         // x3, y3, visible3 := project_to_screen(v_center, -150, cam)
//         // if visible1 && visible2 && visible3
//         // {
//         //     triangle_color := sdl.FColor{0.1, 0.7, 0.3, 1.0} // Emerald Green 
//         //     // Build the geometry for the GPU
//         //     screen_geometry := [3]sdl.Vertex{
//         //         { {x1, y1}, triangle_color, {0,0} },
//         //         { {x2, y2}, triangle_color, {0,0} },
//         //         { {x3, y3}, triangle_color, {0,0} },
//         //     }
//         //     sdl.RenderGeometry(renderer, nil, &screen_geometry[0], 3, nil, 0)  
//         // } // End of Hello Triangle

//         // Define 4 corners for a square room
//         v1 := World_Coordinate{ -150, 600 } 
//         v2 := World_Coordinate{  150, 600 } 
//         v3 := World_Coordinate{  150, 900 } 
//         v4 := World_Coordinate{ -150, 900 } 

//         // Project all 4 corners for Floor (altitude 150) and Ceiling (altitude -150)
//         ax, ay, visA := project_to_screen(v1, 150, cam)
//         bx, by, visB := project_to_screen(v2, 150, cam)
//         cx, cy, visC := project_to_screen(v3, 150, cam)
//         dx, dy, visD := project_to_screen(v4, 150, cam)

//         ax_c, ay_c, visAc := project_to_screen(v1, -150, cam)
//         bx_c, by_c, visBc := project_to_screen(v2, -150, cam)
//         cx_c, cy_c, visCc := project_to_screen(v3, -150, cam)
//         dx_c, dy_c, visDc := project_to_screen(v4, -150, cam)

//         sdl.SetRenderDrawColor(renderer, 0, 255, 100, 255) // Emerald Line Color

//         // --- DRAWING THE SOLID FLOOR ---
//         if visA && visB && visC && visD
//         {
//             floor_color := sdl.FColor{0.05, 0.1, 0.05, 1.0} // Dark Green
            
//             // We need 6 vertices to make 2 triangles (which forms 1 square floor)
//             floor_geometry := [6]sdl.Vertex{
//                 // Triangle 1
//                 { {ax, ay}, floor_color, {0,0} },
//                 { {bx, by}, floor_color, {0,0} },
//                 { {cx, cy}, floor_color, {0,0} },
//                 // Triangle 2
//                 { {ax, ay}, floor_color, {0,0} },
//                 { {cx, cy}, floor_color, {0,0} },
//                 { {dx, dy}, floor_color, {0,0} },
//             }
            
//             sdl.RenderGeometry(renderer, nil, &floor_geometry[0], 6, nil, 0)
//         } //End of Solid Floor fill.

//         // --- DRAWING THE SOLID CEILING ---
//         if visAc && visBc && visCc && visDc
//         {
//             ceil_color := sdl.FColor{0.1, 0.2, 0.1, 1.0} // Slightly lighter Green
            
//             ceil_geometry := [6]sdl.Vertex{
//                 // Triangle 1
//                 { {ax_c, ay_c}, ceil_color, {0,0} },
//                 { {bx_c, ay_c}, ceil_color, {0,0} },
//                 { {cx_c, ay_c}, ceil_color, {0,0} },
//                 // Triangle 2
//                 { {ax_c, ay_c}, ceil_color, {0,0} },
//                 { {cx_c, ay_c}, ceil_color, {0,0} },
//                 { {dx_c, ay_c}, ceil_color, {0,0} },
//             }
            
//             sdl.RenderGeometry(renderer, nil, &ceil_geometry[0], 6, nil, 0)
//         } // End of Solid Ceiling fill.

            // This will box inside a box (a "sector") and leave one edge open as a "portal" to another sector,
            // will end up an array.
//         // Draw Vertical Pillars (Corners)
//         if visA && visAc do sdl.RenderLine(renderer, ax, ay, ax_c, ay_c)
//         if visB && visBc do sdl.RenderLine(renderer, bx, by, bx_c, by_c)
//         if visC && visCc do sdl.RenderLine(renderer, cx, cy, cx_c, cy_c)
//         if visD && visDc do sdl.RenderLine(renderer, dx, dy, dx_c, dy_c)

//         // Draw Floor and Ceiling connections
//         // We connect 1-2, 2-3, 3-4. We leave 4-1 OPEN (The Portal!)
//         if visA && visB do sdl.RenderLine(renderer, ax, ay, bx, by) 
//         if visB && visC do sdl.RenderLine(renderer, bx, by, cx, cy)
//         if visC && visD do sdl.RenderLine(renderer, cx, cy, dx, dy)
        
//         if visAc && visBc do sdl.RenderLine(renderer, ax_c, ay_c, bx_c, by_c)
//         if visBc && visCc do sdl.RenderLine(renderer, bx_c, by_c, cx_c, cy_c)
//         if visCc && visDc do sdl.RenderLine(renderer, cx_c, cy_c, dx_c, dy_c)

//         // --- DRAWING THE SECOND ROOM (Through the portal) ---
//         // Define 4 corners for Room #2 (placed further away at Y=1200)
//         r2_v1 := World_Coordinate{ -150, 1200 } 
//         r2_v2 := World_Coordinate{  150, 1200 } 
//         r2_v3 := World_Coordinate{  150, 1500 } 
//         r2_v4 := World_Coordinate{ -150, 1500 } 

//         // Project Room #2 (Let's make it a bit taller: altitude 250 to -250)
//         rax, ray, rvisA := project_to_screen(r2_v1, 250, cam)
//         rbx, rby, rvisB := project_to_screen(r2_v2, 250, cam)
//         rcx, rcy, rvisC := project_to_screen(r2_v3, 250, cam)
//         rdx, rdy, rvisD := project_to_screen(r2_v4, 250, cam)

//         rax_c, ray_c, rvisAc := project_to_screen(r2_v1, -250, cam)
//         rbx_c, rby_c, rvisBc := project_to_screen(r2_v2, -250, cam)
//         rcx_c, rcy_c, rvisCc := project_to_screen(r2_v3, -250, cam)
//         rdx_c, rdy_c, rvisDc := project_to_screen(r2_v4, -250, cam)

//         sdl.SetRenderDrawColor(renderer, 255, 50, 50, 255) // Red for the second room

//         // Draw Room #2 connections (a complete box this time)
//         if rvisA && rvisB do sdl.RenderLine(renderer, rax, ray, rbx, rby)
//         if rvisB && rvisC do sdl.RenderLine(renderer, rbx, rby, rcx, rcy)
//         if rvisC && rvisD do sdl.RenderLine(renderer, rcx, rcy, rdx, rdy)
//         if rvisD && rvisA do sdl.RenderLine(renderer, rdx, rdy, rax, ray)

//         if rvisAc && rvisBc do sdl.RenderLine(renderer, rax_c, ray_c, rbx_c, rby_c)
//         if rvisBc && rvisCc do sdl.RenderLine(renderer, rbx_c, rby_c, rcx_c, rcy_c)
//         if rvisCc && rvisDc do sdl.RenderLine(renderer, rcx_c, rcy_c, rdx_c, rdy_c)
//         if rvisDc && rvisAc do sdl.RenderLine(renderer, rdx_c, rdy_c, rax_c, ray_c)

//         // --- END OF SECOND ROOM ---

//         sdl.RenderPresent(renderer)
//     }
// }

