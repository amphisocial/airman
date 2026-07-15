import {
  DT, MAX_HP, AMMO, FIRE_HZ, BULLET_SPEED, BULLET_LIFE, BULLET_DMG, GUN_SPREAD,
  FLAK_RANGE, FLAK_SPEED, FLAK_BURST_R, FLAK_DMG, FLAK_FIRST, FLAK_GAP_START,
  FLAK_GAP_END, FLAK_RAMP, FLAK_LEAD_ERR, TOWERS,
  MATCH_TIME, SPAWN_DIST, SPAWN_ALT, PLAY_RADIUS, OOB_GRACE, OOB_DPS,
  PLANE_R, GROUND_CLEAR, SEA_LEVEL, MIN_SPEED, MAX_SPEED,
} from './constants.js';
import { makeTerrain, heightAt } from './terrain.js';
import { stepFlight, clamp } from './flight.js';
import {
  v3, add, sub, scale, norm, len, dot, qId, qLook, fwdOf, segHitsSphere,
} from './vec.js';

const CEILING = 900;
let nextId = 1;

export class Match {
  constructor(players, seed) {
    this.players = players; // [{pid, name, bot, slot}]
    this.seed = seed >>> 0;
    this.rand = mulberry(this.seed ^ 0x51ed270b);
    this.hmap = makeTerrain(this.seed);

    this.tick = 0;
    this.elapsed = 0;
    this.over = false;
    this.winner = null;
    this.outcome = null; // 'saved' | 'fell'

    this.bullets = [];
    this.shells = [];
    this.newBullets = [];
    this.deadBullets = [];
    this.newShells = [];
    this.hits = [];
    this.deaths = [];

    this.flakAt = FLAK_FIRST;

    // Opposite ends of a random axis, noses pointed at the castle. They merge
    // over the keep in about eight seconds, just as the guns wake up.
    const axis = this.rand() * Math.PI * 2;
    for (const p of this.players) {
      const a = axis + (p.slot === 0 ? 0 : Math.PI);
      p.pos = v3(Math.cos(a) * SPAWN_DIST, SPAWN_ALT, Math.sin(a) * SPAWN_DIST);
      // An offset merge. Nose-to-nose decided the match in five seconds; purely
      // tangential meant they orbited 1800 apart and never met. Forty degrees off
      // the line, both breaking the same way, gives a clean pass into a turning fight.
      const toC = a + Math.PI + 0.7;
      p.q = qLook(v3(Math.cos(toC), -0.08, Math.sin(toC)));
      p.speed = (MIN_SPEED + MAX_SPEED) * 0.5;
      p.hp = MAX_HP;
      p.ammo = AMMO;
      p.alive = true;
      p.cause = null;
      p.fireCd = 0;
      p.oobT = 0;
      p.in = { pitch: 0, roll: 0, yaw: 0, throttle: 0.75, fire: false };
      p.botT = 0;
      // Two bots with identical judgement make identical mistakes and lock into
      // a scissors nobody can win. Give each pilot a slightly different hand.
      p.botSkill = 0.030 + this.rand() * 0.025;
      p.botNerve = 0.85 + this.rand() * 0.3;
    }
  }

  groundAt(x, z) { return heightAt(this.hmap, x, z); }

  alivePlayers() { return this.players.filter((p) => p.alive); }

  kill(p, cause) {
    if (!p.alive) return;
    p.alive = false;
    p.hp = 0;
    p.cause = cause;
    this.deaths.push([p.pid, cause, r1(p.pos.x), r1(p.pos.y), r1(p.pos.z)]);
  }

  damage(p, amount, cause) {
    if (!p.alive) return;
    p.hp -= amount;
    if (p.hp <= 0) this.kill(p, cause);
  }

  // --- guns ----------------------------------------------------------------

  stepGuns(p, dt) {
    p.fireCd -= dt;
    if (!p.in.fire || p.ammo <= 0 || p.fireCd > 0) return;
    p.fireCd = 1 / FIRE_HZ;
    p.ammo--;

    const f = fwdOf(p.q);
    const jitter = norm(v3(
      f.x + (this.rand() - 0.5) * GUN_SPREAD * 2,
      f.y + (this.rand() - 0.5) * GUN_SPREAD * 2,
      f.z + (this.rand() - 0.5) * GUN_SPREAD * 2,
    ));
    const b = {
      id: nextId++,
      owner: p.pid,
      pos: add(p.pos, scale(f, 11)),
      vel: scale(jitter, BULLET_SPEED + p.speed),
      ttl: BULLET_LIFE,
    };
    this.bullets.push(b);
    this.newBullets.push([b.id, r1(b.pos.x), r1(b.pos.y), r1(b.pos.z),
      r1(b.vel.x), r1(b.vel.y), r1(b.vel.z), b.owner]);
  }

  stepBullets(dt) {
    // Damage is tallied first and applied afterwards. Resolving hits as we walk
    // the array let whoever fired first (always slot 0) win every mutual kill.
    const tally = new Map();
    const keep = [];

    for (const b of this.bullets) {
      const p0 = b.pos;
      const p1 = add(b.pos, scale(b.vel, dt));
      let dead = false;

      for (const t of this.players) {
        if (!t.alive || t.pid === b.owner) continue;
        if (segHitsSphere(p0, p1, t.pos, PLANE_R)) {
          tally.set(t.pid, (tally.get(t.pid) || 0) + BULLET_DMG);
          this.hits.push([r1(p1.x), r1(p1.y), r1(p1.z)]);
          dead = true;
          break;
        }
      }

      if (!dead) {
        b.pos = p1;
        b.ttl -= dt;
        if (b.ttl <= 0) dead = true;
        else if (p1.y <= SEA_LEVEL || p1.y <= this.groundAt(p1.x, p1.z)) dead = true;
      }

      if (dead) this.deadBullets.push(b.id);
      else keep.push(b);
    }

    this.bullets = keep;
    for (const [pid, amount] of tally) {
      this.damage(this.players.find((q) => q.pid === pid), amount, 'shot');
    }
  }

