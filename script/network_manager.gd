extends Node

@export var coin_scene: PackedScene
@export_enum("weak_server WebSocket", "secure_server WebSocket")
var server_mode: int = 1

const HOST := "127.0.0.1"
const WEAK_WS_PORT := 7779
const SECURE_WS_PORT := 7778
const SEND_INTERVAL := 0.05

@onready var player1 = $"../Player"
@onready var player2 = $"../Player2"

var websocket := WebSocketPeer.new()
var my_id: int = 0
var send_timer: float = 0.0
var network_coins: Dictionary = {}
var pending_coins: Dictionary = {}
var match_ended: bool = false

func _ready() -> void:
	player1.is_local_player = false
	player2.is_local_player = false

	var host := HOST
	# For another PC, uncomment this line and set the server PC's LAN IPv4 address.
	# host = "192.168.0.10"
	var port := WEAK_WS_PORT if server_mode == 0 else SECURE_WS_PORT
	var error := websocket.connect_to_url("ws://%s:%d/ws" % [host, port])
	print("WebSocket 서버 연결 시도 중... port=", port)
	if error != OK:
		push_error("서버 연결 시작 실패: " + str(error))


func _process(delta: float) -> void:
	websocket.poll()
	if websocket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		push_error("WebSocket 서버 연결이 종료되었습니다.")
		set_process(false)
		return
	if websocket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	receive_websocket_messages()

	if my_id == 0:
		return
	send_timer += delta
	if send_timer >= SEND_INTERVAL:
		send_timer = 0.0
		send_my_position()

func receive_websocket_messages() -> void:
	while websocket.get_available_packet_count() > 0:
		_handle_message_text(websocket.get_packet().get_string_from_utf8())

func _handle_message_text(text: String) -> void:
	var message = JSON.parse_string(text)
	if typeof(message) == TYPE_DICTIONARY:
		handle_message(message)

func is_connected_to_server() -> bool:
	return websocket.get_ready_state() == WebSocketPeer.STATE_OPEN

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
			
		"snapshot":
			var players: Dictionary = message.get("players", {})
			for key in players:
				var player_id := int(key)
				var target = get_player(player_id)
				if target != null:
					var state: Dictionary = players[key]
					target.global_position = Vector2(float(state.get("x", 0)), float(state.get("y", 0)))
					target.global_rotation = float(state.get("rotation", 0))
					target.hp = int(state.get("hp", target.hp))
					target.ammo = int(state.get("ammo", target.ammo))
					target.silver = int(state.get("silver", target.silver))
					target.diamond = int(state.get("diamond", target.diamond))
					target.update_hud()
		"position_rejected":
			var player = get_local_player()
			if player != null:
				player.global_position = Vector2(float(message.get("x", 0)), float(message.get("y", 0)))
				player.global_rotation = float(message.get("rotation", 0))
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
				
			if player != null:
				print("[AMMO UPDATE] ammo=", player.ammo, " reloading=", player.is_reloading)
				
		"hp_update":
			var target = get_player(int(message.get("id", 0)))
			if target != null:
				target.hp = int(message.get("hp", target.hp))
				target.update_hud()
				if target.hp <= 0:
					target.server_die()
		"player_respawn":
			var target = get_player(int(message.get("id", 0)))
			if target != null:
				target.server_respawn(
					Vector2(float(message.get("x", 0)), float(message.get("y", 0))),
					int(message.get("hp", target.max_hp))
				)
		"shoot_rejected":
			print("서버에서 발사 거절")
		"request_rejected":
			print("서버 검증에서 요청 거절: ", message.get("reason", "unknown"))
				
		"match_end":
			match_ended = true
			print("경기 종료!")
			var winner := int(message.get("winner", 0))
			var p1_diamond := int(message.get("p1_diamond", 0))
			var p1_silver := int(message.get("p1_silver", 0))
			var p2_diamond := int(message.get("p2_diamond", 0))
			var p2_silver := int(message.get("p2_silver", 0))
			var result_text := "DRAW!"
			var result_color := Color.YELLOW
			if winner == my_id:
				result_text = "VICTORY!"
				result_color = Color.LIME_GREEN
			elif winner != 0:
				result_text = "DEFEAT!"
				result_color = Color.TOMATO

			var hud = get_tree().current_scene.get_node_or_null("CanvasLayer/HUD")
			if hud != null:
				hud.update_timer(0)
				var game_over = hud.get_node_or_null("GameOver")
				if game_over != null:
					var result_label = game_over.get_node_or_null("GameOverLabel")
					if result_label != null:
						result_label.add_theme_font_size_override("font_size", 32)
						result_label.modulate = result_color
						result_label.text = "\n".join([
							result_text,
							"",
							"PLAYER 1",
							"Diamond: %d | Silver: %d" % [p1_diamond, p1_silver],
							"",
							"PLAYER 2",
							"Diamond: %d | Silver: %d" % [p2_diamond, p2_silver]
						])
					game_over.show()
func send_message(message: Dictionary) -> Error:
	if websocket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_UNAVAILABLE
	return websocket.send_text(JSON.stringify(message))

func send_my_position() -> void:
	var player = get_local_player()
	if player == null:
		return
	send_message({
		"type": "position",
		"x": player.global_position.x,
		"y": player.global_position.y,
		"rotation": player.global_rotation
	})

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
	if not is_connected_to_server():
		return
	if my_id == 0:
		return
	if pending_coins.has(coin_id):
		return
		
	pending_coins[coin_id] = true
	send_my_position()
	
	var error := send_message({
		"type": "collect_coin",
		"coin_id": coin_id
	})
	
	if error != OK:
		pending_coins.erase(coin_id)
		
func request_shoot(rotation_value: float) -> void:
	if not is_connected_to_server():
		return
	
	if my_id == 0 or match_ended:
		return
	
	send_message({
		"type": "shoot_request",
		"rotation": rotation_value
	})

func request_reload() -> void:
	if not is_connected_to_server():
		return
		
	if my_id == 0 or match_ended:
		return
		
	send_message({"type": "reload_request"})
	
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
	
