extends Node

@export var coin_scene: PackedScene

const HOST := "127.0.0.1"
const PORT := 7777
const SEND_INTERVAL := 0.05

@onready var player1 = $"../Player"
@onready var player2 = $"../Player2"

var tcp := StreamPeerTCP.new()
var my_id: int = 0
var receive_buffer: String = ""
var send_timer: float = 0.0
var network_coins: Dictionary = {}
var pending_coins: Dictionary = {}
var match_ended: bool = false

func _ready() -> void:
	#서버가 플레이어 번호를 배정할 때까지 입력 차단
	player1.is_local_player = false
	player2.is_local_player = false
	
	var error := tcp.connect_to_host(HOST, PORT)
	
	if error != OK:
		push_error("서버 연결 시작실패: " + str(error))
	else:
		print("서버 연결 시도 중...")
	
	call_deferred("export_spawn_config")
	
func _process(delta: float) -> void:
	tcp.poll()
	
	var status := tcp.get_status()
	
	if status == StreamPeerTCP.STATUS_ERROR:
		push_error("서버 연결 오류")
		set_process(false)
		return
		
	if status != StreamPeerTCP.STATUS_CONNECTED:
		return
		
	receive_messages()
	
	if my_id == 0:
		return
		
	send_timer += delta
	
	if send_timer >= SEND_INTERVAL:
		send_timer = 0.0
		send_my_position()
		
func receive_messages() -> void:
	var available := tcp.get_available_bytes()
	
	if available > 0:
		receive_buffer += tcp.get_utf8_string(available)
		
	while receive_buffer.contains("\n"):
		var newline_index := receive_buffer.find("\n")
		var line := receive_buffer.substr(0, newline_index).strip_edges()
		
		receive_buffer = receive_buffer.substr(newline_index + 1)
		
		var message = JSON.parse_string(line)
		
		if typeof(message) == TYPE_DICTIONARY:
			handle_message(message)
			
func handle_message(message: Dictionary) -> void:
	match message.get("type", ""):
		"welcome":
			my_id = int(message.get("id", 0))
			
			player1.is_local_player = (my_id == 1)
			player2.is_local_player = (my_id == 2)
			
			player1.get_node("Camera2D").enabled = (my_id == 1)
			player2.get_node("Camera2D").enabled = (my_id == 2)
			
			print("서버 접속 완료! 내 번호: ", my_id)
			
			get_local_player().update_hud()
			
		"position":
			var other_id := int(message.get("id", 0))
			var target = get_player(other_id)
			
			if target != null and other_id != my_id:
				target.global_position = Vector2(
					float(message.get("x", 0)),
					float(message.get("y", 0))
				)
				
				target.global_rotation = float(message.get("rotation", 0))
		"leave":
			print("상대 플레이어 연결 종료: ", message.get("id"))
			
		"coin_spawn":
			spawn_network_coin(message)
			
		"coin_remove":
			var coin_id := int(message.get("coin_id", -1))
			
			pending_coins.erase(coin_id)
			
			if network_coins.has(coin_id):
				var coin = network_coins[coin_id]
				
				if is_instance_valid(coin):
					coin.queue_free()
					
				network_coins.erase(coin_id)
				
		"currency_update":
			var player = get_local_player()
			
			if player != null:
				player.silver = int(message.get("silver", 0))
				player.diamond = int(message.get("diamond", 0))
				
				player.update_hud()
				
				print("서버 재화 갱신: 은화=", player.silver, ", 다이아=", player.diamond)
		
		"coin_rejected":
			var coin_id := int(message.get("coin_id", -1))
			pending_coins.erase(coin_id)
			
			print("코인 획득 거절! ID=", coin_id, " 이유=", message.get("reason", "unknown"))
		
		"match_timer":
			var remaining := int(message.get("remaining", 0))

			var hud = get_tree().current_scene.get_node_or_null(
				"CanvasLayer/HUD"
			)
			if hud != null:
				hud.update_timer(remaining)
				
		"bullet_spawn":
			spawn_server_bullet(message)
			
		"ammo_update":
			var player = get_local_player()
			
			if player != null:
				player.ammo = int(message.get("ammo", 0))
				player.is_reloading = bool(message.get("reloading", false))
				player.update_hud()
				
			print(
			"[AMMO UPDATE] ammo=", player.ammo,
			" reloading=", player.is_reloading
			)
				
		"shoot_rejected":
			print("서버에서 발사 거절")
				
		"match_end":
			match_ended = true
			print("경기 종료!")
			
			var hud = get_tree().current_scene.get_node_or_null(
				"CanvasLayer/HUD"
			)
			
			if hud != null:
				hud.update_timer(0)
