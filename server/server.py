from __future__ import annotations

import asyncio
import json
import os

from game_core import GameCore

HOST = os.getenv("FAIR_FPS_HOST", "0.0.0.0")
PORT = int(os.getenv("FAIR_FPS_PORT", "7777"))
MAX_LINE = 8192
game = GameCore("server")


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    async def send(message: dict) -> None:
        writer.write((json.dumps(message, separators=(",", ":"), allow_nan=True) + "\n").encode())
        await writer.drain()

    async def close() -> None:
        writer.close()

    player_id = await game.connect(send, close)
    if player_id is None:
        return
    try:
        while line := await reader.readline():
            if len(line) > MAX_LINE or not line.endswith(b"\n"):
                break
            try:
                message = json.loads(line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
            if isinstance(message, dict):
                await game.process(player_id, message)
    except (ConnectionError, asyncio.IncompleteReadError, ValueError):
        pass
    finally:
        await game.disconnect(player_id)
        writer.close()
        await writer.wait_closed()


async def main() -> None:
    server = await asyncio.start_server(handle, HOST, PORT, limit=MAX_LINE + 1)
    print(f"FairFPS TCP server listening on {HOST}:{PORT}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nServer stopped")
