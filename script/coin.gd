extends Area2D

@export_enum("silver", "diamond")
var coin_type: String = "silver"

@export var amount: int = 1

@export var silver_texture: Texture2D
@export var diamond_texture: Texture2D

@onready var sprite: Sprite2D = $Sprite2D

func _ready() -> void:
	update_appearance()
	
func update_appearance() -> void:
	match coin_type:
		"silver":
			sprite.texture = silver_texture
		"diamond":
			sprite.texture = diamond_texture
		