  // --- castle flak ---------------------------------------------------------

  stepFlak(dt) {
    this.flakAt -= dt;
    if (this.flakAt <= 0) {
      const ramp = clamp(this.elapsed / FLAK_RAMP, 0, 1);
      this.flakAt = FLAK_GAP_START + (FLAK_GAP_END - FLAK_GAP_START) * ramp;
      this.fireFlak();
    }

    const keep = [];
    for (const s of this.shells) {
      s.pos = add(s.pos, scale(s.vel, dt));
      s.fuse -= dt;
      if (s.fuse > 0) { keep.push(s); continue; }
      // Burst. Damage falls off to nothing at the edge, so a near miss is a scare.
      for (const p of this.players) {
        if (!p.alive) continue;
        const d = len(sub(p.pos, s.pos));
        if (d < FLAK_BURST_R) this.damage(p, FLAK_DMG * (1 - d / FLAK_BURST_R), 'flak');
      }
    }
    this.shells = keep;
  }

  fireFlak() {
    const targets = this.alivePlayers().filter((p) => {
      const d = Math.hypot(p.pos.x, p.pos.z);
      return d < FLAK_RANGE;
    });
    if (!targets.length) return;

    const target = targets[Math.floor(this.rand() * targets.length)];
    const tower = TOWERS[Math.floor(this.rand() * TOWERS.length)];
    const from = v3(tower.x, tower.y, tower.z);

    // Lead the target, then fumble the solution a bit. A gun that never misses
    // isn't a hazard, it's a wall.
    const flat = len(sub(target.pos, from));
    const t = flat / FLAK_SPEED;
    const vel = scale(fwdOf(target.q), target.speed);
    const err = 1 + (this.rand() * 2 - 1) * FLAK_LEAD_ERR;
    const aim = add(target.pos, scale(vel, t * err));
    aim.x += (this.rand() * 2 - 1) * 26;
    aim.y += (this.rand() * 2 - 1) * 26;
    aim.z += (this.rand() * 2 - 1) * 26;

    const dir = norm(sub(aim, from));
    const dist = len(sub(aim, from));
    const s = {
      id: nextId++,
      pos: from,
      vel: scale(dir, FLAK_SPEED),
      fuse: dist / FLAK_SPEED,
    };
    this.shells.push(s);
    this.newShells.push([s.id, r1(from.x), r1(from.y), r1(from.z),
      r1(s.vel.x), r1(s.vel.y), r1(s.vel.z), r2(s.fuse)]);
  }

  // --- boundary ------------------------------------------------------------

  stepBounds(p, dt) {
    const flat = Math.hypot(p.pos.x, p.pos.z);
    const out = flat > PLAY_RADIUS || p.pos.y > CEILING;
    if (out) {
      p.oobT += dt;
      if (p.oobT > OOB_GRACE) this.damage(p, OOB_DPS * dt, 'oob');
    } else {
      p.oobT = Math.max(0, p.oobT - dt * 2);
    }
  }

  // --- main tick -----------------------------------------------------------

  step(dt) {
    if (this.over) return;
    this.tick++;
    this.elapsed += dt;
    this.newBullets = [];
    this.deadBullets = [];
    this.newShells = [];
    this.hits = [];
    this.deaths = [];

    for (const p of this.players) {
      if (!p.alive) continue;
      stepFlight(p, p.in, dt);
      this.stepGuns(p, dt);
      this.stepBounds(p, dt);

      if (p.pos.y <= SEA_LEVEL) this.kill(p, 'splash');
      else if (p.pos.y <= this.groundAt(p.pos.x, p.pos.z) + GROUND_CLEAR) this.kill(p, 'crash');
    }

    this.stepBullets(dt);
    this.stepFlak(dt);

    const alive = this.alivePlayers();
    if (alive.length <= 1) {
      this.over = true;
      this.winner = alive.length === 1 ? alive[0].pid : null;
      this.outcome = this.winner !== null ? 'saved' : 'fell';
    } else if (this.elapsed >= MATCH_TIME) {
      // Nobody got the job done. The castle doesn't care whose fault that was.
      this.over = true;
      this.winner = null;
      this.outcome = 'fell';
    }
  }

  snapshot() {
    const snap = {
      t: 's',
      k: this.tick,
      tl: r2(Math.max(0, MATCH_TIME - this.elapsed)),
      p: this.players.map((p) => [
        p.pid, r1(p.pos.x), r1(p.pos.y), r1(p.pos.z),
        r3(p.q.x), r3(p.q.y), r3(p.q.z), r3(p.q.w),
        r1(p.speed), Math.max(0, Math.round(p.hp)), p.ammo, p.alive ? 1 : 0,
        p.oobT > OOB_GRACE * 0.5 ? 1 : 0,
      ]),
    };
    if (this.newBullets.length) snap.nb = this.newBullets;
    if (this.deadBullets.length) snap.db = this.deadBullets;
    if (this.newShells.length) snap.nf = this.newShells;
    if (this.hits.length) snap.h = this.hits;
    if (this.deaths.length) snap.dd = this.deaths;
    return snap;
  }
}

const r1 = (v) => Math.round(v * 10) / 10;
const r2 = (v) => Math.round(v * 100) / 100;
const r3 = (v) => Math.round(v * 1000) / 1000;

function mulberry(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
