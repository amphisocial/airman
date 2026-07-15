extends Node
## Mirror of the server's world, plus local flight prediction.
##
## The server is authoritative for everything that matters (hits, deaths, flak).
## We predict our own aircraft so the stick feels connected at 30Hz, and gently
## pull back toward the server whenever it disagrees.

signal queued(waiting: int, need: int)
signal match_ready
signal match_ended(winner: int, outcome: String, causes: Array)
signal room_closed
signal player_left(pid: int)
signal hit_marker(pos: Vector3)
signal death(pid: int, cause: String, pos: Vector3)
signal flak_burst(pos: Vector3)
signal shot_fired(pid: int, pos: Vector3)

# --- FLIGHT ---------------------------------------------------------------
# Mirrors server/src/game/flight.js and the FLIGHT block of constants.js.
# If these drift apart the aircraft rubber-bands. Change both together.
const MIN_SPEED := 60.0
const MAX_SPEED := 170.0
const THRUST_K := 0.55
const TURN_DRAG := 20.0
const PITCH_RATE := 1.4
const ROLL_RATE := 3.2
const YAW_RATE := 0.45
const TURN_COEF := 0.95
const CLIMB_DRAG := 34.0
const STALL_SPEED := 66.0
const CORNER_SPEED := 115.0
# --- end FLIGHT -----------------------------------------------------------

const DT := 1.0 / 30.0
const BULLET_LIFE := 2.0

var you := -1
var players := {}          # pid -> Dictionary
var bullets := {}          # id -> {pos, vel, ttl, owner}
var shells := {}           # id -> {pos, vel, fuse}
var hmap := PackedByteArray()
var hmap_n := 128
var world := 3000.0
var max_h := 240.0
var play_radius := 1400.0
var match_time := 300.0
var time_left := 300.0
var ammo_max := 500
var live := false

var input := {"pitch": 0.0, "roll": 0.0, "yaw": 0.0, "throttle": 0.75, "fire": false}
var _acc := 0.0
var _send_at := 0.0


func reset() -> void:
	players.clear()
	bullets.clear()
	shells.clear()
	you = -1
	live = false
	_acc = 0.0
	input = {"pitch": 0.0, "roll": 0.0, "yaw": 0.0, "throttle": 0.75, "fire": false}


## Bilinear height. Mirrors heightAt() in terrain.js — and reads the very same
## quantized bytes the server collides against, so we can't disagree about a hill.
func height_at(x: float, z: float) -> float:
	if hmap.is_empty():
		return 0.0
	var half := world * 0.5
	var fx := ((x + half) / world) * float(hmap_n - 1)
	var fz := ((z + half) / world) * float(hmap_n - 1)
	if fx < 0.0 or fz < 0.0 or fx > float(hmap_n - 1) or fz > float(hmap_n - 1):
		return 0.0
	var i := int(floor(fx))
	var j := int(floor(fz))
	var i2 := mini(hmap_n - 1, i + 1)
	var j2 := mini(hmap_n - 1, j + 1)
	var tx := fx - float(i)
	var tz := fz - float(j)
	var a := float(hmap[j * hmap_n + i])
	var b := float(hmap[j * hmap_n + i2])
	var c := float(hmap[j2 * hmap_n + i])
	var d := float(hmap[j2 * hmap_n + i2])
	var top: float = a * (1.0 - tx) + b * tx
	var bot: float = c * (1.0 - tx) + d * tx
	return ((top * (1.0 - tz) + bot * tz) / 255.0) * max_h


