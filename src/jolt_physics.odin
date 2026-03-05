// jolt_physics.odin - Jolt Physics integration for 3D Game Engine.
// Environment collision via Jolt. Player stays custom (SDF render, our movement).
package main

import joltc "lib:joltc-odin"
import "core:fmt"
import "core:math"
// Layer IDs for Jolt
JOLT_LAYER_NON_MOVING: joltc.ObjectLayer = 0
JOLT_LAYER_MOVING: joltc.ObjectLayer = 1
JOLT_LAYER_NUM :: 2

JOLT_BROAD_NON_MOVING: joltc.BroadPhaseLayer = 0
JOLT_BROAD_MOVING: joltc.BroadPhaseLayer = 1
JOLT_BROAD_NUM :: 2

// User data: pack surface color for merge-through. Low 8 bits = color (0=red,1=green,2=blue,3=yellow)
jolt_user_data_color :: proc(room_idx: int, surface_type: int, color: i32) -> u64 {
	return u64(room_idx << 16) | u64(surface_type << 8) | u64(color & 0xFF)
}

jolt_user_data_get_color :: proc(ud: u64) -> i32 {
	return i32(ud & 0xFF)
}

jolt_user_data_get_surface_type :: proc(ud: u64) -> int {
	return int((ud >> 8) & 0xFF)
}

JoltPhysics :: struct {
	job_system:           ^joltc.JobSystem,
	system:               ^joltc.PhysicsSystem,
	body_interface:       ^joltc.BodyInterface,
	narrow_query:         ^joltc.NarrowPhaseQuery,
	broad_query:          ^joltc.BroadPhaseQuery,
	sphere_shape:         ^joltc.Shape,  // unit sphere for collision queries
	broad_phase_filter:   ^joltc.BroadPhaseLayerFilter,  // accept-all for CollideShape
	object_layer_filter:  ^joltc.ObjectLayerFilter,
	body_filter:          ^joltc.BodyFilter,
	shape_filter:         ^joltc.ShapeFilter,
	initialized:          bool,
}

// Accept-all filter callbacks (Jolt crashes on nil filters)
@(private) jolt_filter_broad :: proc "c" (_: rawptr, _: joltc.BroadPhaseLayer) -> bool { return true }
@(private) jolt_filter_object :: proc "c" (_: rawptr, _: joltc.ObjectLayer) -> bool { return true }
@(private) jolt_filter_body :: proc "c" (_: rawptr, _: joltc.BodyID) -> bool { return true }
@(private) jolt_filter_body_locked :: proc "c" (_: rawptr, _: ^joltc.Body) -> bool { return true }
@(private) jolt_filter_shape :: proc "c" (_: rawptr, _: ^joltc.Shape, _: ^joltc.SubShapeID) -> bool { return true }
@(private) jolt_filter_shape2 :: proc "c" (_: rawptr, _: ^joltc.Shape, _: ^joltc.SubShapeID, _: ^joltc.Shape, _: ^joltc.SubShapeID) -> bool { return true }

// Filter procs must live for the entire program; Jolt stores pointers to them.
jolt_bp_procs: joltc.BroadPhaseLayerFilter_Procs
jolt_obj_procs: joltc.ObjectLayerFilter_Procs
jolt_body_procs: joltc.BodyFilter_Procs
jolt_shape_procs: joltc.ShapeFilter_Procs

jolt_physics: JoltPhysics

player_character: ^joltc.CharacterVirtual
player_contact_listener_procs: joltc.CharacterContactListener_Procs
player_contact_listener: ^joltc.CharacterContactListener
player_current_color: i32

@(private)
jolt_player_on_contact_validate :: proc "c" (_userData: rawptr, _character: ^joltc.CharacterVirtual, bodyID2: joltc.BodyID, _subShapeID2: joltc.SubShapeID) -> bool {
	if !jolt_physics.initialized do return true

	ud := joltc.BodyInterface_GetUserData(jolt_physics.body_interface, bodyID2)
	if ud == 0 do return true

	surf := int((ud >> 8) & 0xFF)
	body_color := i32(ud & 0xFF)

	// Walls (surface 0-3): merge-through when color matches player.
	if surf >= 0 && surf <= 3 {
		if body_color == player_current_color {
			return false // reject this contact: player passes through same-color wall
		}
	}

	// Room floors (FLOOR_INNER): melt-through when floor color matches player.
	if surf == FLOOR_INNER {
		if body_color == player_current_color {
			return false
		}
	}

	// Floors, standalone walls, and anything else stay solid.
	return true
}

