# Airman

Two planes, one island, five hundred rounds. The castle is still standing only
if the plane that comes back is yours.

**Mission I — Save the Castle** is the first one. The name is the container:
Mission II is Save the City, and so on. A mission is a level.

- Live at **https://airman.athenabot.ai**
- Deployment: **[DEPLOY.md](DEPLOY.md)**

---

## The game

Third person, camera behind your aircraft. Two planes dogfight over an island
until one of them is down. Whoever's still flying saved the castle.

- **500 rounds, no resupply.** About forty seconds of trigger. Make them count.
- **The castle guns fire at anything with wings.** They can't tell you apart in
  a furball, so flak is a hazard for both of you — it chips you and forces you
  off an attack rather than killing outright.
- **Nobody wins → the castle falls.** A five minute clock. That's a real
  outcome, not a draw.
- **Energy matters.** Pulling G costs speed, and turn rate peaks at a corner
  speed of about 115. Dig into a max-rate turn and you'll bleed down to where
  you can't turn at all.

Controls: `W`/`S` nose down/up, `A`/`D` roll, `Q`/`E` rudder, `Shift`/`Ctrl`
throttle, `Space` guns.

---

## Shape

Same architecture as Fusebox — the server owns the truth.

```
client/    Godot 4, exports to Web (GL Compatibility, single-threaded)
server/    Node: Express + express-session + ws. Authoritative flight sim.
nginx/     Reverse proxy for airman.athenabot.ai → 127.0.0.1:4020
```

The server simulates every aircraft at 30Hz and is the only authority on hits,
crashes and flak. The client predicts *its own* aircraft with an identical copy
of the flight model so the stick feels connected, and eases back toward the
server whenever the two disagree.

**The catch:** `server/src/game/flight.js` and the `FLIGHT` block in
`client/autoload/GameState.gd` are the same model written twice. If they drift
apart, aircraft rubber-band. Change both together.

The island is a heightmap generated server-side, quantized to bytes, and sent
over the wire once at match start (~22KB). The client renders and predicts
against the exact bytes the server collides against — so nobody can clip a hill
the other side thinks is solid. Reimplementing the noise in GDScript would have
risked float drift for no benefit.

Bots fill the second seat after a few seconds, fly the same model with no
cheating, and take over if a player leaves.

Nothing is imported: the terrain, the castle, the aircraft and every sound are
generated in code. There isn't a single binary asset in the repo.

---

## Running it locally

```bash
cd server
npm install
cp .env.example .env      # set SESSION_SECRET; add DEV_NO_AUTH=1 to skip Google
npm run dev
```

Then open `client/` in Godot 4 and hit play. In the editor the client talks to
`127.0.0.1:4020` (see `DEV_HOST` in `autoload/Net.gd`); in the browser it uses
the page's own origin, so the `airman.sid` cookie authenticates the socket.

`/healthz` reports rooms, queued players and live players.

---

## Balance

The flight model went through a lot of iteration, and the numbers aren't
arbitrary — most of them are the answer to a specific failure:

- **Induced drag + tapered thrust.** Without a cost for pulling G, a flat
  max-rate turn is free, and two evenly matched pilots orbit each other until
  the clock runs out. 40 of 40 test sorties timed out before this existed.
- **Corner speed.** Without it, speed buys you nothing and there's no reason to
  manage energy.
- **`BULLET_DMG = 26`.** Swept across the range. Below ~18, evenly matched
  pilots never finish each other off. This is about four hits — roughly two
  seconds of someone tracking you.
- **Offset merge spawn.** Nose-to-nose decided matches in five seconds; purely
  tangential meant they orbited 1800 units apart and never met.

Current bot-vs-bot behaviour over 60 sorties: 54 decisive, 6 run the clock out,
median 127s, winner split evenly between seats.

To retune, `server/src/game/constants.js` is the only file you need — but if you
touch anything in the `FLIGHT` block, mirror it into `GameState.gd`.
