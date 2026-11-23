from __future__ import annotations

import asyncio
import json
import os

from game_core import GameCore
from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed

HOST = os.getenv("FAIR_FPS_HOST", "0.0.0.0")
PORT = int(os.getenv("FAIR_FPS_SECURE_WS_PORT", "7778"))
MAX_MESSAGE = 8192
game = GameCore("secure")


async def handle(ws: ServerConnection) -> None:
    async def send(message: dict) -> None:
        await ws.send(json.dumps(message, separators=(",", ":")))

    async def close() -> None:
        await ws.close(code=1008, reason="too many invalid requests")

    player_id = await game.connect(send, close)
    if player_id is None:
        return
    try:
        async for raw in ws:
            if not isinstance(raw, str) or len(raw.encode("utf-8")) > MAX_MESSAGE:
                await game._flag(player_id, "message", "invalid or oversized payload", "invalid message")
                continue
            try:
                message = json.loads(raw)
            except json.JSONDecodeError:
                await game._flag(player_id, "message", "malformed JSON", "invalid JSON")
                continue
            if isinstance(message, dict):
                await game.process(player_id, message)
            else:
                await game._flag(player_id, "message", "expected JSON object", "invalid message")
    except ConnectionClosed:
        pass
    finally:
        await game.disconnect(player_id)


async def main() -> None:
    async with serve(handle, HOST, PORT, max_size=MAX_MESSAGE):
        print(f"FairFPS secure WebSocket server listening on ws://{HOST}:{PORT}", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("Server stopped")
