extends Node3D
## Everything you can see. Built in code from primitives — no imported models,
## so the whole export stays small and there's nothing to go missing.

const PLATEAU_H := 150.0
const TOWER_XZ := 128.0
const TOWER_TOP := PLATEAU_H + 62.0
const FLAK_BURST_R := 58.0

var cam: Camera3D
var _cam_pos := Vector3(0, 300, 900)
var _cam_q := Quaternion.IDENTITY
var _planes := {}          # pid -> Dictionary {root, prop, alive}
var _tracers: Array[MeshInstance3D] = []
var _shells: Array[MeshInstance3D] = []
var _bursts: Array = []    # {node, t, life, r}
var _burst_pool: Array[MeshInstance3D] = []
var _built := false
var _cam_ready := false

var _mat_tracer: StandardMaterial3D
var _mat_burst: StandardMaterial3D
var _mat_shell: StandardMaterial3D


func _ready() -> void:
	cam = Camera3D.new()
	cam.fov = 72.0
	cam.near = 0.4
	cam.far = 4200.0
	add_child(cam)
	cam.current = true

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 38, 0)
	sun.light_energy = 1.15
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 700.0
	add_child(sun)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.20, 0.42, 0.72)
	sky_mat.sky_horizon_color = Color(0.72, 0.80, 0.86)
	sky_mat.ground_bottom_color = Color(0.24, 0.34, 0.42)
	sky_mat.ground_horizon_color = Color(0.72, 0.80, 0.86)
	sky_mat.sun_angle_max = 12.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.85
	env.fog_enabled = true
	env.fog_light_color = Color(0.70, 0.79, 0.87)
	env.fog_density = 0.0011
	we.environment = env
	add_child(we)

	_mat_tracer = StandardMaterial3D.new()
	_mat_tracer.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_tracer.albedo_color = Color(1.0, 0.86, 0.42)
	_mat_tracer.emission_enabled = true
	_mat_tracer.emission = Color(1.0, 0.78, 0.3)
	_mat_tracer.emission_energy_multiplier = 2.0

	_mat_shell = StandardMaterial3D.new()
	_mat_shell.albedo_color = Color(0.15, 0.15, 0.16)

	_mat_burst = StandardMaterial3D.new()
	_mat_burst.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_burst.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_burst.albedo_color = Color(0.12, 0.12, 0.13, 0.85)

	Sfx.attach(self)
	GameState.match_ready.connect(_on_match_ready)
	GameState.flak_burst.connect(_on_flak_burst)
	GameState.hit_marker.connect(_on_hit)
	GameState.death.connect(_on_death)


# --- building ------------------------------------------------------------

func _on_match_ready() -> void:
	_clear()
	_build_terrain()
	_build_sea()
	_build_castle()
	for pid in GameState.players:
		var p: Dictionary = GameState.players[pid]
		var node := _make_plane(p.color)
		add_child(node)
		_planes[pid] = {"root": node, "prop": node.get_meta("prop"), "dead": false}
	_built = true
	_cam_ready = false
	Sfx.engine_start()


func _clear() -> void:
	for pid in _planes:
		_planes[pid].root.queue_free()
	_planes.clear()
	for t in _tracers:
		t.queue_free()
	_tracers.clear()
	for s in _shells:
		s.queue_free()
	_shells.clear()
	for b in _bursts:
		b.node.queue_free()
	_bursts.clear()
	_burst_pool.clear()
	for c in get_children():
		if c.has_meta("scenery"):
			c.queue_free()


func _scenery(n: Node3D) -> void:
	n.set_meta("scenery", true)
	add_child(n)


func _build_terrain() -> void:
	var n := GameState.hmap_n
	if GameState.hmap.size() < n * n:
		return
	var world := GameState.world
	var max_h := GameState.max_h
	var step := world / float(n - 1)

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	verts.resize(n * n)
	norms.resize(n * n)
	cols.resize(n * n)

	for j in n:
		for i in n:
			var h := (float(GameState.hmap[j * n + i]) / 255.0) * max_h
			var x := -world * 0.5 + float(i) * step
			var z := -world * 0.5 + float(j) * step
			verts[j * n + i] = Vector3(x, h, z)

	# Central differences for normals — cheaper and smoother than face averaging.
	for j in n:
		for i in n:
			var hl := _h(i - 1, j, n, max_h)
			var hr := _h(i + 1, j, n, max_h)
			var hd := _h(i, j - 1, n, max_h)
			var hu := _h(i, j + 1, n, max_h)
			var nrm := Vector3(hl - hr, 2.0 * step, hd - hu).normalized()
			norms[j * n + i] = nrm
			cols[j * n + i] = _ground_color(verts[j * n + i].y, nrm.y)

	var idx := PackedInt32Array()
	idx.resize((n - 1) * (n - 1) * 6)
	var k := 0
	for j in n - 1:
		for i in n - 1:
			var a := j * n + i
			var b := j * n + i + 1
			var c := (j + 1) * n + i
			var d := (j + 1) * n + i + 1
			idx[k] = a; idx[k + 1] = c; idx[k + 2] = b
			idx[k + 3] = b; idx[k + 4] = c; idx[k + 5] = d
			k += 6

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	_scenery(mi)


