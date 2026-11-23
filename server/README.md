# FairFPS servers

The three servers share the same game rules and JSON messages. Only the transport and validation policy differ:

| Server | Transport | Address | Validation |
| --- | --- | --- | --- |
| `server.py` | TCP | `127.0.0.1:7777` | Standard movement, ammo, and reload rules; no cheat alerts |
| `weak_server.py` | WebSocket | `ws://127.0.0.1:7779/ws` | Deliberately accepts altered movement, ammo, damage, target, reload, and pickup values |
| `secure_server.py` | WebSocket | `ws://127.0.0.1:7778/` | Checks movement, ammo, fire interval, reload, and pickup requests; rejects tampering and logs `[CHEAT DETECTED]` |

All three use 100 HP, 25 damage per hit, 12 rounds, 0.2-second fire interval, 1.5-second reload, 3-second respawn, a 3-minute match, and the same item spawn rules. Valid play should behave the same on all three.

## Install and start

Run from the project root:

```powershell
cd C:\fair-fps\fair-fps
python -m pip install -r server\requirements.txt
python server\secure_server.py
```

Replace the last line with `python server\server.py` or `python server\weak_server.py` to run another mode. The ports are distinct, so all three server processes can run simultaneously for comparison. In Godot, select the `NetworkManager` node and choose the matching `server_mode` in the Inspector: `server TCP`, `weak_server WebSocket`, or `secure_server WebSocket`.

The secure server calculates hits from server-stored player positions and the validated shot direction. This prototype does not yet include map-wall geometry in the server hit check, so wall obstruction can differ from the client display. The weak server also retains its older `move`, `shoot`, `reload`, and `state` message aliases for the attack simulator.
