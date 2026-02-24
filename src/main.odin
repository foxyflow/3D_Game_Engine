package main

import sdl "vendor:sdl3"
import "core:fmt"
import "core:math"

// Ensure you have compiled these to .spv before running!
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
    screen: [4]f32, // [width, height, time, _unused]
    ball:   [4]f32, // [pos_x, pos_y, pos_z, radius]
    box:    [4]f32, // [pos_x, pos_y, pos_z, scale]
}

main :: proc()
{
    if !sdl.Init({.VIDEO})
    {
        fmt.eprintln("SDL Init Failed:", sdl.GetError())
        return
    }
    defer sdl.Quit()

    window := sdl.CreateWindow("SDF Raymarcher", 800, 600, {})
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
        num_uniform_buffers = 1, // Important!
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

    // --- Main Loop ---
    // Classic game/render loop:
    // 1) Handle input/events
    // 2) Build the SceneData for this frame
    // 3) Send SceneData to the GPU and draw
    // 4) Present the frame
    running := true 
    for running
    {
        event: sdl.Event
        for sdl.PollEvent(&event)
        {
            if event.type == .QUIT
            {
                running = false
            }
        }

        cmd_buffer := sdl.AcquireGPUCommandBuffer(gpu)
        if cmd_buffer == nil 
        { 
            fmt.eprintln("Failed to acquire command buffer:", sdl.GetError())
            continue 
        }

        swapchain_tex: ^sdl.GPUTexture
        // Try to get swapchain texture. If failed (e.g. minimized), submit empty buffer and loop.
        if !sdl.AcquireGPUSwapchainTexture(cmd_buffer, window, &swapchain_tex, nil, nil)
        {
            if !sdl.SubmitGPUCommandBuffer(cmd_buffer)
            {
                fmt.eprintln("Critical failure during empty submit:", sdl.GetError())
                return 
            }
            continue
        }

        if swapchain_tex != nil
        {
            // 1. Prepare Data
            // Build the SceneData for this frame on the CPU.
            // Right now this is still a small \"demo\" scene:
            // - a moving sphere
            // - a rotating box
            // - the screen size and elapsed time
            // Later we will replace these values with data taken from
            // our structured arrays (world/room description and player state).
            total_time := f32(sdl.GetTicks()) / 1000.0
            w, h: i32
            sdl.GetWindowSize(window, &w, &h) 
            
            // Explicit casting for math.sin
            moveX := f32(math.sin(f64(total_time * 2.0)) * 2.5) 

            scene_struct := SceneData{
                screen = { f32(w), f32(h), total_time, 0.0 }, 
                ball   = { moveX, 0.0, 0.0, 1.2 }, 
                box    = { 0.0,   1.5, 0.0, 1.5 },
            }

            // 2. Render Pass
            color_target := sdl.GPUColorTargetInfo{
                texture = swapchain_tex,
                clear_color = {0.05, 0.05, 0.1, 1.0},
                load_op = .CLEAR,
                store_op = .STORE,
            }
            
            render_pass := sdl.BeginGPURenderPass(cmd_buffer, &color_target, 1, nil)
            
            // Push Packed Data to Binding 0
            // This call copies our SceneData struct into the fragment‑shader
            // uniform buffer at binding slot 0 (set = 3, binding = 0 in GLSL).
            // From the shader's point of view this data is read‑only for the duration
            // of the frame, which is perfect for camera/world parameters.
            sdl.PushGPUFragmentUniformData(cmd_buffer, 0, &scene_struct, size_of(SceneData))

            sdl.BindGPUGraphicsPipeline(render_pass, pipeline)
            sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0) 

            sdl.EndGPURenderPass(render_pass)
        }

        // 3. Submit
        if !sdl.SubmitGPUCommandBuffer(cmd_buffer)
        {
            fmt.eprintln("Submit Failed:", sdl.GetError())
            running = false 
        }
    }

    // Cleanup
    sdl.ReleaseGPUShader(gpu, vert_shader)
    sdl.ReleaseGPUShader(gpu, frag_shader)
    sdl.ReleaseGPUGraphicsPipeline(gpu, pipeline)
}

// ------------------------------- extra comments -------------------------------
//         // Old --- RENDERING --- to show code example without using arrays.
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

