# Team asset drop-in

Put the models the rest of the team produces in this folder as `.glb` (preferred)
or `.gltf`, then list where each one goes in `placement.json` next to them.

`placement.json` is a plain JSON array. Every field except `model` is optional:

```json
[
  {
    "model": "warehouse_ruin.glb",
    "position": [40, 0, -30],
    "yaw": 90,
    "scale": 1.0,
    "collide": true,
    "snap_to_ground": true
  }
]
```

| Field | Meaning |
| --- | --- |
| `model` | File name inside `assets/team/`. |
| `position` | `[x, y, z]` in metres. The blast seat is at roughly `[0, 0, -12]`, the launch pad at `[0, 0, 96]`. |
| `yaw` | Rotation about the vertical axis, in degrees. |
| `scale` | Uniform scale. Export at metre scale and leave this at 1.0 if you can. |
| `collide` | `true` gives the model a box collider so the drone can hit it. |
| `snap_to_ground` | `true` adds the terrain height at that point to `position.y`. |

If this folder is empty or `placement.json` is missing, the scene builds exactly
as it does now - so nobody is blocked waiting for anyone else's work.

Export notes that matter for this project (from the team's asset research):

- glTF 2.0 binary (`.glb`) keeps geometry, materials and textures in one file.
- Set Blender units to metres and apply rotation and scale before export.
- Delete cameras, lights and hidden demo geometry; lighting is done in-engine.
- Keep a close hero ruin under roughly 250k triangles and mid-distance
  buildings under 80k. Anything photogrammetric needs decimating first.
