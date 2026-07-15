extends Node3D
## Screen flow, the stick, and the HUD.

const INK := Color("#221f19")
const CARD := Color("#d9cfb1")
const STAMP := Color("#a8352b")
const GREASE := Color("#4d9ad0")
const OLIVE := Color("#2f3327")
const GOOD := Color("#7fa86a")

var ui: CanvasLayer
var menu: Control
var queue_box: Control
var hud: Control
var result: Control

var lbl_queue: Label
var lbl_timer: Label
var lbl_speed: Label
var lbl_alt: Label
var lbl_ammo: Label
var lbl_thr: Label
var lbl_warn: Label
var lbl_foe: Label
var lbl_result: Label
var lbl_result_sub: Label
var bar_hp: ColorRect
var bar_foe: ColorRect
var overlay: ColorRect
var marks: Control
var btn_fly: Button
var btn_again: Button

var _throttle := 0.75
var _flash := 0.0
var _last_hp := 100
var _phase := "menu"
var _wait := 0.0
var _requeue := 0.0
var _acked := false


func _ready() -> void:
	_build_ui()
	_add_mouse_fire()
	Net.message.connect(GameState.on_message)
	Net.opened.connect(func(): Net.send({"t": "queue"}))
	Net.closed.connect(_on_closed)
	GameState.queued.connect(_on_queued)
	GameState.match_ready.connect(_on_live)
	GameState.match_ended.connect(_on_end)
	GameState.room_closed.connect(_on_room_closed)
	_show("menu")


## SPACE is Godot's default ui_accept, so any Control still holding focus eats it,
## and browsers like to claim it too. A mouse button has neither problem — and
## clicking to shoot is what people try first anyway.
func _add_mouse_fire() -> void:
	if not InputMap.has_action("fire"):
		InputMap.add_action("fire")
	for e in InputMap.action_get_events("fire"):
		if e is InputEventMouseButton:
			return
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	InputMap.action_add_event("fire", mb)


# --- input ---------------------------------------------------------------

func _process(delta: float) -> void:
	# Never sit on a hopeful message forever — say something useful instead.
	if _phase == "queue":
		_wait += delta
		# Keep asking until the server acknowledges. enqueue() is idempotent, so
		# a repeat costs nothing — and this can't be defeated by signal timing.
		if not _acked and Net.is_open():
			_requeue -= delta
			if _requeue <= 0.0:
				_requeue = 1.5
				Net.send({"t": "queue"})
		if _wait > 9.0:
			lbl_queue.text = "Can't reach the field.\nThe game server answered, but the match never started.\nReload the page to try again."
	if _phase == "flying":
		_read_stick(delta)
		_update_hud()
	if _flash > 0.0:
		_flash = maxf(0.0, _flash - delta * 2.2)
		overlay.color = Color(0.7, 0.1, 0.06, _flash * 0.45)
	marks.queue_redraw()


func _read_stick(delta: float) -> void:
	var me: Dictionary = GameState.me()
	if me.is_empty() or not me.alive:
		GameState.input.fire = false
		return

	# Throttle is a lever, not a button. Now that pulling G costs energy, holding
	# a sensible speed is a real decision.
	if Input.is_action_pressed("throttle_up"):
		_throttle = minf(1.0, _throttle + delta * 0.7)
	if Input.is_action_pressed("throttle_down"):
		_throttle = maxf(0.0, _throttle - delta * 0.7)

	GameState.input.pitch = Input.get_action_strength("pitch_up") - Input.get_action_strength("pitch_down")
	GameState.input.roll = Input.get_action_strength("roll_right") - Input.get_action_strength("roll_left")
	GameState.input.yaw = Input.get_action_strength("yaw_right") - Input.get_action_strength("yaw_left")
	GameState.input.throttle = _throttle
	GameState.input.fire = Input.is_action_pressed("fire") and me.ammo > 0


# --- flow ----------------------------------------------------------------

func _fly() -> void:
	_show("queue")
	lbl_queue.text = "Contacting the field…"
	_wait = 0.0
	_requeue = 0.0
	_acked = false
	# Re-queueing on a socket that's still up must not try to reopen it.
	if Net.is_open():
		Net.send({"t": "queue"})
	else:
		Net.connect_to_server()


