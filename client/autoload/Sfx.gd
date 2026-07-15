extends Node
## Every sound in Airman is synthesised at boot into AudioStreamWAV.
##
## No .wav files means nothing to import, nothing to mis-configure in the export,
## and no binary blobs in the repo. It also sidesteps the web export's sample
## playback restrictions, since these are plain samples rather than a live
## generator.

const RATE := 22050

var _bank := {}
var _pool: Array[AudioStreamPlayer3D] = []
var _flat: Array[AudioStreamPlayer] = []
var _engine: AudioStreamPlayer
var _host: Node3D = null


func _ready() -> void:
	_bank["gun"] = _gun()
	_bank["hit"] = _hit()
	_bank["boom"] = _boom(1.5, 1.0)
	_bank["flak"] = _flak()
	_bank["victory"] = _victory()
	_bank["defeat"] = _defeat()
	_bank["engine"] = _engine_loop()

	for i in 10:
		var p := AudioStreamPlayer3D.new()
		p.max_distance = 900.0
		p.unit_size = 60.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_pool.append(p)

	for i in 4:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_flat.append(p)

	_engine = AudioStreamPlayer.new()
	_engine.stream = _bank["engine"]
	_engine.volume_db = -16.0
	add_child(_engine)


## World sounds need somewhere in the 3D scene to live.
func attach(host: Node3D) -> void:
	_host = host
	for p in _pool:
		if p.get_parent():
			p.get_parent().remove_child(p)
		host.add_child(p)


func play_at(name: String, pos: Vector3, db := 0.0) -> void:
	if not _bank.has(name) or _host == null:
		return
	for p in _pool:
		if not p.playing:
			p.global_position = pos
			p.stream = _bank[name]
			p.volume_db = db
			p.pitch_scale = randf_range(0.94, 1.06)
			p.play()
			return


func play(name: String, db := 0.0) -> void:
	if not _bank.has(name):
		return
	for p in _flat:
		if not p.playing:
			p.stream = _bank[name]
			p.volume_db = db
			p.play()
			return


func engine_start() -> void:
	if not _engine.playing:
		_engine.play()


func engine_stop() -> void:
	_engine.stop()


## Speed rides the pitch. It's most of what makes a plane feel like a plane.
func engine_set(speed: float, alive: bool) -> void:
	if not alive:
		_engine.volume_db = -60.0
		return
	_engine.volume_db = -16.0
	_engine.pitch_scale = clampf(0.62 + speed / 170.0 * 0.75, 0.5, 1.7)


# --- synthesis -----------------------------------------------------------

