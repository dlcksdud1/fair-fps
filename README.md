# FairFPS

Godot 4 multiplayer shooter security project. The project compares weak and secure server-side validation and provides a game client for local experiments.

## Game

Open this directory in Godot. The main scene is `scene/main.tscn`. It includes networked coin spawners and connects to the TCP prototype on port 7777 by default.

## Servers

- `server/server.py`: original TCP server
- `server/secure_server.py`: secure TCP prototype
- `server/weak_server.py`: intentionally vulnerable WebSocket server for controlled testing
- `server/java_tcp_prototype/`: standalone Java TCP prototype imported from `MyFairPlay.zip`
- `backend/`: Spring Boot backend with secure and vulnerable profiles

Only one server using port 7777 can run at a time. The Java prototype is separate from the existing servers; see its README for details.