# MIT License.
# Made by Dylearn

# Zelda-style camera that stays fixed until the target enters a border zone,
# then smoothly scrolls by half a screen in that direction.
# Camera positions are quantized to a grid of half-screen cells to prevent
# oscillation at zone boundaries.
# Supports smooth mousewheel zoom with pixel-clean snapping.

@tool
extends Camera2D

@export var target: Node2D
@export_range(0.05, 0.45, 0.01) var border_fraction: float = 0.3
@export var scroll_speed: float = 5.0
@export_range(0.01, 0.5, 0.01) var zoom_speed: float = 0.15
@export var min_zoom: float = 0.5
@export var max_zoom: float = 4.0

var _current_cell: Vector2i
var _target_zoom: float = 1.0


func _ready() -> void:
	_target_zoom = zoom.x
	_recalc_cell()


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_target_zoom *= (1.0 + zoom_speed)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_target_zoom *= (1.0 - zoom_speed)
			_target_zoom = clampf(_target_zoom, min_zoom, max_zoom)


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or not target:
		return

	# Smooth zoom — no snapping (SubViewport texel snapping handles mask edges independently)
	var raw_zoom := lerpf(zoom.x, _target_zoom, 1.0 - exp(-scroll_speed * delta))
	zoom = Vector2(raw_zoom, raw_zoom)

	# Zelda-style cell scrolling
	var vp_size: Vector2 = get_viewport_rect().size / zoom
	var half_screen: Vector2 = vp_size * 0.5
	if half_screen.x <= 0.0 or half_screen.y <= 0.0:
		return

	var cell_center: Vector2 = (Vector2(_current_cell) + Vector2(0.5, 0.5)) * half_screen
	var trigger: Vector2 = half_screen * (1.0 - border_fraction)

	var rel: Vector2 = target.global_position - cell_center
	if absf(rel.x) > trigger.x or absf(rel.y) > trigger.y:
		_current_cell = Vector2i(
			floori(target.global_position.x / half_screen.x),
			floori(target.global_position.y / half_screen.y)
		)
		cell_center = (Vector2(_current_cell) + Vector2(0.5, 0.5)) * half_screen

	global_position = global_position.lerp(cell_center, 1.0 - exp(-scroll_speed * delta))


func _recalc_cell() -> void:
	var half_screen: Vector2 = get_viewport_rect().size / zoom * 0.5
	if half_screen.x > 0.0 and half_screen.y > 0.0:
		_current_cell = Vector2i(
			floori(global_position.x / half_screen.x),
			floori(global_position.y / half_screen.y)
		)