## One step of the flight model — the GDScript twin of stepFlight() in flight.js.
static func step_flight(pos: Vector3, q: Quaternion, speed: float, inp: Dictionary, dt: float) -> Dictionary:
	var pitch: float = clampf(inp.get("pitch", 0.0), -1.0, 1.0)
	var roll: float = clampf(inp.get("roll", 0.0), -1.0, 1.0)
	var yaw: float = clampf(inp.get("yaw", 0.0), -1.0, 1.0)
	var throttle: float = clampf(inp.get("throttle", 0.7), 0.0, 1.0)

	var auth := clampf((speed - MIN_SPEED * 0.55) / (STALL_SPEED - MIN_SPEED * 0.55), 0.22, 1.0)
	var rate := 0.0
	if speed <= CORNER_SPEED:
		rate = clampf(speed / CORNER_SPEED, 0.3, 1.0)
	else:
		rate = clampf(CORNER_SPEED / speed, 0.55, 1.0)

	q = q * Quaternion(Vector3(0, 0, -1), roll * ROLL_RATE * dt * auth)
	q = q * Quaternion(Vector3(1, 0, 0), pitch * PITCH_RATE * dt * auth * rate)
	q = q * Quaternion(Vector3(0, 1, 0), -yaw * YAW_RATE * dt * auth)
	q = q.normalized()

	var up := q * Vector3(0, 1, 0)
	var right := q * Vector3(1, 0, 0)
	var bank := atan2(-right.y, up.y)
	var turn := -sin(bank) * TURN_COEF * auth * rate
	q = (Quaternion(Vector3(0, 1, 0), turn * dt) * q).normalized()

	var target := MIN_SPEED + throttle * (MAX_SPEED - MIN_SPEED)
	speed += (target - speed) * THRUST_K * dt
	var f := q * Vector3(0, 0, -1)
	speed -= f.y * CLIMB_DRAG * dt
	speed -= absf(pitch) * auth * TURN_DRAG * dt
	speed = clampf(speed, 22.0, MAX_SPEED * 1.3)

	if speed < STALL_SPEED:
		var droop := (1.0 - speed / STALL_SPEED) * 1.6 * dt
		var nf := (f + Vector3(0, -droop, 0)).normalized()
		var ref := q * Vector3(0, 1, 0)
		if absf(nf.dot(ref)) > 0.999:
			ref = q * Vector3(1, 0, 0)
		q = Quaternion(Basis.looking_at(nf, ref))
		f = q * Vector3(0, 0, -1)

	pos += f * speed * dt
	return {"pos": pos, "q": q, "speed": speed}


func me() -> Dictionary:
	return players.get(you, {})


func foe() -> Dictionary:
	for pid in players:
		if pid != you:
			return players[pid]
	return {}


# --- wire ----------------------------------------------------------------

func on_message(m: Dictionary) -> void:
	match m.get("t", ""):
		"queued":
			queued.emit(int(m.get("waiting", 1)), int(m.get("need", 2)))
		"match":
			_start_match(m)
		"s":
			_snapshot(m)
		"matchEnd":
			live = false
			match_ended.emit(int(m.get("winner", -1)) if m.get("winner") != null else -1,
				str(m.get("outcome", "fell")), m.get("cause", []))
		"left":
			player_left.emit(int(m.get("pid", -1)))
		"closed":
			room_closed.emit()


func _start_match(m: Dictionary) -> void:
	reset()
	you = int(m.get("you", 0))
	hmap_n = int(m.get("hmapN", 128))
	world = float(m.get("world", 3000.0))
	max_h = float(m.get("maxH", 240.0))
	play_radius = float(m.get("playRadius", 1400.0))
	match_time = float(m.get("matchTime", 300.0))
	time_left = match_time
	ammo_max = int(m.get("ammo", 500))
	hmap = Marshalls.base64_to_raw(str(m.get("terrain", "")))

	for row in m.get("players", []):
		var pid := int(row.get("pid", 0))
		players[pid] = {
			"pid": pid,
			"name": str(row.get("name", "?")),
			"color": Color(str(row.get("color", "#ffffff"))),
			"bot": bool(row.get("bot", false)),
			"pos": Vector3.ZERO, "q": Quaternion.IDENTITY, "speed": 0.0,
			"srv_pos": Vector3.ZERO, "srv_q": Quaternion.IDENTITY, "srv_speed": 0.0,
			"hp": 100, "ammo": ammo_max, "alive": true, "oob": false,
			"spawned": false, "was_firing": false,
		}
	live = true
	match_ready.emit()


