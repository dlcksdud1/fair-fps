# FairFPS

Godot 4 multiplayer shooter security project. The project compares weak and secure server-side validation and provides a game client for local experiments.

## Game

Open this directory in Godot. The main scene is `scene/main.tscn`. It includes networked coin spawners and connects to one of the WebSocket game servers on port 7778 or 7779.

## Servers

- `server/secure_server.py`: secure WebSocket server on port 7778
- `server/weak_server.py`: intentionally vulnerable WebSocket server for controlled testing
- `backend/`: Spring Boot backend with secure and vulnerable profiles

See [server/README.md](server/README.md) for setup and run commands.
