@tool
extends EditorPlugin

const SPOUT_CAM_SCRIPT := preload("res://addons/nagis-spoutcam/spout_cam.gd")


func _exit_tree() -> void:
	remove_custom_type("SpoutCAM")