func _snapshot(m: Dictionary) -> void:
	time_left = float(m.get("tl", time_left))

	for row in m.get("p", []):
		var pid := int(row[0])
		if not players.has(pid):
			continue
		var p: Dictionary = players[pid]
		p.srv_pos = Vector3(float(row[1]), float(row[2]), float(row[3]))
		p.srv_q = Quaternion(float(row[4]), float(row[5]), float(row[6]), float(row[7])).normalized()
		p.srv_speed = float(row[8])
		p.hp = int(row[9])
		p.ammo = int(row[10])
		p.alive = int(row[11]) == 1
		p.oob = int(row[12]) == 1

		if not p.spawned:
			p.pos = p.srv_pos
			p.q = p.srv_q
			p.speed = p.srv_speed
			p.spawned = true
		elif pid == you:
			# Prediction can only drift so far before it's lying to the player.
			if p.pos.distance_to(p.srv_pos) > 45.0 or not p.alive:
				p.pos = p.srv_pos
				p.q = p.srv_q
				p.speed = p.srv_speed

	for b in m.get("nb", []):
		var id := int(b[0])
		bullets[id] = {
			"pos": Vector3(float(b[1]), float(b[2]), float(b[3])),
			"vel": Vector3(float(b[4]), float(b[5]), float(b[6])),
			"ttl": BULLET_LIFE, "owner": int(b[7]),
		}
		shot_fired.emit(int(b[7]), bullets[id].pos)

	for id in m.get("db", []):
		bullets.erase(int(id))

	for s in m.get("nf", []):
		shells[int(s[0])] = {
			"pos": Vector3(float(s[1]), float(s[2]), float(s[3])),
			"vel": Vector3(float(s[4]), float(s[5]), float(s[6])),
			"fuse": float(s[7]),
		}

	for h in m.get("h", []):
		hit_marker.emit(Vector3(float(h[0]), float(h[1]), float(h[2])))

	for d in m.get("dd", []):
		death.emit(int(d[0]), str(d[1]), Vector3(float(d[2]), float(d[3]), float(d[4])))


# --- local simulation ----------------------------------------------------

func _process(delta: float) -> void:
	if not live:
		return

	# Our own aircraft runs the real model at the server's tick rate; anything
	# else and the prediction wanders off on its own.
	_acc += delta
	var guard := 0
	while _acc >= DT and guard < 6:
		_acc -= DT
		guard += 1
		var p: Dictionary = players.get(you, {})
		if not p.is_empty() and p.alive and p.spawned:
			var r := step_flight(p.pos, p.q, p.speed, input, DT)
			p.pos = r.pos
			p.q = r.q
			p.speed = r.speed
			# Ease onto the server's answer rather than snapping every tick.
			p.pos = p.pos.lerp(p.srv_pos, 0.09)
			p.q = p.q.slerp(p.srv_q, 0.11)
			p.speed = lerpf(p.speed, p.srv_speed, 0.14)

	# The other aircraft: carry it forward on its last known heading, then ease
	# toward each snapshot. At 30Hz that reads as smooth flight, not teleporting.
	for pid in players:
		if pid == you:
			continue
		var q: Dictionary = players[pid]
		if not q.spawned or not q.alive:
			continue
		q.pos += (q.q * Vector3(0, 0, -1)) * q.speed * delta
		q.pos = q.pos.lerp(q.srv_pos, 1.0 - exp(-9.0 * delta))
		q.q = q.q.slerp(q.srv_q, 1.0 - exp(-11.0 * delta))
		q.speed = lerpf(q.speed, q.srv_speed, 1.0 - exp(-8.0 * delta))

	for id in bullets.keys():
		var b: Dictionary = bullets[id]
		b.pos += b.vel * delta
		b.ttl -= delta
		if b.ttl <= 0.0:
			bullets.erase(id)

	for id in shells.keys():
		var s: Dictionary = shells[id]
		s.pos += s.vel * delta
		s.fuse -= delta
		if s.fuse <= 0.0:
			flak_burst.emit(s.pos)
			shells.erase(id)

	# Inputs at 30Hz. The server clamps and rate-limits anyway.
	_send_at -= delta
	if _send_at <= 0.0:
		_send_at = DT
		Net.send({
			"t": "input",
			"p": input.pitch, "r": input.roll, "y": input.yaw,
			"th": input.throttle, "f": input.fire,
		})
