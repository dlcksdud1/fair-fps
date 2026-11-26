extends CharacterBody2D

@export var move_speed : float = 250.0
@export var bullet_scene: PackedScene
@export var max_hp: int = 100
@export var magazine_size: int = 12
@export var reload_time: float = 1.5
@export var is_local_player: bool = true
@export var respawn_time: float = 3.0
@export var team_color: Color = Color.WHITE


@onready var muzzle: Marker2D = $Muzzle

var fire_cooldown: float = 0.2
var fire_timer: float = 0.0
var hp: int
var ammo: int = 12
var is_reloading: bool = false
var spawn_position: Vector2
var is_dead: bool = false
var original_collision_layer: int
var original_collision_mask: int
var silver: int = 0
var diamond: int = 0

func _ready() -> void:
	original_collision_layer = collision_layer
	original_collision_mask = collision_mask
	spawn_position = global_position
	hp = max_hp
	$Sprite2D.self_modulate = team_color
	call_deferred("update_hud")
	$PickupArea.area_entered.connect(_on_pickup_area_entered)
	
func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return
		
	if not is_local_player:
		velocity = Vector2.ZERO
		return
	
	var network = get_tree().current_scene.get_node_or_null(
		"NetworkManager"
	)
	
	if network != null and network.match_ended:
		velocity = Vector2.ZERO
		return
		
	var direction := Input.get_vector(
		"move_left", "move_right", "move_up", "move_down")
	velocity = direction * move_speed
	move_and_slide()
	
	look_at(get_global_mouse_position())
	
	fire_timer = maxf(fire_timer - delta, 0.0)
	
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		shoot()
		
	if Input.is_action_just_pressed("reload"):
		reload()
		
func shoot() -> void:
	print(
		"[SHOOT DEBUG] ammo=", ammo,
		" reloading=", is_reloading,
		" fire_timer=", fire_timer,
		" dead=", is_dead
	)
	if is_dead:
		return
		
	if fire_timer > 0.0 or is_reloading or ammo <= 0:
		return
			
	if bullet_scene == null:
		return
		
	var network = get_tree().current_scene.get_node_or_null(
		"NetworkManager"
	)
	if network != null and network.match_ended:
		return
	
	fire_timer = fire_cooldown
	
	network.request_shoot(global_rotation)

		
func take_damage(amount: int) -> void:
	hp = maxi(hp - amount, 0)
	update_hud()
	
	print(name, "HP: ", hp)
	
	if hp == 0:
		die()
		
func die() -> void:
	if is_dead: 
		return
	is_dead = true
	print(name, "You die", respawn_time, "후에 부활")
	visible = false
	collision_layer = 0
	collision_mask = 0
	
	await get_tree().create_timer(respawn_time).timeout
	
	respawn()

func reload() -> void:
	if not is_local_player or is_dead:
		return 
		
	if is_reloading or ammo == magazine_size:
		return
		
	var network = get_tree().current_scene.get_node_or_null(
		"NetworkManager"
	)
	
	if network == null or network.match_ended:
		return
		
	print("[RELOAD] 서버에 재장전 요청")
	network.request_reload()
	
func respawn() -> void:
	global_position = spawn_position
	
	hp = max_hp
	
	ammo = magazine_size
	update_hud()
	is_reloading = false
	fire_timer = 0.0
	
	collision_layer = original_collision_layer
	collision_mask = original_collision_mask
	
	visible = true
	is_dead = false
	
	print(name, "부활 완료 HP: ", hp)

func server_die() -> void:
	if is_dead:
		return
	is_dead = true
	hp = 0
	velocity = Vector2.ZERO
	collision_layer = 0
	collision_mask = 0
	visible = false
	update_hud()

func server_respawn(new_position: Vector2, new_hp: int) -> void:
	global_position = new_position
	hp = new_hp
	is_dead = false
	velocity = Vector2.ZERO
	collision_layer = original_collision_layer
	collision_mask = original_collision_mask
	visible = true
	fire_timer = 0.0
	is_reloading = false
	update_hud()
	
func update_hud() -> void:
	if not is_local_player:
		return
	
	var hud = get_tree().current_scene.get_node_or_null("CanvasLayer/HUD")
	
	if hud == null:
		return
		
	hud.update_health(hp, max_hp)
	hud.update_ammo(ammo, magazine_size)
	hud.update_currency(silver, diamond)
	
func _on_pickup_area_entered(area: Area2D) -> void:
	if not is_local_player or is_dead:
		return

	if area.is_in_group("coins"):
		collect_coin(area)
		
func collect_coin(coin: Area2D):
	var coin_id: int = int(coin.get_meta("coin_id", -1))
	
	if coin_id < 0:
		return
		
	var network = get_tree().current_scene.get_node_or_null(
		"NetworkManager"
	)
	
	if network == null:
		return
	var distance := global_position.distance_to(coin.global_position)
	print(
		"[GODOT PICKUP] Coin=", coin_id,
		" Player=", global_position,
		" CoinPos=", coin.global_position,
		" Distance=", snappedf(distance, 0.1)
	)
	network.request_collect_coin(coin_id)