func _on_queued(waiting: int, need: int) -> void:
	_wait = 0.0
	_acked = true
	_show("queue")
	lbl_queue.text = "Waiting for another pilot… %d of %d\nA machine will take the other aircraft shortly." % [waiting, need]


func _on_live() -> void:
	_wait = 0.0
	_acked = true
	# The button you clicked to get here still has keyboard focus, and a focused
	# Button consumes SPACE. Let it go before anyone reaches for the trigger.
	get_viewport().gui_release_focus()
	_throttle = 0.75
	_last_hp = 100
	_flash = 0.0
	_show("flying")
	var f: Dictionary = GameState.foe()
	lbl_foe.text = ("%s%s" % [f.get("name", "?"), " (machine)" if f.get("bot", false) else ""]) if not f.is_empty() else ""


func _on_end(winner: int, outcome: String, _causes: Array) -> void:
	_show("result")
	GameState.input.fire = false
	Sfx.engine_stop()
	var won := winner == GameState.you
	if won:
		lbl_result.text = "CASTLE SAVED"
		lbl_result.add_theme_color_override("font_color", GOOD)
		lbl_result_sub.text = "You're the one still flying. They'll be talking about this one."
		Sfx.play("victory", 0.0)
	elif outcome == "fell":
		lbl_result.text = "CASTLE FELL"
		lbl_result.add_theme_color_override("font_color", STAMP)
		lbl_result_sub.text = "Nobody finished the job. The castle doesn't care whose fault that was."
		Sfx.play("defeat", -2.0)
	else:
		lbl_result.text = "CASTLE DESTROYED"
		lbl_result.add_theme_color_override("font_color", STAMP)
		lbl_result_sub.text = "You went down. There was nothing left between them and the walls."
		Sfx.play("defeat", -2.0)


func _on_room_closed() -> void:
	_show("menu")


func _on_closed(_code: int) -> void:
	Sfx.engine_stop()
	if _phase != "result":
		_show("queue")
		lbl_queue.text = "Lost contact with the field.\nReload the page to try again."


func _again() -> void:
	GameState.reset()
	Net.disconnect_from_server()
	await get_tree().create_timer(0.25).timeout
	_fly()


func _show(p: String) -> void:
	_phase = p
	menu.visible = p == "menu"
	queue_box.visible = p == "queue"
	hud.visible = p == "flying"
	result.visible = p == "result"
	if p != "flying":
		GameState.input.fire = false


# --- hud -----------------------------------------------------------------

func _update_hud() -> void:
	var me: Dictionary = GameState.me()
	if me.is_empty():
		return

	if me.hp < _last_hp:
		_flash = 1.0
	_last_hp = me.hp

	var t: float = GameState.time_left
	lbl_timer.text = "%d:%02d" % [int(t) / 60, int(t) % 60]
	lbl_speed.text = "%3d kn" % int(me.speed)
	lbl_alt.text = "%4d ft" % int(me.pos.y)
	lbl_ammo.text = "%d / %d" % [me.ammo, GameState.ammo_max]
	lbl_ammo.add_theme_color_override("font_color", STAMP if me.ammo < 80 else CARD)
	lbl_thr.text = "THR %3d%%" % int(_throttle * 100.0)
	bar_hp.size.x = 168.0 * clampf(float(me.hp) / 100.0, 0.0, 1.0)
	bar_hp.color = GOOD if me.hp > 45 else STAMP

	var f: Dictionary = GameState.foe()
	if not f.is_empty():
		bar_foe.size.x = 168.0 * clampf(float(f.hp) / 100.0, 0.0, 1.0)
		bar_foe.color = CARD if f.alive else Color(0.4, 0.4, 0.4)

	var w := ""
	if not me.alive:
		w = "YOU ARE DOWN"
	elif me.oob:
		w = "RETURN TO THE ISLAND"
	elif me.speed < 72.0:
		w = "STALL — GET THE NOSE DOWN"
	elif me.ammo == 0:
		w = "OUT OF AMMUNITION"
	lbl_warn.text = w


