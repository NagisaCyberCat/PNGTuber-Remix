@tool
extends Camera2D
class_name SpoutCAM

@export_group("Spout Sender")
## Aktiviert/deaktiviert den Spout-Output dieser Kamera.
@export var send_to_spout: bool = true:
	set(value):
		send_to_spout = value
		if not is_inside_tree():
			return
		if Engine.is_editor_hint():
			set_process(false)
			return

		if send_to_spout and _spout == null:
			_start_spout_deferred()
		elif not send_to_spout:
			_release_spout()

## Name des Spout-Senders (wenn vom Addon unterstützt).
@export var spout_sender_name: String = "PNGTube-Remix":
	set(value):
		spout_sender_name = value
		if _spout != null:
			_apply_sender_name()

## Limitiert die Sende-Frequenz. 0 oder kleiner = jede Frame.
@export_range(0.0, 240.0, 1.0) var max_send_fps: float = 60.0

## Korrigiert die vertikale Orientierung fuer Spout-Empfaenger.
@export var flip_vertical_output: bool = true

## Verzoegerung nach Szenenstart, bevor Spout initialisiert wird.
@export_range(0, 120, 1) var spout_init_delay_frames: int = 2

## Zusaetzliche Zeitverzoegerung vor Spout-Init (Sekunden).
@export_range(0.0, 5.0, 0.05) var spout_init_delay_seconds: float = 0.35

@export var debug_output: bool = false

@export_group("Spout Output")
## Nutzt eine feste Aufloesung fuer die Spout-Ausgabe statt der Viewport-Groesse.
@export var use_custom_spout_resolution: bool = false:
	set(value):
		use_custom_spout_resolution = value
		_sync_spout_viewport_size()

## Breite der Spout-Ausgabe, wenn feste Aufloesung aktiv ist.
@export_range(16, 8192, 1) var spout_output_width: int = 1280:
	set(value):
		spout_output_width = max(16, value)
		_sync_spout_viewport_size()

## Hoehe der Spout-Ausgabe, wenn feste Aufloesung aktiv ist.
@export_range(16, 8192, 1) var spout_output_height: int = 720:
	set(value):
		spout_output_height = max(16, value)
		_sync_spout_viewport_size()

@export_group("Visual Settings")
## Aktiviert die Transparenz (Alpha-Kanal) für den Spout-Output.
@export var transparent_background: bool = true:
	set(value):
		transparent_background = value
		_apply_settings()

## Bestimmt welche Canvas-Layer in den Spout-Output gerendert werden (Bitmaske).
## Bit 1 = Layer 1, Bit 2 = Layer 2, usw.
## Standard: Layer 1-17 aktiv (BG auf Layer 0 und UI auf hohen CanvasLayern ausgeschlossen).
@export_flags_2d_render var canvas_cull_mask: int = 0xFFFFFFFF:
	set(value):
		canvas_cull_mask = value
		if _spout_viewport != null:
			_spout_viewport.canvas_cull_mask = canvas_cull_mask

var _spout: Object = null
var _spout_viewport: SubViewport = null
var _spout_camera: Camera2D = null
var _time_since_send: float = 0.0
var _sent_frames: int = 0
var _pending_spout_init: bool = false
var _frames_until_spout_init: int = 0
var _spout_init_request_id: int = 0



func _ready() -> void:
	add_to_group("nagi_spout_camera")

	if Engine.is_editor_hint():
		_apply_settings()
		set_process(false)
		return

	if send_to_spout:
		_start_spout_deferred()
	
	_apply_settings()
	set_process(send_to_spout)

func _start_spout_deferred() -> void:
	_spout_init_request_id += 1
	var request_id: int = _spout_init_request_id
	call_deferred("_continue_spout_deferred_start", request_id)

func _continue_spout_deferred_start(request_id: int) -> void:
	if request_id != _spout_init_request_id:
		return
	if not send_to_spout or Engine.is_editor_hint():
		return

	if spout_init_delay_seconds > 0.0:
		await get_tree().create_timer(spout_init_delay_seconds).timeout
		if request_id != _spout_init_request_id:
			return
		if not send_to_spout:
			return

	_schedule_spout_init()

func _process(delta: float) -> void:
	if _pending_spout_init:
		if _frames_until_spout_init > 0:
			_frames_until_spout_init -= 1
		else:
			_pending_spout_init = false
			_initialize_spout()

	if not send_to_spout or _spout == null:
		return

	_ensure_spout_viewport()
	_sync_spout_camera()
	_sync_spout_viewport_size()

	if max_send_fps > 0.0:
		_time_since_send += delta
		var send_interval := 1.0 / max_send_fps
		if _time_since_send < send_interval:
			return
		_time_since_send = 0.0

	if _spout_viewport == null:
		return

	var tex := _spout_viewport.get_texture()
	if tex == null:
		return

	var frame_image := tex.get_image()
	if frame_image == null or frame_image.get_width() <= 0 or frame_image.get_height() <= 0:
		return

	# Spout erwartet stabil ein 4-Kanal-Format; daher immer auf RGBA8 normalisieren.
	if frame_image.get_format() != Image.FORMAT_RGBA8:
		frame_image.convert(Image.FORMAT_RGBA8)

	if flip_vertical_output:
		frame_image.flip_y()

	if _spout.has_method("send_image"):
		_spout.call("send_image", frame_image, frame_image.get_width(), frame_image.get_height())
		if debug_output and (_sent_frames % 120 == 0):
			print("Spout frame sent:", frame_image.get_width(), "x", frame_image.get_height(), " via ", spout_sender_name)
		_sent_frames += 1

