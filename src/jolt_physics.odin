// jolt_physics.odin - Jolt Physics integration for 3D Game Engine.
// Creates static world from procedural rooms. Player collision still uses voxel (fallback).
// Jolt world ready for future: dynamic bodies, mesh loading, destructibles.
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

JoltPhysics :: struct {
	job_system:     ^joltc.JobSystem,
	system:         ^joltc.PhysicsSystem,
	body_interface: ^joltc.BodyInterface,
	narrow_query:   ^joltc.NarrowPhaseQuery,
	initialized:    bool,
}

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
	jolt_physics.initialized = true

	// Build static world from level
	jolt_build_static_world(level)
	fmt.eprintln("[Jolt] Physics world ready")
	return true
}

jolt_shutdown :: proc() {
	if !jolt_physics.initialized do return
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
