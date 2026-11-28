extends CharacterBody2D

@export var move_speed : float = 800.0
@export var bullet_scene: PackedScene
@export var max_hp: int = 300
@export var magazine_size: int = 12
@export var reload_time: float = 1.5
@export var is_local_player: bool = true
@export var respawn_time: float = 0.5


@onready var muzzle: Marker2D = $Muzzle

var fire_cooldown: float = 0.2
var fire_timer: float = 0.0
var hp: int
var ammo: int = 20
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
	ammo = magazine_size
	call_deferred("update_hud")
	$PickupArea.area_entered.connect(_on_pickup_area_entered)
	
func _physics_process(delta: float) -> void:
	if is_dead:
		velocity = Vector2.ZERO
		return
		
	if not is_local_player:
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
	if is_dead:
		return
		
	if fire_timer > 0.0 or is_reloading:
		return
		
	if ammo <= 0:
		return
	
	if bullet_scene == null:
		return
	
	ammo -= 1
	update_hud()
	fire_timer = fire_cooldown
	
	var bullet = bullet_scene.instantiate()
	bullet.shooter = self
	get_tree().current_scene.add_child(bullet)
	
	bullet.global_position = muzzle.global_position
	bullet.direction = Vector2.RIGHT.rotated(global_rotation)
	bullet.rotation = global_rotation
	
	print("남은 탄창 수: ", ammo)
		
func take_damage(amount: int) -> void:
	hp = maxi(hp - amount, 0)
	update_hud()
	
	print(name, "HP: ", hp)
	
	if hp == 0:
		die()
		
func die() -> void:
	if is_dead: 
		return
		
	print(name, "You die", respawn_time, "후에 부활")
	visible = false
	collision_layer = 0
	collision_mask = 0
	
	await get_tree().create_timer(respawn_time).timeout
	
	respawn()

func reload() -> void:
	if is_reloading or ammo == magazine_size:
		return
	
	is_reloading = true
	print("재장전 중")
	
	await get_tree().create_timer(reload_time).timeout
	
	if not is_inside_tree():
		return
		
	ammo = magazine_size
	is_reloading = false
	
	print("재장전 완료")
	update_hud()
	
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
	
func update_hud() -> void:
	if not is_local_player:
		return
	
	var hud = get_tree().current_scene.get_node_or_null("CanvasLayer/HUD")
	
	if hud == null:
		return
		
	hud.update_health(hp, max_hp)
	hud.update_ammo(ammo, magazine_size)
	
func _on_pickup_area_entered(area: Area2D):
	if area.is_in_group("coins"):
		collect_coin(area)
		
func collect_coin(coin: Area2D):
	var coin_type = coin.get("coin_type")
	var amount = coin.get("amount")
	
	if coin_type == "silver":
		silver += amount
		print("은화 획득! 현재 은화: ", silver)
		
	elif coin_type == "diamond":
		diamond += amount
		print("다이아몬드 획득! 현재 다이아: ", diamond)
		
	coin.queue_free()