func _initialize_spout() -> void:
	if not ClassDB.class_exists("Spout"):
		push_warning("Klasse 'Spout' nicht gefunden. Addon 'spout-gd' aktivieren und Projekt neu starten.")
		set_process(false)
		return

	if not ClassDB.can_instantiate("Spout"):
		push_warning("Klasse 'Spout' kann aktuell nicht instanziiert werden.")
		set_process(false)
		return

	var instance: Object = ClassDB.instantiate("Spout") as Object
	if instance == null:
		push_warning("Spout konnte nicht initialisiert werden. Stelle sicher, dass das Addon 'spout-gd' aktiv ist.")
		set_process(false)
		return

	_spout = instance
	_ensure_spout_viewport()
	_apply_sender_name()

	if debug_output:
		print("Spout initialized")

func _schedule_spout_init() -> void:
	_pending_spout_init = true
	_frames_until_spout_init = max(0, spout_init_delay_frames)
	set_process(true)

	if debug_output:
		print("Spout init scheduled in ", _frames_until_spout_init, " frame(s)")

func _ensure_spout_viewport() -> void:
	if _spout_viewport != null and _spout_camera != null:
		return

	_spout_viewport = SubViewport.new()
	_spout_viewport.name = "SpoutOutputViewport"
	_spout_viewport.transparent_bg = transparent_background
	_spout_viewport.canvas_cull_mask = canvas_cull_mask
	_spout_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_spout_viewport.handle_input_locally = false
	_spout_viewport.msaa_2d = Viewport.MSAA_DISABLED

	var world_source := get_viewport()
	if world_source != null:
		_spout_viewport.world_2d = world_source.world_2d

	add_child(_spout_viewport)

	_spout_camera = Camera2D.new()
	_spout_camera.name = "SpoutOutputCamera"
	_spout_viewport.add_child(_spout_camera)

	_sync_spout_viewport_size()
	_sync_spout_camera()
	_apply_settings()

func _sync_spout_viewport_size() -> void:
	if _spout_viewport == null:
		return

	if use_custom_spout_resolution:
		var custom_size := Vector2i(max(16, spout_output_width), max(16, spout_output_height))
		if _spout_viewport.size != custom_size:
			_spout_viewport.size = custom_size
		return

	var source_viewport := get_viewport()
	if source_viewport == null:
		return

	var source_tex := source_viewport.get_texture()
	if source_tex == null:
		return

	var source_size: Vector2i = source_tex.get_size()
	if source_size.x <= 0 or source_size.y <= 0:
		return

	if _spout_viewport.size != source_size:
		_spout_viewport.size = source_size

func _sync_spout_camera() -> void:
	if _spout_camera == null:
		return

	_spout_camera.global_transform = global_transform
	_spout_camera.offset = offset
	_spout_camera.zoom = zoom
	_spout_camera.anchor_mode = anchor_mode
	_spout_camera.ignore_rotation = ignore_rotation
	_spout_camera.make_current()

func _apply_sender_name() -> void:
	if _spout == null:
		return

	if spout_sender_name.is_empty():
		return

	# Das Addon hat je nach Version unterschiedliche API-Namen.
	if _spout.has_method("set_sender_name"):
		_spout.call("set_sender_name", spout_sender_name)
	elif _spout.has_method("set_sender"):
		_spout.call("set_sender", spout_sender_name)

func _release_spout() -> void:
	_spout_init_request_id += 1
	_pending_spout_init = false
	_frames_until_spout_init = 0

	if _spout != null:
		if not (_spout is RefCounted):
			_spout.free()
		_spout = null

	if _spout_viewport != null:
		_spout_viewport.queue_free()
		_spout_viewport = null
		_spout_camera = null

	_time_since_send = 0.0

func restart_spout() -> void:
	_release_spout()
	if Engine.is_editor_hint():
		set_process(false)
		return
	if send_to_spout:
		_start_spout_deferred()
		set_process(true)

func get_spout_runtime_status() -> Dictionary:
	return {
		"send_to_spout": send_to_spout,
		"spout_ready": _spout != null,
		"viewport_ready": _spout_viewport != null,
		"pending_init": _pending_spout_init,
		"frames_until_init": _frames_until_spout_init,
		"sent_frames": _sent_frames,
		"processing": is_processing(),
		"spout_class_exists": ClassDB.class_exists("Spout"),
		"spout_can_instantiate": ClassDB.can_instantiate("Spout") if ClassDB.class_exists("Spout") else false
	}

func _apply_settings() -> void:
	if _spout_viewport:
		_spout_viewport.transparent_bg = transparent_background

func _exit_tree() -> void:
	_release_spout()
