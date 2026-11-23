# FairFPS servers

Both game servers use WebSocket and share the same game rules and JSON messages. Their validation policies differ:

| Server | Transport | Address | Validation |
| --- | --- | --- | --- |
| `weak_server.py` | WebSocket | `ws://127.0.0.1:7779/ws` | Deliberately accepts altered movement, ammo, damage, target, reload, and pickup values |
| `secure_server.py` | WebSocket | `ws://127.0.0.1:7778/ws` | Checks movement, ammo, fire interval, reload, and pickup requests; rejects tampering and logs `[CHEAT DETECTED]` |

Both use 100 HP, 25 damage per hit, 12 rounds, 0.2-second fire interval, 1.5-second reload, 3-second respawn, a 3-minute match, and the same item spawn rules. Valid play should behave the same on both.

The secure server allows a 100 px coin pickup distance to match Godot's pickup collision area and movement update delay. A distance rejection is logged as `[PICKUP REJECTED]` and does not count toward the three-strike disconnect rule.

## Install and start

Run from the project root:

```powershell
cd C:\fair-fps\fair-fps
python -m pip install -r server\requirements.txt
python server\secure_server.py
```

Replace the last line with `python server\weak_server.py` to run the vulnerable mode. In Godot, select the `NetworkManager` node and choose `weak_server WebSocket` or `secure_server WebSocket` in the Inspector.

Both Python servers bind to `0.0.0.0` by default, so they accept local and LAN connections. To connect from another PC on the same network, uncomment the `host = "192.168.0.10"` line in `script/network_manager.gd` and replace the sample with the server PC's LAN IPv4 address. Localhost remains the default. Allow inbound connections to port 7778 (secure) or 7779 (weak) in the server PC's firewall. Internet access from outside the LAN also requires router port forwarding.

The secure server calculates hits from server-stored player positions and the validated shot direction. This prototype does not yet include map-wall geometry in the server hit check, so wall obstruction can differ from the client display. The weak server also retains its older `move`, `shoot`, `reload`, and `state` message aliases for the attack simulator.
