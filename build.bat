@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat"

REM Compile shaders first (required when .frag changes)
REM Vulkan SDK 1.4 at E:\VulkanSDK\1.4.341.1
REM vulkan1.1 = SPIR-V 1.3 (SDL3 expects this); vulkan1.2 = SPIR-V 1.5 (rejected by runtime)
E:\VulkanSDK\1.4.341.1\Bin\glslangValidator.exe --target-env vulkan1.1 -V shaders/quad.vert -o shaders/quad.vert.spv
if %ERRORLEVEL% neq 0 (echo Vertex shader failed & exit /b 1)
E:\VulkanSDK\1.4.341.1\Bin\glslangValidator.exe --target-env vulkan1.1 -V shaders/sdf_test.frag -o shaders/sdf_test.frag.spv
if %ERRORLEVEL% neq 0 (echo Fragment shader failed & exit /b 1)

odin build src -debug -out:3D_Game_Engine.exe -collection:lib=./lib