jolt_init :: proc(level: ^LevelData) -> bool {
	if !joltc.Init() {
		fmt.eprintln("[Jolt] Init failed")
		return false
	}

	jolt_physics.job_system = joltc.JobSystemThreadPool_Create(nil)
	if jolt_physics.job_system == nil {
		fmt.eprintln("[Jolt] JobSystem failed")
		joltc.Shutdown()
		return false
	}

	object_layer_pair := joltc.ObjectLayerPairFilterTable_Create(JOLT_LAYER_NUM)
	joltc.ObjectLayerPairFilterTable_EnableCollision(object_layer_pair, JOLT_LAYER_MOVING, JOLT_LAYER_MOVING)
	joltc.ObjectLayerPairFilterTable_EnableCollision(object_layer_pair, JOLT_LAYER_MOVING, JOLT_LAYER_NON_MOVING)

	broad_interface := joltc.BroadPhaseLayerInterfaceTable_Create(JOLT_LAYER_NUM, JOLT_BROAD_NUM)
	joltc.BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(broad_interface, JOLT_LAYER_NON_MOVING, JOLT_BROAD_NON_MOVING)
	joltc.BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(broad_interface, JOLT_LAYER_MOVING, JOLT_BROAD_MOVING)

	object_vs_broad := joltc.ObjectVsBroadPhaseLayerFilterTable_Create(
		broad_interface, JOLT_BROAD_NUM, object_layer_pair, JOLT_LAYER_NUM)

	settings := joltc.PhysicsSystemSettings {
		maxBodies                = 4096,
		numBodyMutexes           = 0,
		maxBodyPairs             = 4096,
		maxContactConstraints    = 4096,
		broadPhaseLayerInterface = broad_interface,
		objectLayerPairFilter    = object_layer_pair,
		objectVsBroadPhaseLayerFilter = object_vs_broad,
	}
	jolt_physics.system = joltc.PhysicsSystem_Create(&settings)
	if jolt_physics.system == nil {
		fmt.eprintln("[Jolt] PhysicsSystem failed")
		joltc.JobSystem_Destroy(jolt_physics.job_system)
		joltc.Shutdown()
		return false
	}

	jolt_physics.body_interface = joltc.PhysicsSystem_GetBodyInterface(jolt_physics.system)
	jolt_physics.narrow_query = joltc.PhysicsSystem_GetNarrowPhaseQuery(jolt_physics.system)
	jolt_physics.broad_query = joltc.PhysicsSystem_GetBroadPhaseQuery(jolt_physics.system)
	jolt_physics.sphere_shape = cast(^joltc.Shape)joltc.SphereShape_Create(1.0)  // unit sphere, scale by radius

	// Create accept-all filters (Jolt crashes on nil filters in CollideShape/CollidePoint).
	// Procs are stored in globals so Jolt can keep pointers to them safely.
	jolt_bp_procs = joltc.BroadPhaseLayerFilter_Procs{ ShouldCollide = jolt_filter_broad }
	joltc.BroadPhaseLayerFilter_SetProcs(&jolt_bp_procs)
	jolt_physics.broad_phase_filter = joltc.BroadPhaseLayerFilter_Create(nil)

	jolt_obj_procs = joltc.ObjectLayerFilter_Procs{ ShouldCollide = jolt_filter_object }
	joltc.ObjectLayerFilter_SetProcs(&jolt_obj_procs)
	jolt_physics.object_layer_filter = joltc.ObjectLayerFilter_Create(nil)

	jolt_body_procs = joltc.BodyFilter_Procs{ ShouldCollide = jolt_filter_body, ShouldCollideLocked = jolt_filter_body_locked }
	joltc.BodyFilter_SetProcs(&jolt_body_procs)
	jolt_physics.body_filter = joltc.BodyFilter_Create(nil)

	jolt_shape_procs = joltc.ShapeFilter_Procs{ ShouldCollide = jolt_filter_shape, ShouldCollide2 = jolt_filter_shape2 }
	joltc.ShapeFilter_SetProcs(&jolt_shape_procs)
	jolt_physics.shape_filter = joltc.ShapeFilter_Create(nil)

	jolt_physics.initialized = true

	// Build static world from level
	jolt_build_static_world(level)
	fmt.eprintln("[Jolt] Physics world ready")
	return true
}

