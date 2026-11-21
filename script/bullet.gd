extends Area2D

@export var speed: float = 700.0
@export var lifetime: float = 1.5
@export var damage: int = 25

var direction: Vector2 = Vector2.RIGHT
var shooter: CollisionObject2D = null
var elapsed: float = 0.0
var visual_only: bool = false

func _physics_process(delta: float) -> void:
	elapsed += delta
	
	if elapsed >= lifetime:
		queue_free()
		return
	
	var from := global_position
	var to := from + direction.normalized() * speed * delta
	var query := PhysicsRayQueryParameters2D.create(from, to)
	
	query.collision_mask = collision_mask
	if is_instance_valid(shooter):
		query.exclude = [shooter.get_rid()]
		
	var hit := get_world_2d().direct_space_state.intersect_ray(query)
	
	if not hit.is_empty():
		var target = hit["collider"]

		print("총알 명중: ", target.name)
		print("데미지 함수 존재: ", target.has_method("take_damage"))

		if not visual_only and target.has_method("take_damage"):
			target.take_damage(damage)

		global_position = hit["position"]
		queue_free()
		return 
		
	global_position = to