func _h(i: int, j: int, n: int, max_h: float) -> float:
	var ci := clampi(i, 0, n - 1)
	var cj := clampi(j, 0, n - 1)
	return (float(GameState.hmap[cj * n + ci]) / 255.0) * max_h


func _ground_color(h: float, up: float) -> Color:
	var sand := Color(0.80, 0.73, 0.52)
	var grass := Color(0.27, 0.40, 0.21)
	var grass2 := Color(0.36, 0.47, 0.25)
	var rock := Color(0.44, 0.42, 0.39)
	var c: Color
	if h < 5.0:
		c = sand
	elif h < 18.0:
		c = sand.lerp(grass, (h - 5.0) / 13.0)
	elif h < 120.0:
		c = grass.lerp(grass2, (h - 18.0) / 102.0)
	else:
		c = grass2.lerp(rock, clampf((h - 120.0) / 80.0, 0.0, 1.0))
	# Anything steep is bare rock, whatever height it's at.
	if up < 0.82 and h > 8.0:
		c = c.lerp(rock, clampf((0.82 - up) / 0.35, 0.0, 1.0))
	return c


func _build_sea() -> void:
	var pm := PlaneMesh.new()
	pm.size = Vector2(9000, 9000)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.33, 0.48)
	mat.roughness = 0.12
	mat.metallic = 0.35
	var mi := MeshInstance3D.new()
	mi.mesh = pm
	mi.material_override = mat
	mi.position = Vector3(0, 0, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_scenery(mi)


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _build_castle() -> void:
	var root := Node3D.new()
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.55, 0.53, 0.48)
	stone.roughness = 0.9
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.34, 0.30, 0.28)
	dark.roughness = 0.9
	var banner := StandardMaterial3D.new()
	banner.albedo_color = Color(0.66, 0.21, 0.17)

	# Curtain wall between the towers.
	var wall_h := 34.0
	var span := TOWER_XZ * 2.0
	for s in [-1.0, 1.0]:
		_box(root, Vector3(span, wall_h, 10), Vector3(0, PLATEAU_H + wall_h * 0.5, s * TOWER_XZ), stone)
		_box(root, Vector3(10, wall_h, span), Vector3(s * TOWER_XZ, PLATEAU_H + wall_h * 0.5, 0), stone)

	# Battlements — the silhouette is most of what makes it read as a castle.
	for i in range(-6, 7):
		var o := float(i) * 20.0
		for s in [-1.0, 1.0]:
			_box(root, Vector3(9, 6, 10), Vector3(o, PLATEAU_H + wall_h + 3.0, s * TOWER_XZ), stone)
			_box(root, Vector3(10, 6, 9), Vector3(s * TOWER_XZ, PLATEAU_H + wall_h + 3.0, o), stone)

	# Keep.
	_box(root, Vector3(86, 74, 86), Vector3(0, PLATEAU_H + 37, 0), stone)
	_box(root, Vector3(94, 6, 94), Vector3(0, PLATEAU_H + 76, 0), dark)
	_box(root, Vector3(2, 20, 2), Vector3(0, PLATEAU_H + 88, 0), dark)
	_box(root, Vector3(14, 9, 1), Vector3(7.5, PLATEAU_H + 93, 0), banner)

	# Towers, with the guns on top.
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var cyl := CylinderMesh.new()
			cyl.top_radius = 17.0
			cyl.bottom_radius = 20.0
			cyl.height = 62.0
			cyl.radial_segments = 12
			var t := MeshInstance3D.new()
			t.mesh = cyl
			t.material_override = stone
			t.position = Vector3(sx * TOWER_XZ, PLATEAU_H + 31.0, sz * TOWER_XZ)
			root.add_child(t)

			var cap := CylinderMesh.new()
			cap.top_radius = 21.0
			cap.bottom_radius = 21.0
			cap.height = 4.0
			cap.radial_segments = 12
			var cp := MeshInstance3D.new()
			cp.mesh = cap
			cp.material_override = dark
			cp.position = Vector3(sx * TOWER_XZ, TOWER_TOP, sz * TOWER_XZ)
			root.add_child(cp)

			# The gun itself: a stub barrel angled at the sky.
			var gun := Node3D.new()
			gun.position = Vector3(sx * TOWER_XZ, TOWER_TOP + 3.0, sz * TOWER_XZ)
			root.add_child(gun)
			_box(gun, Vector3(9, 4, 9), Vector3(0, 1, 0), dark)
			var barrel := _box(gun, Vector3(1.7, 1.7, 17), Vector3(0, 4.5, 0), dark)
			barrel.rotation_degrees = Vector3(-52, sx * sz * 24.0, 0)

	_scenery(root)