jolt_shutdown :: proc() {
	if !jolt_physics.initialized do return

	if player_character != nil {
		joltc.CharacterBase_Destroy(cast(^joltc.CharacterBase)player_character)
		player_character = nil
	}
	if player_contact_listener != nil {
		joltc.CharacterContactListener_Destroy(player_contact_listener)
		player_contact_listener = nil
	}

	if jolt_physics.broad_phase_filter != nil do joltc.BroadPhaseLayerFilter_Destroy(jolt_physics.broad_phase_filter)
	if jolt_physics.object_layer_filter != nil do joltc.ObjectLayerFilter_Destroy(jolt_physics.object_layer_filter)
	if jolt_physics.body_filter != nil do joltc.BodyFilter_Destroy(jolt_physics.body_filter)
	if jolt_physics.shape_filter != nil do joltc.ShapeFilter_Destroy(jolt_physics.shape_filter)
	joltc.PhysicsSystem_Destroy(jolt_physics.system)
	joltc.JobSystem_Destroy(jolt_physics.job_system)
	joltc.Shutdown()
	jolt_physics.initialized = false
	fmt.eprintln("[Jolt] Shutdown")
}

jolt_build_static_world :: proc(level: ^LevelData) {
	bi := jolt_physics.body_interface
	wt := level.wall_thickness
	level_floor := level_floor_aabb(level)

	// Per-room walls and floors (for merge-through: store color in user data)
	for room_idx in 0 ..< len(level.rooms) {
		room_def := &level.rooms[room_idx]
		r := &room_def.room
		floor_color := color_string_to_id(room_def.floor.color)

		// Floor inner (merge-through when color matches)
		floor_inner := floor_inner_aabb(r, wt)
		fi_half: [3]f32 = {
			(floor_inner.max[0] - floor_inner.min[0]) * 0.5,
			wt * 0.5,
			(floor_inner.max[2] - floor_inner.min[2]) * 0.5,
		}
		fi_center: [3]f32 = {
			(floor_inner.min[0] + floor_inner.max[0]) * 0.5,
			floor_inner.min[1] + wt * 0.5,
			(floor_inner.min[2] + floor_inner.max[2]) * 0.5,
		}
		fi_shape := joltc.BoxShape_Create(&fi_half, joltc.DEFAULT_CONVEX_RADIUS)
		fi_settings := joltc.BodyCreationSettings_Create3(
			cast(^joltc.Shape)fi_shape,
			&fi_center,
			nil,
			.Static,
			JOLT_LAYER_NON_MOVING,
		)
		defer joltc.BodyCreationSettings_Destroy(fi_settings)
		fi_id := joltc.BodyInterface_CreateAndAddBody(bi, fi_settings, .DontActivate)
		joltc.BodyInterface_SetUserData(bi, fi_id, jolt_user_data_color(room_idx, FLOOR_INNER, floor_color))

		// Floor outer ring: always solid, fills gaps between rooms so you don't fall forever when going through walls.
		left_outer, right_outer, back_outer, front_outer := floor_outer_aabb(r, wt)
		outer_list: [4]AABB = { left_outer, right_outer, back_outer, front_outer }
		for oi in 0 ..< 4 {
			aabb := outer_list[oi]
			half_out: [3]f32 = {
				(aabb.max[0] - aabb.min[0]) * 0.5,
				(aabb.max[1] - aabb.min[1]) * 0.5,
				(aabb.max[2] - aabb.min[2]) * 0.5,
			}
			center_out: [3]f32 = {
				(aabb.min[0] + aabb.max[0]) * 0.5,
				(aabb.min[1] + aabb.max[1]) * 0.5,
				(aabb.min[2] + aabb.max[2]) * 0.5,
			}
			out_shape := joltc.BoxShape_Create(&half_out, joltc.DEFAULT_CONVEX_RADIUS)
			out_settings := joltc.BodyCreationSettings_Create3(
				cast(^joltc.Shape)out_shape,
				&center_out,
				nil,
				.Static,
				JOLT_LAYER_NON_MOVING,
			)
			defer joltc.BodyCreationSettings_Destroy(out_settings)
			out_id := joltc.BodyInterface_CreateAndAddBody(bi, out_settings, .DontActivate)
			// FLOOR_OUTER: always solid, color -1 (ignored by merge-through rules).
			joltc.BodyInterface_SetUserData(bi, out_id, jolt_user_data_color(room_idx, FLOOR_OUTER, -1))
		}

		// Walls (left, right, back, front) - get color by wall type
		get_wall_color :: proc(room_def: ^RoomDef, wall_idx: int) -> i32 {
			type_str := wall_type_for_index(wall_idx)
			for w in room_def.walls {
				if w.type == type_str do return color_string_to_id(w.color)
			}
			return 0
		}
		walls: [4]struct { aabb: AABB, color: i32 } = {
			{ left_wall_aabb(r, wt),  get_wall_color(room_def, 0) },
			{ right_wall_aabb(r, wt), get_wall_color(room_def, 1) },
			{ back_wall_aabb(r, wt),  get_wall_color(room_def, 2) },
			{ front_wall_aabb(r, wt), get_wall_color(room_def, 3) },
		}
		for w in 0 ..< 4 {
			aabb := walls[w].aabb
			half: [3]f32 = {
				(aabb.max[0] - aabb.min[0]) * 0.5,
				(aabb.max[1] - aabb.min[1]) * 0.5,
				(aabb.max[2] - aabb.min[2]) * 0.5,
			}
			center: [3]f32 = {
				(aabb.min[0] + aabb.max[0]) * 0.5,
				(aabb.min[1] + aabb.max[1]) * 0.5,
				(aabb.min[2] + aabb.max[2]) * 0.5,
			}
			wall_shape := joltc.BoxShape_Create(&half, joltc.DEFAULT_CONVEX_RADIUS)
			wall_settings := joltc.BodyCreationSettings_Create3(
				cast(^joltc.Shape)wall_shape,
				&center,
				nil,
				.Static,
				JOLT_LAYER_NON_MOVING,
			)
			defer joltc.BodyCreationSettings_Destroy(wall_settings)
			wall_id := joltc.BodyInterface_CreateAndAddBody(bi, wall_settings, .DontActivate)
			joltc.BodyInterface_SetUserData(bi, wall_id, jolt_user_data_color(room_idx, int(w), walls[w].color))
		}
	}

	// Standalone walls: always solid (no merge-through). Color only for rendering.
	for i in 0 ..< len(level.standalone_walls) {
		sw := level.standalone_walls[i]
		half: [3]f32 = {
			sw.half_x,
			sw.half_y,
			sw.half_z,
		}
		center: [3]f32 = {
			sw.center_x,
			sw.center_y,
			sw.center_z,
		}
		sw_shape := joltc.BoxShape_Create(&half, joltc.DEFAULT_CONVEX_RADIUS)
		sw_settings := joltc.BodyCreationSettings_Create3(
			cast(^joltc.Shape)sw_shape,
			&center,
			nil,
			.Static,
			JOLT_LAYER_NON_MOVING,
		)
		defer joltc.BodyCreationSettings_Destroy(sw_settings)
		sw_id := joltc.BodyInterface_CreateAndAddBody(bi, sw_settings, .DontActivate)
		// surface_type 8 = standalone; treated as non-wall in character filter so it's always solid.
		sw_color := color_string_to_id(sw.color)
		joltc.BodyInterface_SetUserData(bi, sw_id, jolt_user_data_color(0, 8, sw_color))
	}

	joltc.PhysicsSystem_OptimizeBroadPhase(jolt_physics.system)
}

