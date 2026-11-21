# Java TCP prototype imported from MyFairPlay.zip

This is a standalone TCP prototype. It listens on port 7777 and reads `spawn_points.json` from its current working directory. Run only one port-7777 server at a time.

The Godot scripts and scenes were imported into the main project. This Java prototype is kept separate from `server/server.py`, `server/secure_server.py`, `server/weak_server.py`, and the Spring Boot backend. The Gradle entry point is `FairPlay`, matching `src/main/java/FairPlay.java`.