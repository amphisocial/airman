extends Node
## WebSocket transport. Same-origin in the browser, so the sortie.sid cookie
## rides along on the handshake and the server already knows who we are.

signal opened
signal closed(code: int)
signal message(msg: Dictionary)

## Used only when running from the Godot editor (not in a web export).
const DEV_HOST := "127.0.0.1:4020"
const DEV_TLS := false

var _ws := WebSocketPeer.new()
var _state := WebSocketPeer.STATE_CLOSED
var _ping_at := 0.0
var rtt_ms := 0


func origin() -> Dictionary:
	if OS.has_feature("web"):
		var host := str(JavaScriptBridge.eval("window.location.host", true))
		var proto := str(JavaScriptBridge.eval("window.location.protocol", true))
		return {"host": host, "tls": proto == "https:"}
	return {"host": DEV_HOST, "tls": DEV_TLS}


func connect_to_server() -> void:
	var o := origin()
	var scheme: String = "wss" if o.tls else "ws"
	var url := "%s://%s/ws" % [scheme, o.host]
	var err := _ws.connect_to_url(url)
	if err != OK:
		push_error("Sortie: could not open %s (error %d)" % [url, err])
		closed.emit(-1)


func send(msg: Dictionary) -> void:
	if _state == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(msg))


func disconnect_from_server() -> void:
	if _state == WebSocketPeer.STATE_OPEN:
		_ws.close(1000, "bye")


func _process(delta: float) -> void:
	_ws.poll()
	var st := _ws.get_ready_state()

	if st != _state:
		if st == WebSocketPeer.STATE_OPEN:
			opened.emit()
		elif st == WebSocketPeer.STATE_CLOSED:
			closed.emit(_ws.get_close_code())
		_state = st

	if st != WebSocketPeer.STATE_OPEN:
		return

	while _ws.get_available_packet_count() > 0:
		var raw := _ws.get_packet().get_string_from_utf8()
		var parsed = JSON.parse_string(raw)
		if typeof(parsed) == TYPE_DICTIONARY:
			if parsed.get("t", "") == "pong":
				rtt_ms = int(Time.get_ticks_msec() - float(parsed.get("ts", 0)))
			else:
				message.emit(parsed)

	_ping_at -= delta
	if _ping_at <= 0.0:
		_ping_at = 2.0
		send({"t": "ping", "ts": Time.get_ticks_msec()})