// --- CharacterVirtual player controller (used for green ball first) ---

jolt_player_character_init :: proc(player: ^Player) {
	if !jolt_physics.initialized || player == nil do return
	if player_character != nil do return

	settings: joltc.CharacterVirtualSettings
	joltc.CharacterVirtualSettings_Init(&settings)

	// Basic up direction and slope settings
	settings.base.up = joltc.Vec3{ 0, 1, 0 }
	settings.base.maxSlopeAngle = 60.0 * (math.PI / 180.0)

	// Simple body properties
	settings.mass = 1.0
	settings.maxStrength = 1000.0
	settings.backFaceMode = .IgnoreBackFaces
	settings.predictiveContactDistance = 0.1
	settings.maxCollisionIterations = 8
	settings.maxConstraintIterations = 3
	settings.collisionTolerance = 0.05
	settings.characterPadding = 0.02

	// Shape: sphere matching our collision radius
	radius := player.collision_radius
	if radius <= 0.0 do radius = 0.3
	char_shape := joltc.SphereShape_Create(radius)
	settings.base.shape = cast(^joltc.Shape)char_shape

	start_pos: joltc.RVec3 = { player.pos[0], player.pos[1], player.pos[2] }
	angles := joltc.Vec3{ 0, 0, 0 }
	rot: joltc.Quat
	joltc.Quat_FromEulerAngles(&angles, &rot)

	player_character = joltc.CharacterVirtual_Create(&settings, &start_pos, &rot, 0, jolt_physics.system)
	if player_character == nil {
		fmt.eprintln("[Jolt] CharacterVirtual_Create failed")
		return
	}

	// Set up contact listener once, then attach to character.
	if player_contact_listener == nil {
		player_contact_listener_procs = joltc.CharacterContactListener_Procs{}
		player_contact_listener_procs.OnContactValidate = jolt_player_on_contact_validate
		joltc.CharacterContactListener_SetProcs(&player_contact_listener_procs)
		player_contact_listener = joltc.CharacterContactListener_Create(nil)
	}
	joltc.CharacterVirtual_SetListener(player_character, player_contact_listener)

	fmt.eprintln("[Jolt] CharacterVirtual created for player")
}