func _make_plane(col: Color) -> Node3D:
	var root := Node3D.new()
	var body := StandardMaterial3D.new()
	body.albedo_color = col
	body.roughness = 0.6
	var wing := StandardMaterial3D.new()
	wing.albedo_color = col.darkened(0.32)
	wing.roughness = 0.6
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.12, 0.13, 0.15)
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.35, 0.5, 0.6)
	glass.metallic = 0.6
	glass.roughness = 0.15

	_box(root, Vector3(3.0, 3.0, 15.0), Vector3(0, 0, 0), body)
	_box(root, Vector3(2.1, 2.1, 3.2), Vector3(0, 0, -8.6), dark)
	_box(root, Vector3(23.0, 0.7, 4.6), Vector3(0, -0.5, 0.6), wing)
	_box(root, Vector3(9.0, 0.6, 2.6), Vector3(0, 0.5, 6.3), wing)
	_box(root, Vector3(0.6, 4.0, 2.8), Vector3(0, 2.2, 6.4), wing)
	_box(root, Vector3(2.0, 1.3, 3.8), Vector3(0, 1.7, -0.6), glass)
	# Wingtips in the darker shade read as roundels at distance.
	_box(root, Vector3(3.0, 0.8, 4.8), Vector3(-10.4, -0.5, 0.6), dark)
	_box(root, Vector3(3.0, 0.8, 4.8), Vector3(10.4, -0.5, 0.6), dark)

	var disc := CylinderMesh.new()
	disc.top_radius = 3.6
	disc.bottom_radius = 3.6
	disc.height = 0.2
	disc.radial_segments = 10
	var prop := MeshInstance3D.new()
	prop.mesh = disc
	var pm := StandardMaterial3D.new()
	pm.albedo_color = Color(0.1, 0.1, 0.1, 0.35)
	pm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	prop.material_override = pm
	prop.rotation_degrees = Vector3(90, 0, 0)
	prop.position = Vector3(0, 0, -10.3)
	root.add_child(prop)
	root.set_meta("prop", prop)
	return root


# --- effects -------------------------------------------------------------

func _on_hit(pos: Vector3) -> void:
	Sfx.play_at("hit", pos, -4.0)
	_spawn_burst(pos, 7.0, 0.22, Color(1.0, 0.85, 0.4, 0.9))


func _on_flak_burst(pos: Vector3) -> void:
	Sfx.play_at("flak", pos, 2.0)
	_spawn_burst(pos, FLAK_BURST_R, 1.5, Color(0.14, 0.14, 0.15, 0.9))


func _on_death(pid: int, _cause: String, pos: Vector3) -> void:
	Sfx.play_at("boom", pos, 4.0)
	_spawn_burst(pos, 46.0, 1.3, Color(1.0, 0.55, 0.15, 0.95))
	_spawn_burst(pos, 70.0, 2.4, Color(0.16, 0.15, 0.15, 0.8))
	if _planes.has(pid):
		_planes[pid].dead = true
		_planes[pid].root.visible = false


func _spawn_burst(pos: Vector3, r: float, life: float, col: Color) -> void:
	var mi: MeshInstance3D
	if _burst_pool.size() > 0:
		mi = _burst_pool.pop_back()
		mi.visible = true
	else:
		var sm := SphereMesh.new()
		sm.radius = 1.0
		sm.height = 2.0
		sm.radial_segments = 10
		sm.rings = 6
		mi = MeshInstance3D.new()
		mi.mesh = sm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
	var m := _mat_burst.duplicate()
	m.albedo_color = col
	mi.material_override = m
	mi.global_position = pos
	mi.scale = Vector3.ONE * 0.1
	_bursts.append({"node": mi, "t": 0.0, "life": life, "r": r, "mat": m, "col": col})


