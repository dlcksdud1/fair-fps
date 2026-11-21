extends Control

@onready var health_bar: ProgressBar = $HealthBar
@onready var ammo_label: Label = $AmmoLabel
@onready var silver_label: Label = $CurrencyContainer/SilverLabel
@onready var diamond_label: Label = $CurrencyContainer/DiamondLabel
@onready var timer_label: Label = $TimerLabel

func _ready() -> void:
	print("HUD HealthBar: ", health_bar)
	
func update_health(current_hp: int, max_hp: int) -> void:
	health_bar.max_value = max_hp
	health_bar.value = current_hp
	
func update_ammo(current_ammo: int, magazine_size: int) -> void:
	ammo_label.text = "%d / %d" % [current_ammo, magazine_size]

func update_currency(silver: int, diamond: int) -> void:
	silver_label.text = "SILVER: %d / " % silver
	diamond_label.text = "DIAMOND: %d" % diamond
	
func update_timer(seconds: int) -> void:
	var minutes := int(seconds / 60)
	var remaining := seconds % 60
	timer_label.text = "%02d:%02d" % [minutes, remaining]
