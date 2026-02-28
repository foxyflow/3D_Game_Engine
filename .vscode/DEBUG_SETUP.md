# Debug Setup (Cursor + 8bitdo keyboard)

## 1. Install CodeLLDB extension

Cursor does **not** support `cppvsdbg` (Microsoft C/C++ debugger). Use **CodeLLDB** instead:

1. Open Extensions (Ctrl+Shift+X)
2. Search for **"CodeLLDB"** (by vadimcn)
3. Install it

## 2. Start debugging without F5

Your 8bitdo keyboard may send media keys instead of F5. Use one of these:

| Method | How |
|--------|-----|
| **Run and Debug panel** | `Ctrl+Shift+D` → click green play button |
| **Menu** | Run → Start Debugging |
| **Command Palette** | `Ctrl+Shift+P` → type "Debug: Start Debugging" → Enter |

## 3. Add a custom keybinding (optional)

To bind debugging to a key you can reach:

1. `Ctrl+Shift+P` → "Preferences: Open Keyboard Shortcuts (JSON)"
2. Add:
```json
{
    "key": "ctrl+shift+d",
    "command": "workbench.action.debug.start"
}
```
(Use a key that doesn't conflict with your existing shortcuts.)

## 4. If you prefer cppvsdbg (advanced)

There is a community workaround involving hex-editing the C/C++ extension. See:  
https://gist.github.com/Ouroboros/1a1e0b9c8bcbac2a519516aa5a12a52b

CodeLLDB is simpler and works out of the box.