func _panel(c: Color, a := 0.55) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(c.r, c.g, c.b, a)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	sb.corner_radius_top_left = 2
	sb.corner_radius_top_right = 2
	sb.corner_radius_bottom_left = 2
	sb.corner_radius_bottom_right = 2
	return sb


func _label(parent: Control, text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	parent.add_child(l)
	return l


func _button(parent: Control, text: String, enabled := true) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 19)
	b.custom_minimum_size = Vector2(360, 52)
	b.disabled = not enabled
	var n := _panel(INK, 0.95)
	var h := _panel(Color("#3a352a"), 1.0)
	b.add_theme_stylebox_override("normal", n)
	b.add_theme_stylebox_override("hover", h)
	b.add_theme_stylebox_override("pressed", n)
	b.add_theme_stylebox_override("disabled", _panel(INK, 0.35))
	b.add_theme_color_override("font_color", CARD)
	b.add_theme_color_override("font_disabled_color", Color(0.75, 0.72, 0.62, 0.4))
	parent.add_child(b)
	return b


func _build_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)

	# ---- menu ----
	menu = ColorRect.new()
	menu.color = OLIVE
	_full(menu)
	ui.add_child(menu)

	var col := VBoxContainer.new()
	_anchor(col, 0.5, 0.5, 0.5, 0.5, -230, -210, 230, 210)
	col.add_theme_constant_override("separation", 9)
	menu.add_child(col)

	var title := _label(col, "AIRMAN", 62, CARD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var sub := _label(col, "Two planes. One island. Five hundred rounds.", 15, Color("#9aa085"))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	col.add_child(_spacer(18))
	btn_fly = _button(col, "I  ·  SAVE THE CASTLE")
	btn_fly.pressed.connect(_fly)
	_button(col, "II  ·  SAVE THE CITY  —  not yet flying", false)

	col.add_child(_spacer(20))
	var help := _label(col, "W / S  nose down / up      A / D  roll      Q / E  rudder\nSHIFT / CTRL  throttle      SPACE or LEFT CLICK  guns\n\nThe castle guns fire at anything with wings. That includes you.", 13, Color("#8d9179"))
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# ---- queue ----
	queue_box = ColorRect.new()
	queue_box.color = OLIVE
	_full(queue_box)
	ui.add_child(queue_box)
	lbl_queue = _label(queue_box, "", 20, CARD)
	_anchor(lbl_queue, 0.5, 0.5, 0.5, 0.5, -280, -40, 280, 40)
	lbl_queue.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_queue.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	# ---- hud ----
	hud = Control.new()
	_full(hud)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(hud)

	overlay = ColorRect.new()
	overlay.color = Color(0, 0, 0, 0)
	_full(overlay)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(overlay)

	marks = Marks.new()
	_full(marks)
	marks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(marks)

	# your aircraft, top left
	var tl := VBoxContainer.new()
	_anchor(tl, 0, 0, 0, 0, 18, 14, 200, 60)
	hud.add_child(tl)
	_label(tl, "YOUR AIRCRAFT", 11, Color("#9aa085"))
	var hp_bg := ColorRect.new()
	hp_bg.color = Color(0, 0, 0, 0.5)
	hp_bg.custom_minimum_size = Vector2(168, 9)
	tl.add_child(hp_bg)
	bar_hp = ColorRect.new()
	bar_hp.color = GOOD
	bar_hp.size = Vector2(168, 9)
	hp_bg.add_child(bar_hp)

	# their aircraft, top right
	var tr := VBoxContainer.new()
	_anchor(tr, 1, 0, 1, 0, -186, 14, -18, 60)
	tr.alignment = BoxContainer.ALIGNMENT_BEGIN
	hud.add_child(tr)
	lbl_foe = _label(tr, "", 11, Color("#9aa085"))
	lbl_foe.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var foe_bg := ColorRect.new()
	foe_bg.color = Color(0, 0, 0, 0.5)
	foe_bg.custom_minimum_size = Vector2(168, 9)
	tr.add_child(foe_bg)
	bar_foe = ColorRect.new()
	bar_foe.color = CARD
	bar_foe.size = Vector2(168, 9)
	foe_bg.add_child(bar_foe)

	lbl_timer = _label(hud, "5:00", 28, CARD)
	_anchor(lbl_timer, 0.5, 0, 0.5, 0, -60, 10, 60, 48)
	lbl_timer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	lbl_warn = _label(hud, "", 22, STAMP)
	_anchor(lbl_warn, 0.5, 0.5, 0.5, 0.5, -280, -140, 280, -108)
	lbl_warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	var bl := VBoxContainer.new()
	_anchor(bl, 0, 1, 0, 1, 18, -86, 200, -14)
	hud.add_child(bl)
	lbl_speed = _label(bl, "", 21, CARD)
	lbl_alt = _label(bl, "", 21, CARD)
	lbl_thr = _label(bl, "", 15, Color("#9aa085"))

	var br := VBoxContainer.new()
	_anchor(br, 1, 1, 1, 1, -170, -62, -18, -14)
	hud.add_child(br)
	var ammo_cap := _label(br, "AMMUNITION", 11, Color("#9aa085"))
	ammo_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lbl_ammo = _label(br, "500 / 500", 21, CARD)
	lbl_ammo.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	# ---- result ----
	result = ColorRect.new()
	result.color = Color(0.09, 0.10, 0.08, 0.86)
	_full(result)
	ui.add_child(result)
	var rc := VBoxContainer.new()
	_anchor(rc, 0.5, 0.5, 0.5, 0.5, -280, -130, 280, 130)
	rc.add_theme_constant_override("separation", 12)
	result.add_child(rc)
	lbl_result = _label(rc, "", 44, CARD)
	lbl_result.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_result_sub = _label(rc, "", 15, Color("#9aa085"))
	lbl_result_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl_result_sub.autowrap_mode = TextServer.AUTOWRAP_WORD
	rc.add_child(_spacer(14))
	btn_again = _button(rc, "FLY ANOTHER MISSION")
	btn_again.pressed.connect(_again)


func _anchor(c: Control, al: float, at: float, ar: float, ab: float,
		ol: float, ot: float, orr: float, ob: float) -> void:
	c.anchor_left = al
	c.anchor_top = at
	c.anchor_right = ar
	c.anchor_bottom = ab
	c.offset_left = ol
	c.offset_top = ot
	c.offset_right = orr
	c.offset_bottom = ob


func _full(c: Control) -> void:
	_anchor(c, 0, 0, 1, 1, 0, 0, 0, 0)


func _spacer(h: int) -> Control:
	var s := Control.new()
	s.custom_minimum_size = Vector2(0, h)
	return s


## Gunsight, the bandit box, and the bearing strip along the bottom. Drawn rather
## than built from nodes because all of it moves every frame.
class Marks:
	extends Control

	func _ctext(font: Font, at: Vector2, txt: String, fs: int, col: Color) -> void:
		var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, at - Vector2(w * 0.5, 0.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)

	func _draw() -> void:
		if GameState.you < 0 or not GameState.live:
			return
		var me: Dictionary = GameState.me()
		if me.is_empty() or not me.get("alive", false):
			return

		var c := size * 0.5
		var ink := Color(0.85, 0.88, 0.72, 0.85)
		var font := ThemeDB.fallback_font

		# Gunsight.
		draw_arc(c, 15.0, 0.0, TAU, 28, ink, 1.5)
		draw_line(c + Vector2(-26, 0), c + Vector2(-8, 0), ink, 1.5)
		draw_line(c + Vector2(8, 0), c + Vector2(26, 0), ink, 1.5)
		draw_line(c + Vector2(0, -26), c + Vector2(0, -8), ink, 1.5)
		draw_line(c + Vector2(0, 8), c + Vector2(0, 26), ink, 1.5)
		draw_circle(c, 1.6, ink)

		# Until the first round goes out, say how. Ammo is the state — no flag needed.
		if int(me.get("ammo", 0)) >= GameState.ammo_max:
			_ctext(font, c + Vector2(0, 54), "SPACE or LEFT CLICK to fire", 13,
				Color(0.85, 0.88, 0.72, 0.6))

		var foe: Dictionary = GameState.foe()
		var world = get_node_or_null("/root/Main/World")
		var red := Color(0.91, 0.34, 0.25, 0.95)

		if not foe.is_empty() and foe.get("alive", false) and foe.get("spawned", false) \
				and world != null and world.cam != null:
			var cam: Camera3D = world.cam
			var fp: Vector3 = foe.pos
			var behind := cam.is_position_behind(fp)
			var sp := cam.unproject_position(fp)
			var on_screen := not behind and Rect2(Vector2.ZERO, size).grow(-40.0).has_point(sp)

			if on_screen:
				var d: float = me.pos.distance_to(fp)
				var r: float = clampf(1400.0 / maxf(d, 40.0), 9.0, 60.0)
				draw_rect(Rect2(sp - Vector2(r, r), Vector2(r * 2, r * 2)), red, false, 1.6)
				draw_string(font, sp + Vector2(r + 5, 4), "%d" % int(d),
					HORIZONTAL_ALIGNMENT_LEFT, -1, 12, red)
			else:
				var dir := sp - c
				if behind:
					dir = -dir
				if dir.length() < 0.001:
					dir = Vector2(0, -1)
				dir = dir.normalized()
				var edge: Vector2 = c + dir * (minf(size.x, size.y) * 0.5 - 46.0)
				var perp := Vector2(-dir.y, dir.x)
				draw_colored_polygon(PackedVector2Array([
					edge + dir * 13.0, edge - dir * 6.0 + perp * 9.0, edge - dir * 6.0 - perp * 9.0,
				]), red)

		_strip(me, foe, font)

	## Where he is, in clock code. A chase camera shows you nothing behind the
	## tail, and that is exactly where a bot who's winning will be.
	func _strip(me: Dictionary, foe: Dictionary, font: Font) -> void:
		var w: float = minf(size.x - 140.0, 520.0)
		var cx: float = size.x * 0.5
		var y: float = size.y - 56.0
		var left: float = cx - w * 0.5
		var dim := Color(0.85, 0.88, 0.72, 0.30)
		var lab := Color(0.85, 0.88, 0.72, 0.55)

		draw_line(Vector2(left, y), Vector2(left + w, y), dim, 2.0)
		for m in [[-1.0, "6"], [-0.5, "9"], [0.0, "12"], [0.5, "3"], [1.0, "6"]]:
			var b: float = m[0]
			var tx: float = left + (b * 0.5 + 0.5) * w
			var h: float = 10.0 if b == 0.0 else 6.0
			draw_line(Vector2(tx, y - h), Vector2(tx, y + h), dim, 1.5)
			_ctext(font, Vector2(tx, y + 24.0), str(m[1]), 11, lab)

		if foe.is_empty() or not foe.get("alive", false) or not foe.get("spawned", false):
			_ctext(font, Vector2(cx, y - 26.0), "NO CONTACT", 12, lab)
			return

		# Bearing on the horizontal plane, so rolling doesn't spin the strip.
		var f: Vector3 = me.q * Vector3(0, 0, -1)
		var to: Vector3 = foe.pos - me.pos
		var flat_f := Vector2(f.x, f.z)
		var flat_t := Vector2(to.x, to.z)
		if flat_f.length() < 0.001 or flat_t.length() < 0.001:
			return
		var bearing: float = flat_f.angle_to(flat_t)          # + = off to your right
		var t: float = clampf(bearing / PI, -1.0, 1.0)
		var mx: float = left + (t * 0.5 + 0.5) * w
		var dist: float = to.length()
		var col := Color(0.91, 0.34, 0.25, 0.95)

		draw_colored_polygon(PackedVector2Array([
			Vector2(mx, y - 9.0), Vector2(mx - 7.0, y - 21.0), Vector2(mx + 7.0, y - 21.0),
		]), col)
		_ctext(font, Vector2(mx, y - 27.0), "%d" % int(dist), 12, col)

		var dy: float = float(foe.pos.y) - float(me.pos.y)
		var tag := "level"
		if absf(dy) > 25.0:
			tag = ("above  +%d" % int(dy)) if dy > 0.0 else ("below  -%d" % int(-dy))
		_ctext(font, Vector2(cx, y + 40.0), tag, 11, lab)

		if absf(bearing) > 2.36:
			_ctext(font, Vector2(cx, y - 50.0), "CHECK SIX", 18, col)
