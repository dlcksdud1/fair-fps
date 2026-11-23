from __future__ import annotations

import asyncio
import json
import math
import random
import time
from typing import Awaitable, Callable

MAX_HP = 100
MAGAZINE_SIZE = 12
BULLET_DAMAGE = 25
BULLET_RANGE = 1050.0
PLAYER_HIT_RADIUS = 24.0
MOVE_SPEED = 250.0
MOVE_TOLERANCE = 25.0
# Godot's pickup overlap is about 72 px; this leaves room for position-update delay.
COIN_PICKUP_DISTANCE = 100.0
FIRE_COOLDOWN = 0.2
RELOAD_SECONDS = 1.5
RESPAWN_SECONDS = 3.0
MATCH_SECONDS = 180
SPAWNS = {1: (116.0, 122.0), 2: (4250.0, 141.0)}
MARKERS = [(0, -19), (-27, -10), (24, -10), (-27, 17), (0, 21), (26, 16), (-28, 0), (17, 10), (0, 0), (-1, -9)]
SPAWNERS = [
    ("silver", 5.0, 0.2, (150.0, 320.0)),
    ("silver", 5.0, 0.2, (4237.0, 323.0)),
    ("diamond", 10.0, 1.0, (2200.0, 277.0)),
]
Send = Callable[[dict], Awaitable[None]]
Close = Callable[[], Awaitable[None]]