jolt_player_character_step :: proc(player: ^Player, delta_time: f32) {
	if !jolt_physics.initialized || player == nil do return
	if player_character == nil do jolt_player_character_init(player)
	if player_character == nil do return

	vel: joltc.Vec3 = { player.vel_x, player.vel_y, player.vel_z }
	joltc.CharacterVirtual_SetLinearVelocity(player_character, &vel)

	joltc.CharacterVirtual_Update(
		player_character,
		delta_time,
		JOLT_LAYER_MOVING,
		jolt_physics.system,
		jolt_physics.body_filter,
		jolt_physics.shape_filter,
	)

	// Read back position and velocity for SDF render + gameplay
	pos_r: joltc.RVec3
	joltc.CharacterVirtual_GetPosition(player_character, &pos_r)
	player.pos[0] = pos_r[0]
	player.pos[1] = pos_r[1]
	player.pos[2] = pos_r[2]

	new_vel: joltc.Vec3
	joltc.CharacterVirtual_GetLinearVelocity(player_character, &new_vel)
	player.vel_x = new_vel[0]
	player.vel_y = new_vel[1]
	player.vel_z = new_vel[2]
}

jolt_player_character_sync_from_player :: proc(player: ^Player) {
	if !jolt_physics.initialized || player == nil || player_character == nil do return
	pos_r: joltc.RVec3 = { player.pos[0], player.pos[1], player.pos[2] }
	joltc.CharacterVirtual_SetPosition(player_character, &pos_r)
}

jolt_player_character_on_ground :: proc() -> bool {
	if !jolt_physics.initialized || player_character == nil do return false
	base := cast(^joltc.CharacterBase)player_character
	state := joltc.CharacterBase_GetGroundState(base)
	return state == .OnGround || state == .OnSteepGround
}

// --- Player collision (sphere vs world, merge-through by color) ---
JOLT_MAX_CONTACTS :: 32

