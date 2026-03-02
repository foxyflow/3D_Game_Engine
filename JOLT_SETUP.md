# Jolt Physics Setup

Jolt Physics is integrated via [joltc-odin](https://github.com/jrdurandt/joltc-odin) (Odin bindings for JoltC C API).

## Prerequisites

- **CMake** - [cmake.org](https://cmake.org) (add to PATH)
- **Visual Studio Build Tools** - C++ compiler (already used for shaders)
- **Odin** - [odin-lang.org](https://odin-lang.org)

## Initial Setup

### 1. Submodules (already added)

```bash
git submodule update --init --recursive
```

### 2. Build JoltC DLL

Run from project root:

```batch
build_jolt.bat
```

This configures and builds JoltC, then copies `joltc.dll` and `joltc.lib` to:
- Project root (for main game)
- `lib/joltc-odin/` (for linker when using joltc package)

### 3. Verify

```batch
odin run jolt_test -collection:lib=./lib
```

Expected output: `Initializing Jolt Physics...` then `Jolt Init OK.`

## Integration Status

Jolt is integrated into the main game (`src/main.odin`):

- **Init**: `jolt_init(&level)` after level load
- **Static world**: Floor + walls from procedural rooms (see `src/jolt_physics.odin`)
- **User data**: Body user data stores surface color for future merge-through
- **Player collision**: Still uses voxel AABB tree (Jolt world ready for dynamic bodies, mesh loading)

## Using Jolt in Your Code

Build with:

```
-collection:lib=./lib
```

Import (in package main):

```odin
// jolt_physics.odin provides jolt_init, jolt_shutdown, jolt_physics
// For direct Jolt API:
import joltc "lib:joltc-odin"
```

## File Locations

| File | Purpose |
|------|---------|
| `lib/joltc-odin/` | joltc-odin submodule (Odin bindings) |
| `lib/joltc-odin/joltc/` | JoltC C wrapper (submodule) |
| `joltc.dll` | Runtime - must be next to .exe |
| `joltc.lib` | Link time - in lib/joltc-odin/ |

## Rebuilding JoltC

After pulling joltc-odin updates:

```batch
build_jolt.bat
```

## Troubleshooting

- **"cannot open input file joltc.lib"** - Run `build_jolt.bat` and ensure `joltc.lib` is in `lib/joltc-odin/`
- **DLL not found at runtime** - Copy `joltc.dll` to the same directory as your .exe
- **Python build.py fails** - Use `build_jolt.bat` instead (no Python needed)