func _wav(s: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var st := AudioStreamWAV.new()
	st.format = AudioStreamWAV.FORMAT_16_BITS
	st.mix_rate = RATE
	st.stereo = false
	var b := PackedByteArray()
	b.resize(s.size() * 2)
	for i in s.size():
		b.encode_s16(i * 2, int(clampf(s[i], -1.0, 1.0) * 32767.0))
	st.data = b
	if loop:
		st.loop_mode = AudioStreamWAV.LOOP_FORWARD
		st.loop_begin = 0
		st.loop_end = s.size()
	return st


func _gun() -> AudioStreamWAV:
	var n := int(RATE * 0.085)
	var s := PackedFloat32Array()
	s.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in n:
		var t := float(i) / RATE
		var env: float = exp(-t * 52.0)
		var crack := rng.randf_range(-1.0, 1.0) * 0.6
		var body := sin(TAU * 150.0 * t) * 0.75 + sin(TAU * 82.0 * t) * 0.4
		s[i] = (crack + body) * env * 0.5
	return _wav(s)


func _hit() -> AudioStreamWAV:
	var n := int(RATE * 0.18)
	var s := PackedFloat32Array()
	s.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	for i in n:
		var t := float(i) / RATE
		var env: float = exp(-t * 24.0)
		var ping := sin(TAU * 1720.0 * t) * 0.5 + sin(TAU * 2480.0 * t) * 0.28
		s[i] = (ping + rng.randf_range(-1.0, 1.0) * 0.22) * env * 0.45
	return _wav(s)


func _boom(dur: float, pitch: float) -> AudioStreamWAV:
	var n := int(RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 37
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		# Low-passed noise is the body of any explosion; the sine underneath is
		# the thump you feel rather than hear.
		lp = lp * 0.86 + rng.randf_range(-1.0, 1.0) * 0.14
		var env: float = exp(-t * 3.4)
		var crack: float = exp(-t * 30.0) * rng.randf_range(-1.0, 1.0) * 0.5
		var rumble := sin(TAU * 48.0 * pitch * t + sin(TAU * 3.0 * t)) * 0.6
		s[i] = (lp * 5.0 * env + rumble * env + crack) * 0.5
	return _wav(s)


func _flak() -> AudioStreamWAV:
	var n := int(RATE * 0.7)
	var s := PackedFloat32Array()
	s.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 53
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		lp = lp * 0.78 + rng.randf_range(-1.0, 1.0) * 0.22
		var env: float = exp(-t * 8.0)
		s[i] = (lp * 3.2 + sin(TAU * 96.0 * t) * 0.5) * env * 0.5
	return _wav(s)


## The payoff. A four-note bugle call — this is the sound of the castle standing.
func _victory() -> AudioStreamWAV:
	var notes := [
		{"f": 392.00, "at": 0.00, "len": 0.19},
		{"f": 523.25, "at": 0.19, "len": 0.19},
		{"f": 659.25, "at": 0.38, "len": 0.19},
		{"f": 783.99, "at": 0.57, "len": 0.72},
		{"f": 659.25, "at": 0.57, "len": 0.72},
		{"f": 523.25, "at": 0.57, "len": 0.72},
	]
	var n := int(RATE * 1.5)
	var s := PackedFloat32Array()
	s.resize(n)
	for note in notes:
		var start := int(note.at * RATE)
		var count := int(note.len * RATE)
		for k in count:
			var i := start + k
			if i >= n:
				break
			var t := float(k) / RATE
			# Quick attack, slow release — brassy rather than organ-like.
			var env: float = minf(t / 0.012, 1.0) * exp(-t * 2.2)
			var vib := 1.0 + sin(TAU * 5.5 * t) * 0.004
			var f: float = note.f * vib
			var v := 0.0
			for h in range(1, 7):
				v += sin(TAU * f * float(h) * t) * (1.0 / float(h * h)) * (1.0 if h % 2 == 1 else 0.6)
			s[i] += v * env * 0.24
	return _wav(s)


## The castle coming down: a minor fall over a long collapse.
func _defeat() -> AudioStreamWAV:
	var notes := [
		{"f": 329.63, "at": 0.00, "len": 0.34},
		{"f": 261.63, "at": 0.30, "len": 0.34},
		{"f": 220.00, "at": 0.60, "len": 1.1},
		{"f": 164.81, "at": 0.60, "len": 1.1},
	]
	var n := int(RATE * 2.0)
	var s := PackedFloat32Array()
	s.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 71
	for note in notes:
		var start := int(note.at * RATE)
		var count := int(note.len * RATE)
		for k in count:
			var i := start + k
			if i >= n:
				break
			var t := float(k) / RATE
			var env: float = minf(t / 0.03, 1.0) * exp(-t * 1.7)
			var v := sin(TAU * note.f * t) * 0.6 + sin(TAU * note.f * 2.0 * t) * 0.2
			s[i] += v * env * 0.3
	# Rubble under the melody.
	var lp := 0.0
	for i in n:
		var t := float(i) / RATE
		lp = lp * 0.9 + rng.randf_range(-1.0, 1.0) * 0.1
		s[i] += lp * 2.2 * exp(-t * 1.2) * 0.35
	return _wav(s)


## Exactly one second, built only from whole-number frequencies, so the loop
## point lands mid-cycle for every partial and never clicks.
func _engine_loop() -> AudioStreamWAV:
	var n := RATE
	var s := PackedFloat32Array()
	s.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var phases := []
	for h in 16:
		phases.append(rng.randf() * TAU)
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for h in range(1, 17):
			var amp := 1.0 / float(h)
			if h % 2 == 0:
				amp *= 0.45
			v += sin(TAU * float(h * 55) * t + phases[h - 1]) * amp
		s[i] = v * 0.13
	return _wav(s, true)
