# FairFPS backend

This is the proposal-aligned Java 17 / Spring Boot / PostgreSQL WebSocket server. It provides two local profiles on the same game protocol:

- Vulnerable (`ws://127.0.0.1:7777/ws`): accepts client-supplied positions and state, and does not enforce ammo or fire cooldown.
- Secure (`ws://127.0.0.1:7778/ws`): computes movement from direction input, caps speed at 250 px/s, owns HP/ammo, enforces 24 rounds, one shot per 500 ms, 10 damage, unique `request_id`s, and logs/rejects invalid requests. Three rejected requests disconnect the session. Opponent ammo is omitted from secure snapshots.

## Start

1. Start PostgreSQL from this folder: `docker compose up -d`.
2. Set an admin key, then choose one profile and run it from this folder:

```powershell
$env:FAIRFPS_ADMIN_KEY = "replace-with-a-local-secret"
$env:FAIRFPS_MODE = "secure"
mvn spring-boot:run
```

Use `vulnerable` instead of `secure` to start the vulnerable server. Java 17+ and Maven 3.6.3+ are required. The defaults use separate ports, so both profiles can run side by side.

Read recent security events with `GET http://127.0.0.1:7778/api/admin/events`, sending `X-Admin-Key` with the configured key. Vulnerable mode uses port 7777; secure mode uses port 7778. Both bind to loopback for the proposal's local-only experiment requirement.

## WebSocket message examples

Connect two clients to `/ws`. The server sends `welcome`, then `state` snapshots. Send newline-free JSON WebSocket text frames:

- Movement: `{"type":"move","x":900,"y":900,"dx":1,"dy":0,"request_id":"m-1"}`. Vulnerable mode trusts `x/y`; secure mode ignores them and applies bounded `dx/dy` using server time.
- Fire: `{"type":"shoot","angle":0,"request_id":"s-1"}`. Secure mode checks living state, ammo, cooldown and aim; a hit within range deals 10 damage.
- Reload: `{"type":"reload","request_id":"r-1"}`. Secure mode restores ammo to 24 subject to its reload interval.
- State tampering scenario: `{"type":"state","x":900,"y":900,"hp":9999,"ammo":9999}`. Vulnerable mode accepts it; secure mode rejects it.

The Godot game client uses the Python WebSocket game servers documented in `../server/README.md`. This Spring Boot backend is a separate service for persistence and security-event demonstrations. Player IDs are session-only, so permanent account bans require authentication and persistent account records.



## Dedicated vulnerable-server launcher

From PowerShell, start PostgreSQL once with `docker compose up -d`, set `FAIRFPS_ADMIN_KEY`, then run:

```powershell
.\run-vulnerable.ps1
```

This launches the WebSocket vulnerable profile on `127.0.0.1:7777`. It is separate from the Python WebSocket game servers in `../server/`.
