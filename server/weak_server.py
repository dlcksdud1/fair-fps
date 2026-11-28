from __future__ import annotations

import asyncio
import json
import os

from game_core import GameCore
from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed

# Bind all interfaces so localhost and other PCs on the LAN can connect.
HOST = os.getenv("FAIR_FPS_HOST", "0.0.0.0")
PORT = int(os.getenv("FAIR_FPS_WEAK_WS_PORT", "7779"))
MAX_MESSAGE = 8192
game = GameCore("weak")


async def handle(ws: ServerConnection) -> None:
    if ws.request.path != "/ws":
        await ws.close(code=1008, reason="use /ws")
        return

    async def send(message: dict) -> None:
        await ws.send(json.dumps(message, separators=(",", ":"), allow_nan=True))

    async def close() -> None:
        await ws.close(code=1008, reason="room full")

    player_id = await game.connect(send, close)
    if player_id is None:
        return
    try:
        async for raw in ws:
            if len(raw.encode("utf-8")) > MAX_MESSAGE:
                continue
            try:
                message = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                continue
            if not isinstance(message, dict):
                continue
            # Keep the older simulator message names working with the shared rules.
            kind = message.get("type")
            if kind == "move":
                message = {"type": "position", "x": message.get("x"), "y": message.get("y"),
                           "rotation": game.players[player_id]["rotation"]}
            elif kind == "shoot":
                message = {"type": "shoot_request", "rotation": message.get("rotation", 0),
                           "damage": message.get("damage", 25)}
            elif kind == "reload":
                message = {"type": "reload_request", "reload_time": message.get("reload_time", 0)}
            await game.process(player_id, message)
    except ConnectionClosed:
        pass
    finally:
        await game.disconnect(player_id)


async def main() -> None:
    async with serve(handle, HOST, PORT, max_size=MAX_MESSAGE):
        print(f"FairFPS weak WebSocket server listening on ws://{HOST}:{PORT}/ws", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("Server stopped")