class GameCore:
    """Shared game rules; transports provide only send and close callbacks."""

    def __init__(self, mode: str) -> None:
        self.mode = mode
        self.secure = mode == "secure"
        self.validate = mode != "weak"
        self.clients: dict[int, tuple[Send, Close]] = {}
        self.players: dict[int, dict] = {}
        self.updated_at: dict[int, float] = {}
        self.movement_credit: dict[int, float] = {}
        self.last_shot: dict[int, float] = {}
        self.reload_until: dict[int, float] = {}
        self.violations: dict[int, int] = {}
        self.coins: dict[int, dict] = {}
        self.coin_id = 0
        self.spawners: list[dict] = []
        self.match_start: float | None = None
        self.match_ended = False
        self.match_task: asyncio.Task | None = None

    @staticmethod
    def _number(value: object) -> float | None:
        if type(value) not in (int, float):
            return None
        try:
            result = float(value)
        except (OverflowError, ValueError):
            return None
        return result if math.isfinite(result) else None

    @staticmethod
    def _new_player(player_id: int) -> dict:
        x, y = SPAWNS[player_id]
        return {"x": x, "y": y, "rotation": 0.0, "hp": MAX_HP, "ammo": MAGAZINE_SIZE,
                "alive": True, "silver": 0, "diamond": 0}

    async def _send(self, player_id: int, message: dict) -> None:
        client = self.clients.get(player_id)
        if client:
            await client[0](message)

    async def broadcast(self, message: dict) -> None:
        for send, _ in list(self.clients.values()):
            try:
                await send(message)
            except Exception:
                pass

    async def connect(self, send: Send, close: Close) -> int | None:
        player_id = next((i for i in (1, 2) if i not in self.clients), None)
        if player_id is None:
            await send({"type": "full"})
            await close()
            return None

        if not self.clients:
            self._start_match()
        self.clients[player_id] = (send, close)
        self.players[player_id] = self._new_player(player_id)
        now = time.monotonic()
        self.updated_at[player_id] = now
        self.movement_credit[player_id] = MOVE_TOLERANCE
        self.last_shot[player_id] = 0.0
        self.reload_until[player_id] = 0.0
        self.violations[player_id] = 0
        await send({"type": "welcome", "id": player_id})
        await send({"type": "snapshot", "players": self.players})
        await send({"type": "match_timer", "remaining": MATCH_SECONDS})
        for coin in self.coins.values():
            await send({"type": "coin_spawn", **coin})
        print(f"[CONNECT] mode={self.mode} player={player_id}", flush=True)
        return player_id

    def _start_match(self) -> None:
        self.match_start = time.monotonic()
        self.match_ended = False
        self.players = {player_id: self._new_player(player_id) for player_id in SPAWNS}
        self.coins.clear()
        self.coin_id = 0
        now = self.match_start
        self.spawners = [
            {"type": kind, "interval": interval, "scale": scale, "base": base,
             "next": now + interval, "max": len(MARKERS)}
            for kind, interval, scale, base in SPAWNERS
        ]
        self.match_task = asyncio.create_task(self._run_match())

    async def _run_match(self) -> None:
        last_remaining = MATCH_SECONDS + 1
        while self.clients and not self.match_ended and self.match_start is not None:
            await asyncio.sleep(0.1)
            now = time.monotonic()
            remaining = max(0, MATCH_SECONDS - int(now - self.match_start))
            if remaining != last_remaining:
                await self.broadcast({"type": "match_timer", "remaining": remaining})
                last_remaining = remaining
            if remaining == 0:
                self.match_ended = True
                await self.broadcast({"type": "match_end"})
                break
            if not self.match_ended:
                for spawner_id, spawner in enumerate(self.spawners):
                    if now >= spawner["next"]:
                        self._spawn_coin(spawner_id, spawner)
                        spawner["next"] += spawner["interval"]

    def _spawn_coin(self, spawner_id: int, spawner: dict) -> None:
        occupied = {coin["point"] for coin in self.coins.values() if coin["spawner"] == spawner_id}
        available = [i for i in range(len(MARKERS)) if i not in occupied]
        if not available or len(occupied) >= spawner["max"]:
            return
        point_id = random.choice(available)
        dx, dy = MARKERS[point_id]
        x, y = spawner["base"]
        self.coin_id += 1
        coin = {"coin_id": self.coin_id, "coin_type": spawner["type"], "amount": 1,
                "x": x + dx * spawner["scale"], "y": y + dy * spawner["scale"],
                "spawner": spawner_id, "point": point_id}
        self.coins[self.coin_id] = coin
        event = {key: value for key, value in coin.items() if key not in ("spawner", "point")}
        asyncio.create_task(self.broadcast({"type": "coin_spawn", **event}))

    async def disconnect(self, player_id: int) -> None:
        if self.clients.pop(player_id, None) is not None:
            await self.broadcast({"type": "leave", "id": player_id})
            print(f"[DISCONNECT] mode={self.mode} player={player_id}", flush=True)

    async def _flag(self, player_id: int, action: str, detail: str, reason: str) -> None:
        self.violations[player_id] = self.violations.get(player_id, 0) + 1
        count = self.violations[player_id]
        print(f"[CHEAT DETECTED] mode=secure player={player_id} action={action} detail={detail} count={count}", flush=True)
        await self._send(player_id, {"type": "request_rejected", "reason": reason})
        if count >= 3:
            client = self.clients.get(player_id)
            if client:
                await client[1]()

    async def process(self, player_id: int, message: dict) -> None:
        player = self.players.get(player_id)
        if player is None:
            return
        if not isinstance(message.get("type"), str):
            if self.secure:
                await self._flag(player_id, "message", "missing or invalid type", "invalid message")
            return
        kind = message["type"]
        if self.match_ended:
            if self.secure and kind in {"position", "shoot_request", "reload_request", "collect_coin"}:
                await self._flag(player_id, kind, "request after match end", "match ended")
            return

        if kind == "position":
            extra = set(message) - {"type", "x", "y", "rotation"}
            x, y, rotation = (self._number(message.get(key)) for key in ("x", "y", "rotation"))
            if x is None or y is None or rotation is None:
                if self.secure:
                    await self._flag(player_id, kind, "non-finite or non-numeric coordinates", "invalid position")
                return
            now = time.monotonic()
            if self.validate and extra:
                if self.secure:
                    await self._flag(player_id, kind, f"unexpected fields={sorted(extra)}", "unexpected position fields")
                else:
                    await self._send(player_id, {"type": "request_rejected", "reason": "unexpected position fields"})
                return
            if self.validate:
                elapsed = max(0.0, now - self.updated_at[player_id])
                allowed = min(MOVE_TOLERANCE, self.movement_credit[player_id] + MOVE_SPEED * elapsed)
                distance = math.hypot(x - player["x"], y - player["y"])
                if not player["alive"]:
                    return
                if distance > allowed:
                    if self.secure:
                        await self._flag(player_id, kind, f"distance={distance:.1f}px limit={allowed:.1f}px", "movement exceeds limit")
                    await self._send(player_id, {"type": "position_rejected", "x": player["x"], "y": player["y"], "rotation": player["rotation"]})
                    return
                self.movement_credit[player_id] = allowed - distance
            player.update(x=x, y=y, rotation=math.atan2(math.sin(rotation), math.cos(rotation)))
            if not self.secure and "hp" in message:
                player["hp"] = max(0, min(MAX_HP, int(self._number(message["hp"]) or 0)))
                await self.broadcast({"type": "hp_update", "id": player_id, "hp": player["hp"]})
            if not self.secure and "ammo" in message:
                player["ammo"] = int(self._number(message["ammo"]) or 0)
                await self._send(player_id, {"type": "ammo_update", "ammo": player["ammo"], "reloading": False})
            if self.validate or not extra:
                self.updated_at[player_id] = now
            await self.broadcast({"type": "position", "id": player_id, "x": x, "y": y, "rotation": player["rotation"]})

        elif kind == "shoot_request":
            extra = set(message) - {"type", "rotation"}
            rotation = self._number(message.get("rotation"))
            now = time.monotonic()
            if self.validate:
                reason = None
                if extra:
                    reason = "untrusted shot fields"
                elif rotation is None or not player["alive"] or player["ammo"] <= 0 or now < self.reload_until.get(player_id, 0.0):
                    reason = "shot not allowed"
                elif now - self.last_shot.get(player_id, 0.0) < FIRE_COOLDOWN - 0.02:
                    reason = "shot too fast"
                if reason:
                    if self.secure:
                        await self._flag(player_id, kind, reason, reason)
                    else:
                        await self._send(player_id, {"type": "shoot_rejected", "reason": reason})
                    return
            elif rotation is None:
                rotation = player["rotation"]
            if not self.validate:
                if self._number(message.get("x")) is not None:
                    player["x"] = self._number(message["x"])
                if self._number(message.get("y")) is not None:
                    player["y"] = self._number(message["y"])
                if self._number(message.get("ammo")) is not None:
                    player["ammo"] = int(self._number(message["ammo"]))
            rotation = math.atan2(math.sin(rotation), math.cos(rotation))
            self.last_shot[player_id] = now
            player["ammo"] = max(0, player["ammo"] - 1)
            await self._send(player_id, {"type": "ammo_update", "ammo": player["ammo"], "reloading": False})
            radians = rotation
            muzzle_x = player["x"] + 32.28 * math.cos(radians) - 9.0 * math.sin(radians)
            muzzle_y = player["y"] + 32.28 * math.sin(radians) + 9.0 * math.cos(radians)
            await self.broadcast({"type": "bullet_spawn", "shooter_id": player_id,
                                  "x": muzzle_x, "y": muzzle_y, "rotation": rotation})
            target_id = self._find_hit(player_id, muzzle_x, muzzle_y, rotation)
            if not self.secure and "target_id" in message:
                try:
                    target_id = int(message["target_id"])
                except (TypeError, ValueError, OverflowError):
                    pass
            if target_id in self.clients:
                damage = BULLET_DAMAGE
                if not self.validate and self._number(message.get("damage")) is not None:
                    damage = int(self._number(message["damage"]))
                await self._hit(target_id, damage)
            print(f"[SHOT] mode={self.mode} player={player_id} ammo={player['ammo']}", flush=True)

        elif kind == "reload_request":
            extra = set(message) - {"type"}
            now = time.monotonic()
            if self.validate:
                reason = None
                if extra:
                    reason = "untrusted reload fields"
                elif not player["alive"] or player["ammo"] >= MAGAZINE_SIZE or now < self.reload_until.get(player_id, 0.0):
                    reason = "reload not allowed"
                if reason:
                    if self.secure:
                        await self._flag(player_id, kind, reason, reason)
                    else:
                        await self._send(player_id, {"type": "request_rejected", "reason": reason})
                    return
                duration = RELOAD_SECONDS
            else:
                duration = self._number(message.get("reload_time")) if "reload_time" in message else RELOAD_SECONDS
                duration = max(0.0, duration or 0.0)
            deadline = now + duration
            self.reload_until[player_id] = deadline
            await self._send(player_id, {"type": "ammo_update", "ammo": player["ammo"], "reloading": True})
            asyncio.create_task(self._finish_reload(player_id, deadline))

        elif kind == "collect_coin":
            coin_id_value = message.get("coin_id")
            if self.secure and type(coin_id_value) is not int:
                await self._flag(player_id, kind, f"invalid coin_id={coin_id_value}", "invalid coin id")
                return
            try:
                coin_id = int(coin_id_value)
            except (TypeError, ValueError, OverflowError):
                coin_id = -1
            coin = self.coins.get(coin_id)
            if coin is None:
                if self.secure:
                    await self._flag(player_id, kind, f"unknown coin_id={coin_id_value}", "unknown coin")
                else:
                    await self._send(player_id, {"type": "coin_rejected", "coin_id": coin_id, "reason": "unknown coin"})
                return
            distance = math.hypot(player["x"] - coin["x"], player["y"] - coin["y"])
            if self.validate and distance > COIN_PICKUP_DISTANCE:
                if self.secure:
                    print(f"[PICKUP REJECTED] mode=secure player={player_id} reason=out of reach distance={distance:.1f}px", flush=True)
                await self._send(player_id, {"type": "coin_rejected", "coin_id": coin_id, "reason": "out of reach"})
                return
            kind_value = coin["coin_type"]
            amount = coin["amount"]
            if not self.validate:
                kind_value = message.get("coin_type", kind_value)
                amount = self._number(message.get("amount")) or amount
            player[kind_value if kind_value in ("silver", "diamond") else "silver"] += int(amount)
            self.coins.pop(coin_id, None)
            await self.broadcast({"type": "coin_remove", "coin_id": coin_id})
            await self._send(player_id, {"type": "currency_update", "silver": player["silver"], "diamond": player["diamond"]})

        elif kind == "state":
            if self.validate:
                if self.secure:
                    await self._flag(player_id, kind, "client attempted to set game state", "client state is not accepted")
                else:
                    await self._send(player_id, {"type": "request_rejected", "reason": "client state is not accepted"})
                return
            for key in ("x", "y", "rotation", "hp", "ammo", "alive", "silver", "diamond"):
                if key in message:
                    value = self._number(message[key])
                    if key == "alive" and isinstance(message[key], bool):
                        player[key] = message[key]
                    elif value is not None:
                        player[key] = value if key in ("x", "y", "rotation") else int(value)
            await self.broadcast({"type": "position", "id": player_id, "x": player["x"], "y": player["y"], "rotation": player["rotation"]})
            await self.broadcast({"type": "hp_update", "id": player_id, "hp": player["hp"]})
            await self._send(player_id, {"type": "ammo_update", "ammo": player["ammo"], "reloading": False})
            await self._send(player_id, {"type": "currency_update", "silver": player["silver"], "diamond": player["diamond"]})

        else:
            if self.secure:
                await self._flag(player_id, kind, "unsupported message type", "unknown request")

    def _find_hit(self, shooter_id: int, x: float, y: float, rotation: float) -> int | None:
        dx, dy = math.cos(rotation), math.sin(rotation)
        hits = []
        for target_id, target in self.players.items():
            if target_id == shooter_id or target_id not in self.clients or not target["alive"]:
                continue
            vx, vy = target["x"] - x, target["y"] - y
            along = vx * dx + vy * dy
            across = abs(vx * dy - vy * dx)
            if 0 <= along <= BULLET_RANGE and across <= PLAYER_HIT_RADIUS:
                hits.append((along, target_id))
        return min(hits)[1] if hits else None

    async def _hit(self, player_id: int, damage: int) -> None:
        player = self.players[player_id]
        if not player["alive"]:
            return
        player["hp"] = max(0, min(MAX_HP, player["hp"] - damage))
        if player["hp"] == 0:
            player["alive"] = False
            asyncio.create_task(self._respawn(player_id))
        await self.broadcast({"type": "hp_update", "id": player_id, "hp": player["hp"]})
        print(f"[HIT] mode={self.mode} player={player_id} hp={player['hp']}", flush=True)

    async def _respawn(self, player_id: int) -> None:
        await asyncio.sleep(RESPAWN_SECONDS)
        player = self.players[player_id]
        x, y = SPAWNS[player_id]
        player.update(x=x, y=y, rotation=0.0, hp=MAX_HP, alive=True, ammo=MAGAZINE_SIZE)
        self.updated_at[player_id] = time.monotonic()
        self.movement_credit[player_id] = MOVE_TOLERANCE
        self.reload_until[player_id] = 0.0
        await self.broadcast({"type": "player_respawn", "id": player_id, "x": x, "y": y, "hp": MAX_HP})
        await self._send(player_id, {"type": "ammo_update", "ammo": MAGAZINE_SIZE, "reloading": False})

    async def _finish_reload(self, player_id: int, deadline: float) -> None:
        await asyncio.sleep(max(0.0, deadline - time.monotonic()))
        if self.reload_until.get(player_id) != deadline:
            return
        self.reload_until[player_id] = 0.0
        player = self.players[player_id]
        player["ammo"] = MAGAZINE_SIZE
        await self._send(player_id, {"type": "ammo_update", "ammo": MAGAZINE_SIZE, "reloading": False})
        print(f"[RELOAD] mode={self.mode} player={player_id} complete", flush=True)
