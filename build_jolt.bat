@echo off
REM Build JoltC DLL for 3D Game Engine
REM Requires: CMake (https://cmake.org), Visual Studio Build Tools

call "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if %ERRORLEVEL% neq 0 (
    echo vcvars64 not found. Try: "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
    exit /b 1
)

cd lib\joltc-odin\joltc

echo Configuring JoltC...
cmake -S . -B build -DJPH_SAMPLES=OFF -DJPH_BUILD_SHARED=ON
if %ERRORLEVEL% neq 0 (echo CMake configure failed. Make sure CMake is installed. & exit /b 1)

echo Building JoltC...
cmake --build build --config Distribution
if %ERRORLEVEL% neq 0 (echo Build failed. & exit /b 1)

cd ..\..\..
copy lib\joltc-odin\joltc\build\bin\Distribution\joltc.dll .
copy lib\joltc-odin\joltc\build\lib\Distribution\joltc.lib .
copy lib\joltc-odin\joltc\build\bin\Distribution\joltc.dll lib\joltc-odin\
copy lib\joltc-odin\joltc\build\lib\Distribution\joltc.lib lib\joltc-odin\
echo Build complete. joltc.dll and joltc.lib copied to project root and lib/joltc-odin/
