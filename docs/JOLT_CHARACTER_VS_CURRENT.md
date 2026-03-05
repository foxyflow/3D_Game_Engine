# Jolt Character Controller vs Current Setup

## What you have now (current setup)

- **Movement:** You apply velocity yourself in `main.odin`:
  - Gravity: `player.vel_y -= gravity * delta_time`
  - Horizontal: accelerate/decel from input, clamp to `move_speed`, then `player.pos += vel * delta_time`
  - Jump: set `vel_y = jump_vel` when on floor / on stuck projectile
- **Collision (green ball):** After moving, you call `jolt_resolve_player_collision(&player.pos, radius, player.color, 12)` which:
  - Runs `NarrowPhaseQuery_CollideShape2` (sphere at `player.pos` vs static world)
  - Collects contacts, filters merge-through (same-color walls), then **pushes position out** along the penetration axis of the “best” contact, up to 12 iterations
- **No velocity response:** You never cancel the “into wall” part of velocity, so the next frame the ball is driven back into the wall → feels sticky / gets stuck.

So: **you drive position and velocity; Jolt is only used to correct position (push out of geometry).**

---

## What Jolt’s character controller gives you

The bindings expose two character types:

1. **Character** – full rigid body in the simulation (has a BodyID, part of the physics step).
2. **CharacterVirtual** – **not** a body; it’s a dedicated “virtual” character that you move yourself and then ask Jolt to **resolve collisions and slide** for you. This is the one that matches your “I control velocity, you resolve” style.

### CharacterVirtual flow (from joltc.odin)

- **Create:** `CharacterVirtual_Create(settings, position, rotation, userData, system)`  
  Settings include: `CharacterVirtualSettings` (shape, mass, maxStrength, collision iterations, padding, etc.) and base `CharacterBaseSettings` (up vector, supporting volume, max slope angle, **shape**).
- **Each frame:**
  1. You set velocity: `CharacterVirtual_SetLinearVelocity(character, velocity)`
  2. You call: **`CharacterVirtual_Update(character, deltaTime, layer, system, bodyFilter, shapeFilter)`**  
     Jolt then:
     - Moves the character by velocity × dt
     - Collides the shape against the world
     - **Slides** along surfaces (resolves multiple contacts, adjusts velocity so you don’t stick)
     - Updates internal ground state (on ground, steep slope, not supported)
  3. You read position back: `CharacterVirtual_GetPosition(character, position)` and use it for rendering (e.g. SDF ball).
- **Ground / jump:**  
  `CharacterBase_GetGroundState(character)` → `OnGround` / `OnSteepGround` / `NotSupported`  
  So “can jump” = ground state is OnGround (or OnSteepGround if you allow that).

So: **you set velocity; Jolt does move + collide + slide and gives you a clean position and ground state.** No manual “push out” loop; sliding is built in.

---

## Side‑by‑side comparison

| Aspect | Your current (green ball) | Jolt CharacterVirtual |
|--------|---------------------------|------------------------|
| Who moves position | You (`pos += vel * dt`) | Jolt inside `CharacterVirtual_Update` |
| Who resolves collision | You (CollideShape2 + push out along one contact) | Jolt (internal collide + slide) |
| Velocity after hit | Unchanged → re-penetrate → stuck | Adjusted (sliding) so you don’t stick |
| “On ground” / jump | Your `on_floor` (e.g. `pos[1] <= rest_y + 0.05`) | `CharacterBase_GetGroundState` (OnGround / NotSupported) |
| Shape | Sphere (scale from radius) | Any shape in settings (e.g. capsule or sphere) |
| Merge-through / colors | You filter contacts by body user data (walls same color = skip) | You’d do the same in a **CharacterContactListener** (OnContactValidate / OnContactAdded) and reject or allow contacts by bodyID/userData |

---

## How you’d switch green ball to CharacterVirtual

1. **Create once (e.g. when level loads):**
   - Fill `CharacterVirtualSettings` (base shape = sphere or capsule, up = (0,1,0), max slope, layer, etc.).
   - `char_virtual = CharacterVirtual_Create(settings, &position, &rotation, userData, jolt_physics.system)`  
   - Optionally set a `CharacterContactListener` (with `CharacterContactListener_Procs` and `OnContactValidate` / `OnContactAdded`) to implement merge-through by body user data (reject contact if wall same color as player).
2. **Every frame (green ball only):**
   - Build velocity from input (same as now: gravity, horizontal, jump).
   - `CharacterVirtual_SetLinearVelocity(char_virtual, &vel)`  
   - `CharacterVirtual_Update(char_virtual, delta_time, JOLT_LAYER_MOVING, system, body_filter, shape_filter)`  
   - `CharacterVirtual_GetPosition(char_virtual, &position)` → copy into `player.pos` for rendering and camera.
   - Jump: only set upward velocity when `CharacterBase_GetGroundState(char_virtual) == .OnGround` (or similar).
3. **Rendering:** Keep your SDF ball at `player.pos`; no change.

So you’d **replace** the current “move + jolt_resolve_player_collision” path for green with “set velocity + CharacterVirtual_Update + get position”. That gives you Jolt’s character controller (with proper sliding and ground state) instead of the custom “push out only” logic that causes the ball to get stuck.