jolt_player_contact :: struct {
	axis:    joltc.Vec3,
	depth:   f32,
	bodyID2: joltc.BodyID,
}

jolt_player_collision_ctx :: struct {
	pos:         ^[3]f32,
	player_color: i32,
	contacts:    [JOLT_MAX_CONTACTS]jolt_player_contact,
	count:       int,
}

// Callback only copies contact data; no GetUserData here (can crash when called from Jolt's thread).
@(private)
jolt_player_collide_callback :: proc "c" (_context: rawptr, result: ^joltc.CollideShapeResult) {
	ctx := cast(^jolt_player_collision_ctx)_context
	if ctx == nil || result == nil do return
	if ctx.count >= JOLT_MAX_CONTACTS do return

	axis := result.penetrationAxis
	depth := result.penetrationDepth
	bodyID2 := result.bodyID2

	c := &ctx.contacts[ctx.count]
	c.axis = axis
	c.depth = depth
	c.bodyID2 = bodyID2
	ctx.count += 1
}

jolt_resolve_player_collision :: proc(pos: ^[3]f32, radius: f32, player_color: i32, max_iter: int = 12) {
	jolt_resolve_player_collision_scaled(pos, radius, radius, radius, player_color, max_iter)
}

// Scaled sphere (ellipsoid-like) for red ball: scale_x/y/z = radii (squash compresses Y or XZ).
jolt_resolve_player_collision_scaled :: proc(pos: ^[3]f32, scale_x, scale_y, scale_z: f32, player_color: i32, max_iter: int = 12) {
	if !jolt_physics.initialized || jolt_physics.sphere_shape == nil do return

	scale: joltc.Vec3 = { scale_x, scale_y, scale_z }
	trans: joltc.Vec3 = { pos[0], pos[1], pos[2] }
	transform: joltc.RMat4
	joltc.Mat4_Identity(&transform)
	joltc.Mat4_Translation(&transform, &trans)

	settings: joltc.CollideShapeSettings
	joltc.CollideShapeSettings_Init(&settings)

	ctx: jolt_player_collision_ctx = {
		pos          = pos,
		player_color = player_color,
		contacts     = {},
		count        = 0,
	}

	// baseOffset must be a valid pointer (Jolt dereferences it; nil caused access violation).
	base_offset: joltc.RVec3 = { 0, 0, 0 }
	for _ in 0 ..< max_iter {
		ctx.count = 0
		joltc.NarrowPhaseQuery_CollideShape2(
			jolt_physics.narrow_query,
			jolt_physics.sphere_shape,
			&scale,
			&transform,
			&settings,
			&base_offset,
			joltc.CollisionCollectorType.AllHit,
			jolt_player_collide_callback,
			&ctx,
			jolt_physics.broad_phase_filter,
			jolt_physics.object_layer_filter,
			jolt_physics.body_filter,
			jolt_physics.shape_filter,
		)
		if ctx.count == 0 do break
		// Clamp in case Jolt callback was invoked more than JOLT_MAX_CONTACTS (avoids out-of-bounds).
		if ctx.count > JOLT_MAX_CONTACTS do ctx.count = JOLT_MAX_CONTACTS

		// Filter merge-through: resolve only contacts with bodies we don't pass through (GetUserData on main thread).
		// Floor (surface type 4 or 5) is always solid so the ball can stand; only walls (0-3) merge when same color.
		best := -1
		for i in 0 ..< ctx.count {
			ud := joltc.BodyInterface_GetUserData(jolt_physics.body_interface, ctx.contacts[i].bodyID2)
			if ud != 0 {
				surf := int((ud >> 8) & 0xFF)
				body_color := i32(ud & 0xFF)
				// Same-color walls = merge-through; floor (FLOOR_INNER/FLOOR_OUTER) = always solid
				if surf >= 0 && surf <= 3 && body_color == player_color do continue
			}
			if best < 0 || ctx.contacts[i].depth > ctx.contacts[best].depth do best = i
		}
		if best < 0 do break
		if best >= ctx.count do break  // safety: never use out-of-range index
		c := &ctx.contacts[best]
		pos[0] += c.axis[0] * c.depth
		pos[1] += c.axis[1] * c.depth
		pos[2] += c.axis[2] * c.depth

		trans[0], trans[1], trans[2] = pos[0], pos[1], pos[2]
		joltc.Mat4_Translation(&transform, &trans)
	}
}

