# Voxel AABB Tree Collision System

## Overview

The collision system uses a **3D voxel grid** to approximate the room walls, then builds an **AABB tree** (Bounding Volume Hierarchy) over the occupied voxels for fast sphere-vs-wall collision queries.

```
┌─────────────────────────────────────────────────────────────────┐
│  PIPELINE                                                        │
│                                                                  │
│  1. VOXELIZE     Room walls → 3D grid of occupied voxels         │
│  2. COLLECT      Occupied voxels → list of AABBs (boxes)         │
│  3. BUILD TREE   AABBs → hierarchical AABB tree (BVH)             │
│  4. RESOLVE      Each frame: sphere vs tree → push player out   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Why VOXEL_SIZE = 0.25?

**It was NOT chosen to match the player.** The player sphere has radius 0.5 (diameter 1.0), so the player is about **4 voxels wide**.

The voxel size is a **trade-off**:

| Smaller (e.g. 0.1) | Larger (e.g. 0.5) |
|--------------------|--------------------|
| ✓ Tighter fit to walls | ✓ Fewer voxels, faster |
| ✗ More voxels (slower build, more memory) | ✗ Collision feels blocky, "air" gaps |
| ✗ More tree nodes | ✗ Walls might be missed |

**0.25** was chosen as a middle ground:
- Wall thickness is 0.25 → **1 voxel per wall** in the thin direction
- Room ~8×4×12 units → grid 35×18×51 ≈ **32,000 voxels** (only ~hundreds occupied)
- Player radius 0.5 → player overlaps ~2–4 voxels when near a wall

---

## The 3D Voxel Grid (Conceptual)

The grid covers the room + walls. Each cell is 0.25×0.25×0.25 world units.

**Top-down view (XZ plane, looking down):**  
See `E:\demo_images\voxel_grid_concept.png` for a visual (demo images stored on E: drive).

```
        -Z                                    +Z
         │                                     │
    ┌────┼─────────────────────────────────────┼────┐
    │    │  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │    │  ← back wall voxels
    │    │  ░                                 ░ │    │
    │    │  ░                                 ░ │    │
 -X ────┼───░───  ROOM INTERIOR (empty)  ────░─┼──── +X
    │    │  ░     (no collision here)      ░ │    │
    │    │  ░                                 ░ │    │
    │    │  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │    │  ← front wall voxels
    └────┼─────────────────────────────────────┼────┘
         │              ★ player               │
         │         (sphere, radius 0.5)         │
         └─────────────────────────────────────┘

  ░ = occupied voxel (wall)
  Each ░ is 0.25 × 0.25 in this view
```

**Side view (XZ slice through one wall):**

```
  Y
  │
  │     ┌───┬───┬───┬───┐
  │     │ ░ │ ░ │ ░ │ ░ │  ← wall = row of voxels
  │     ├───┼───┼───┼───┤
  │     │   │   │   │   │
  │     │   │   room   │   │  ← empty voxels (no collision)
  │     │   │   │   │   │
  └─────┴───┴───┴───┴───┴─── X
        0.25 0.25 0.25 0.25
              voxel size
```

---

## The AABB Tree (BVH)

We don't test the sphere against every voxel. That would be O(n) per frame. Instead we build a **binary tree** where:

- **Leaves** = individual voxel AABBs
- **Internal nodes** = bounding box that contains all descendants

```
                    [root: entire room bounds]
                           /        \
                    [left half]    [right half]
                     /    \          /    \
                [..]    [..]     [leaf]  [leaf]
                                    ↑
                              single voxel AABB
```

**Traversal:** Start at root. If sphere doesn't hit the node's AABB, skip entire subtree. If it does, recurse. At leaves, do actual sphere-vs-AABB and compute push.

This gives **O(log n)** average case instead of O(n).

---

## Sphere vs AABB: The Push

When the sphere overlaps a voxel AABB:

1. Find **closest point** on AABB to sphere center (clamp center to box)
2. If distance to closest point < radius → **penetration**
3. Push = (radius - distance) × direction from closest point to center

```
        ┌─────────┐
        │  voxel  │
        │  AABB   │
        │    ●────┼───→ push (sphere center)
        │  closest│
        └─────────┘
             ○
          sphere
```

If center is **inside** the AABB (e.g. stuck), push out along the shortest axis.

---

## Why the Gap?

See `E:\demo_images\voxel_gap_explanation.png` for a cross-section (demo images on E: drive).

The gap you see is because:

1. **Voxels are cubes** – walls are thin planes; we approximate them with cubes. The cube extends 0.25 in all directions, so the collision surface is the full voxel, not the thin wall face.

2. **Push is conservative** – we push until the sphere surface *just* clears the AABB. The AABB is the voxel box, which is slightly larger than the visible wall.

3. **Player radius 0.5** – when the sphere center is 0.5 away from the wall, the sphere surface touches. But our voxels are 0.25; the voxel might start 0.25 from the wall center, so the collision "zone" starts earlier.

To reduce the gap you could: smaller voxels (e.g. 0.125), or use the actual wall geometry for collision instead of voxels (but then you lose the voxel-tree learning aspect).

---

## Summary

| Concept | Value | Purpose |
|---------|-------|---------|
| VOXEL_SIZE | 0.25 | Balance: resolution vs performance |
| Player radius | 0.5 | 2× voxel size |
| Wall thickness | 0.25 | Matches 1 voxel |
| Grid | 35×18×51 | Covers room + walls |
| Tree | Binary BVH | O(log n) collision queries |