func send_my_position() -> void:
	var player = get_local_player()
	
	if player == null:
		return
		
	var message := JSON.stringify({
		"type": "position",
		"x": player.global_position.x,
		"y": player.global_position.y,
		"rotation": player.global_rotation
	}) + "\n"
	
	tcp.put_data(message.to_utf8_buffer())
	
func spawn_network_coin(message: Dictionary) -> void:
	var coin_id := int(message.get("coin_id", -1))
	if coin_id < 0:
		return
	
	# 같은 ID의 코인이 이미 존재하면 중복 생성하지 않음
	if network_coins.has(coin_id):
		return
	
	if coin_scene == null:
		push_error("NetworkManager: Coin Scene이 없습니다.")
		return
	
	var coin = coin_scene.instantiate()
	
	coin.coin_type = str(message.get("coin_type", "silver"))
	coin.amount = int(message.get("amount", 1))
	
	# 서버 코인 식별자 저장
	coin.set_meta("coin_id", coin_id)

	get_tree().current_scene.add_child(coin)
	
	coin.global_position = Vector2(
		float(message.get("x", 0)),
		float(message.get("y", 0))
	)
	network_coins[coin_id] = coin
	
	print( "서버 코인 생성: ID=", coin_id," 종류=", coin.coin_type," 위치=", coin.global_position)
func get_player(id: int):
	match id:
		1:
			return player1
		2:
			return player2
			
	return null
	
func get_local_player():
	return get_player(my_id)
	
func request_collect_coin(coin_id: int) -> void:
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	if my_id == 0:
		return
	if pending_coins.has(coin_id):
		return
		
	pending_coins[coin_id] = true
	send_my_position()
	
	var message := JSON.stringify({
		"type": "collect_coin",
		"coin_id": coin_id
	}) + "\n"
	
	var error := tcp.put_data(message.to_utf8_buffer())
	
	if error != OK:
		pending_coins.erase(coin_id)
		
func request_shoot(rotation_value: float) -> void:
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	
	if my_id == 0 or match_ended:
		return
	
	var message := JSON.stringify({
		"type": "shoot_request",
		"rotation": rotation_value
	}) + "\n"
	
	tcp.put_data(message.to_utf8_buffer())

func request_reload() -> void:
	if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
		
	if my_id == 0 or match_ended:
		return
		
	var message := JSON.stringify({
		"type": "reload_request"
	}) + "\n"
	
	tcp.put_data(message.to_utf8_buffer())
	
func spawn_server_bullet(message: Dictionary) -> void:
	var shooter_id := int(message.get("shooter_id", 0))
	var shooter = get_player(shooter_id)
	
	if shooter == null or shooter.bullet_scene == null:
		return
	
	var bullet = shooter.bullet_scene.instantiate()
	bullet.shooter = shooter
	bullet.visual_only = true
	
	get_tree().current_scene.add_child(bullet)
	
	var rotation_value := float(message.get("rotation", 0))
	
	bullet.global_position = Vector2(
		float(message.get("x", 0)),
		float(message.get("y", 0))
	)
	
	bullet.direction = Vector2.RIGHT.rotated(rotation_value)
	bullet.global_rotation = rotation_value
	
func export_spawn_config() -> void:
	var configs: Array = []
	
	for node in get_tree().get_nodes_in_group("coin_spawners"):
		configs.append(node.get_spawn_config())
		
	var file = FileAccess.open(
		"user://spawn_points.json",
		FileAccess.WRITE
	)
	
	if file == null:
		push_error("생성 지점 파일 생성 실패")
		return
	
	file.store_string(JSON.stringify(configs, "\t"))
	file.close()
	
	print(
		"생성 지점 설정 저장 완료: ",
		ProjectSettings.globalize_path(
			"user://spawn_points.json"
		)
	)
	
