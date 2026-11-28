import unittest

from server.game_core import BULLET_DAMAGE, BULLET_SPEED, MAX_HP, GameCore


class ProjectileTests(unittest.IsolatedAsyncioTestCase):
    async def fire(self, mode, muzzle, target):
        game = GameCore(mode)
        game.players = {player_id: game._new_player(player_id) for player_id in (1, 2)}
        game.players[1].update(x=muzzle[0] - 32.28, y=muzzle[1] - 9.0)
        game.players[2].update(x=target[0], y=target[1])
        self.events = []

        async def send(message):
            self.events.append(message["type"])

        async def ignore(*args):
            pass

        game.clients = {1: (ignore, ignore), 2: (send, ignore)}
        await game.process(1, {"type": "shoot_request", "rotation": 0.0})
        self.assertEqual(self.events, ["bullet_spawn"])
        self.assertEqual(game.players[2]["hp"], MAX_HP)
        return game, next(iter(game.projectiles))

    async def test_damage_requires_bullet_contact_in_both_modes(self):
        for mode in ("secure", "weak"):
            with self.subTest(mode=mode):
                game, shot = await self.fire(mode, (100, 240), (400, 240))
                await game._advance_projectiles(shot.started + 280 / BULLET_SPEED)
                self.assertEqual(game.players[2]["hp"], MAX_HP)
                await game._advance_projectiles(shot.started + 290 / BULLET_SPEED)
                self.assertEqual(self.events, ["bullet_spawn", "hp_update"])
                self.assertEqual(game.players[2]["hp"], MAX_HP - BULLET_DAMAGE)
                self.assertFalse(game.projectiles)

    async def test_player_can_move_out_of_the_path(self):
        game, shot = await self.fire("secure", (100, 240), (400, 240))
        await game._advance_projectiles(shot.started + 0.2)
        game.players[2]["y"] = 270
        await game._advance_projectiles(shot.started + 0.5)
        self.assertEqual(game.players[2]["hp"], MAX_HP)

    async def test_wall_in_main_scene_stops_the_bullet(self):
        game, shot = await self.fire("secure", (0, 331), (200, 331))
        self.assertAlmostEqual(shot.limit, 18.65)
        await game._advance_projectiles(shot.started + 0.5)
        self.assertEqual(game.players[2]["hp"], MAX_HP)
        self.assertFalse(game.projectiles)
