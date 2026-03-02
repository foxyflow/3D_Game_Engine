// jolt_physics.odin - Jolt Physics integration for 3D Game Engine.
// Environment collision via Jolt. Player stays custom (SDF render, our movement).
package main

import joltc "lib:joltc-odin"
import "core:fmt"

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

jolt_physics: JoltPhysics

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

	// Create accept-all filters (Jolt crashes on nil filters in CollideShape/CollidePoint)
	bp_procs: joltc.BroadPhaseLayerFilter_Procs = { ShouldCollide = jolt_filter_broad }
	joltc.BroadPhaseLayerFilter_SetProcs(&bp_procs)
	jolt_physics.broad_phase_filter = joltc.BroadPhaseLayerFilter_Create(nil)

	obj_procs: joltc.ObjectLayerFilter_Procs = { ShouldCollide = jolt_filter_object }
	joltc.ObjectLayerFilter_SetProcs(&obj_procs)
	jolt_physics.object_layer_filter = joltc.ObjectLayerFilter_Create(nil)

	body_procs: joltc.BodyFilter_Procs = { ShouldCollide = jolt_filter_body, ShouldCollideLocked = jolt_filter_body_locked }
	joltc.BodyFilter_SetProcs(&body_procs)
	jolt_physics.body_filter = joltc.BodyFilter_Create(nil)

	shape_procs: joltc.ShapeFilter_Procs = { ShouldCollide = jolt_filter_shape, ShouldCollide2 = jolt_filter_shape2 }
	joltc.ShapeFilter_SetProcs(&shape_procs)
	jolt_physics.shape_filter = joltc.ShapeFilter_Create(nil)

	jolt_physics.initialized = true

	// Build static world from level
	jolt_build_static_world(level)
	fmt.eprintln("[Jolt] Physics world ready")
	return true
}

jolt_shutdown :: proc() {
	if !jolt_physics.initialized do return
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

	// Level floor (solid, no merge-through)
	floor_half: [3]f32 = {
		(level_floor.max[0] - level_floor.min[0]) * 0.5 + wt,
		wt * 0.5,
		(level_floor.max[2] - level_floor.min[2]) * 0.5 + wt,
	}
	floor_center: [3]f32 = {
		(level_floor.min[0] + level_floor.max[0]) * 0.5,
		level_floor.min[1] + wt * 0.5,
		(level_floor.min[2] + level_floor.max[2]) * 0.5,
	}
	floor_shape := joltc.BoxShape_Create(&floor_half, joltc.DEFAULT_CONVEX_RADIUS)
	floor_settings := joltc.BodyCreationSettings_Create3(
		cast(^joltc.Shape)floor_shape,
		&floor_center,
		nil,
		.Static,
		JOLT_LAYER_NON_MOVING,
	)
	defer joltc.BodyCreationSettings_Destroy(floor_settings)
	_ = joltc.BodyInterface_CreateAndAddBody(bi, floor_settings, .DontActivate)

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

	joltc.PhysicsSystem_OptimizeBroadPhase(jolt_physics.system)
}

// --- Player collision (sphere vs world, merge-through by color) ---
JOLT_MAX_CONTACTS :: 32

jolt_player_contact :: struct {
	axis:  joltc.Vec3,
	depth: f32,
}

jolt_player_collision_ctx :: struct {
	pos:         ^[3]f32,
	player_color: i32,
	contacts:    [JOLT_MAX_CONTACTS]jolt_player_contact,
	count:       int,
}

@(private)
jolt_player_collide_callback :: proc "c" (_context: rawptr, result: ^joltc.CollideShapeResult) {
	ctx := cast(^jolt_player_collision_ctx)_context
	if ctx == nil || result == nil do return
	if ctx.count >= JOLT_MAX_CONTACTS do return

	ud := joltc.BodyInterface_GetUserData(jolt_physics.body_interface, result.bodyID2)
	if ud != 0 {  // user data = merge-through surfaces; ud==0 = solid (level floor)
		body_color := i32(ud & 0xFF)
		if body_color == ctx.player_color do return  // merge-through
	}

	c := &ctx.contacts[ctx.count]
	c.axis = result.penetrationAxis
	c.depth = result.penetrationDepth
	ctx.count += 1
}

jolt_resolve_player_collision :: proc(pos: ^[3]f32, radius: f32, player_color: i32, max_iter: int = 12) {
	if !jolt_physics.initialized || jolt_physics.sphere_shape == nil do return

	scale: joltc.Vec3 = { radius, radius, radius }
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

	for _ in 0 ..< max_iter {
		ctx.count = 0
		joltc.NarrowPhaseQuery_CollideShape2(
			jolt_physics.narrow_query,
			jolt_physics.sphere_shape,
			&scale,
			&transform,
			&settings,
			nil,
			joltc.CollisionCollectorType.AllHit,
			jolt_player_collide_callback,
			&ctx,
			jolt_physics.broad_phase_filter,
			jolt_physics.object_layer_filter,
			jolt_physics.body_filter,
			jolt_physics.shape_filter,
		)
		if ctx.count == 0 do break

		// Push by largest penetration first
		best := 0
		for i in 1 ..< ctx.count {
			if ctx.contacts[i].depth > ctx.contacts[best].depth do best = i
		}
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