func _step_bursts(delta: float) -> void:
	for i in range(_bursts.size() - 1, -1, -1):
		var b: Dictionary = _bursts[i]
		b.t += delta
		var k: float = clampf(b.t / b.life, 0.0, 1.0)
		var s: float = b.r * (0.25 + 0.75 * sqrt(k))
		b.node.scale = Vector3.ONE * s
		var c: Color = b.col
		c.a = b.col.a * (1.0 - k)
		b.mat.albedo_color = c
		if k >= 1.0:
			b.node.visible = false
			_burst_pool.append(b.node)
			_bursts.remove_at(i)


func _sync_pool(pool: Array, want: int, radius: float, mat: Material) -> void:
	while pool.size() < want:
		var mi := MeshInstance3D.new()
		if radius > 0.0:
			var sm := SphereMesh.new()
			sm.radius = radius
			sm.height = radius * 2.0
			sm.radial_segments = 6
			sm.rings = 4
			mi.mesh = sm
		else:
			var bm := BoxMesh.new()
			bm.size = Vector3(0.4, 0.4, 4.5)
			mi.mesh = bm
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		pool.append(mi)


# --- per-frame -----------------------------------------------------------

func _process(delta: float) -> void:
	if not _built or not GameState.live:
		_step_bursts(delta)
		return

	for pid in GameState.players:
		var p: Dictionary = GameState.players[pid]
		if not _planes.has(pid) or not p.spawned:
			continue
		var e: Dictionary = _planes[pid]
		if not p.alive:
			e.root.visible = false
			continue
		e.root.visible = true
		e.root.global_transform = Transform3D(Basis(p.q), p.pos)
		e.prop.rotate_object_local(Vector3(0, 1, 0), delta * 42.0)

	# Tracers.
	_sync_pool(_tracers, GameState.bullets.size(), 0.0, _mat_tracer)
	var i := 0
	for id in GameState.bullets:
		var b: Dictionary = GameState.bullets[id]
		var t := _tracers[i]
		t.visible = true
		var dir: Vector3 = b.vel.normalized()
		var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
		t.global_transform = Transform3D(Basis.looking_at(dir, up), b.pos)
		i += 1
	for j in range(i, _tracers.size()):
		_tracers[j].visible = false

	# Flak shells in flight — seeing them coming is the whole point.
	_sync_pool(_shells, GameState.shells.size(), 1.4, _mat_shell)
	i = 0
	for id in GameState.shells:
		var s: Dictionary = GameState.shells[id]
		_shells[i].visible = true
		_shells[i].global_position = s.pos
		i += 1
	for j in range(i, _shells.size()):
		_shells[j].visible = false

	_step_bursts(delta)
	_update_camera(delta)

	var me: Dictionary = GameState.me()
	if not me.is_empty():
		Sfx.engine_set(me.get("speed", 0.0), me.get("alive", false))


func _update_camera(delta: float) -> void:
	var me: Dictionary = GameState.me()
	if me.is_empty() or not me.spawned:
		return

	var b := Basis(me.q)
	if not _cam_ready:
		# First frame we actually know where we are — start behind the aircraft
		# rather than flying the camera in from wherever it was left.
		_cam_ready = true
		_cam_pos = me.pos + b.y * 5.5 + b.z * 22.0
		_cam_q = Quaternion(Basis.looking_at(-b.z, b.y))
	var want_pos: Vector3 = me.pos + b.y * 5.5 + b.z * 22.0
	var look_at: Vector3 = me.pos - b.z * 42.0
	var up: Vector3 = b.y

	if not me.alive:
		# Hang back and watch the wreck rather than riding it into the ground.
		want_pos = me.pos + Vector3(0, 26, 0) + b.z * 46.0
		look_at = me.pos
		up = Vector3.UP

	_cam_pos = _cam_pos.lerp(want_pos, 1.0 - exp(-10.0 * delta))
	# Never let the camera end up inside the island.
	var floor_y := GameState.height_at(_cam_pos.x, _cam_pos.z) + 4.0
	_cam_pos.y = maxf(_cam_pos.y, maxf(floor_y, 2.0))

	var dir := look_at - _cam_pos
	if dir.length() > 0.01:
		if absf(dir.normalized().dot(up)) > 0.995:
			up = Vector3.UP
		var want_q := Quaternion(Basis.looking_at(dir.normalized(), up))
		_cam_q = _cam_q.slerp(want_q, 1.0 - exp(-12.0 * delta))

	cam.global_transform = Transform3D(Basis(_cam_q), _cam_pos)
	# A touch of FOV with speed does more for the sense of pace than the number does.
	cam.fov = lerpf(cam.fov, 68.0 + clampf(me.speed / 170.0, 0.0, 1.2) * 12.0, 1.0 - exp(-3.0 * delta))