// --- Projectile: in yellow wall? (point query) ---
jolt_projectile_in_yellow_ctx :: struct {
	in_yellow: bool,
}

@(private)
jolt_projectile_in_yellow_callback :: proc "c" (_context: rawptr, result: ^joltc.CollidePointResult) {
	ctx := cast(^jolt_projectile_in_yellow_ctx)_context
	if ctx == nil || result == nil do return

	ud := joltc.BodyInterface_GetUserData(jolt_physics.body_interface, result.bodyID)
	if i32(ud & 0xFF) == 3 {  // WALL_COLOR_YELLOW
		ctx.in_yellow = true
	}
}

jolt_projectile_in_yellow :: proc(pos: [3]f32) -> bool {
	if !jolt_physics.initialized do return false

	rpos: joltc.RVec3 = { pos[0], pos[1], pos[2] }
	ctx: jolt_projectile_in_yellow_ctx = { in_yellow = false }

	joltc.NarrowPhaseQuery_CollidePoint2(
		jolt_physics.narrow_query,
		&rpos,
		joltc.CollisionCollectorType.AnyHit,
		jolt_projectile_in_yellow_callback,
		&ctx,
		jolt_physics.broad_phase_filter,
		jolt_physics.object_layer_filter,
		jolt_physics.body_filter,
		jolt_physics.shape_filter,
	)
	return ctx.in_yellow
}

// --- Projectile: hit non-yellow wall? (sphere query, returns hit + push) ---
JOLT_FLOOR_INNER :: 4  // surface type for floor (skip in wall hit)

jolt_projectile_hits_wall_ctx :: struct {
	hit: bool,
	push: [3]f32,
}

@(private)
jolt_projectile_hits_wall_callback :: proc "c" (_context: rawptr, result: ^joltc.CollideShapeResult) {
	ctx := cast(^jolt_projectile_hits_wall_ctx)_context
	if ctx == nil || result == nil do return
	if ctx.hit do return  // already found one

	ud := joltc.BodyInterface_GetUserData(jolt_physics.body_interface, result.bodyID2)
	surf := int((ud >> 8) & 0xFF)
	if surf == JOLT_FLOOR_INNER do return  // skip floor
	if i32(ud & 0xFF) == 3 do return  // WALL_COLOR_YELLOW = merge-through

	ctx.hit = true
	ctx.push[0] = result.penetrationAxis[0] * result.penetrationDepth
	ctx.push[1] = result.penetrationAxis[1] * result.penetrationDepth
	ctx.push[2] = result.penetrationAxis[2] * result.penetrationDepth
}

jolt_projectile_hits_wall :: proc(pos: [3]f32, radius: f32) -> (hit: bool, push: [3]f32) {
	if !jolt_physics.initialized || jolt_physics.sphere_shape == nil do return false, [3]f32{}

	scale: joltc.Vec3 = { radius, radius, radius }
	trans: joltc.Vec3 = { pos[0], pos[1], pos[2] }
	transform: joltc.RMat4
	joltc.Mat4_Identity(&transform)
	joltc.Mat4_Translation(&transform, &trans)

	settings: joltc.CollideShapeSettings
	joltc.CollideShapeSettings_Init(&settings)

	ctx: jolt_projectile_hits_wall_ctx = { hit = false, push = {} }

	joltc.NarrowPhaseQuery_CollideShape2(
		jolt_physics.narrow_query,
		jolt_physics.sphere_shape,
		&scale,
		&transform,
		&settings,
		nil,
		joltc.CollisionCollectorType.AnyHit,
		jolt_projectile_hits_wall_callback,
		&ctx,
		jolt_physics.broad_phase_filter,
		jolt_physics.object_layer_filter,
		jolt_physics.body_filter,
		jolt_physics.shape_filter,
	)
	return ctx.hit, ctx.push
}
