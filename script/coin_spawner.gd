extends Node2D

@export var coin_scene: PackedScene

@export_enum("silver", "diamond")
var coin_type: String = "silver"

@export var spawn_interval: float = 5.0
@export var max_coins: int = 10
@export var silver_spawner_texture: Texture2D
@export var diamond_spawner_texture: Texture2D

@onready var sprite: Sprite2D = $Sprite2D
@onready var spawn_points: Node2D = $SpawnPoints

var spawned_coins: Array[Node2D] = []

func _ready() -> void:
	update_appearance()


func _process(delta: float) -> void:
	pass
	
func update_appearance() -> void:
	match coin_type:
		"silver":
			sprite.texture = silver_spawner_texture
		"diamond":
			sprite.texture = diamond_spawner_texture
			
func spawn_coin() -> void:
	# 이미 생성한 코인 중 획득되거나 삭제된 코인 제거
	spawned_coins = spawned_coins.filter(
		func(coin): return is_instance_valid(coin)
	)
	
	if spawned_coins.size() >= max_coins:
		return
		
	if coin_scene == null:
		push_warning("CoinSpawner: Coin Scene이 설정되지 않았습니다.")
		return
		
	var available_points: Array[Marker2D] = []
	for point in spawn_points.get_children():
		if not point is Marker2D:
			continue
		var occupied := false
		
		for existing_coin in spawned_coins:
			if existing_coin.global_position.distance_to(
				point.global_position
			) < 1.0:
				occupied = true
				break
				
		if not occupied:
			available_points.append(point)
			
	if available_points.is_empty():
		return
		
	var selected_point: Marker2D = available_points.pick_random()
	var coin = coin_scene.instantiate()
	coin.coin_type = coin_type
	
	get_tree().current_scene.add_child(coin)
	coin.global_position = selected_point.global_position
	
	spawned_coins.append(coin)
	
func get_spawn_config() -> Dictionary:
	var points: Array = []
	
	for point in spawn_points.get_children():
		if point is Marker2D:
			points.append({
				"x": point.global_position.x,
				"y": point.global_position.y
			})
	return {
		"name": name,
		"coin_type": coin_type,
		"interval": spawn_interval,
		"max_coins": max_coins,
		"points": points
	}
