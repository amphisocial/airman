import { Match } from './game/match.js';
import { botThink } from './game/bot.js';
import { packTerrain } from './game/terrain.js';
import {
  COLORS, MATCH_END_LINGER, MAX_PLAYERS, HMAP_N, WORLD, MAX_H,
  MATCH_TIME, AMMO, PLAY_RADIUS, SPEED_MODES, DEFAULT_MODE,
} from './game/constants.js';

let nextRoomId = 1;

export class Room {
  constructor(seats, onClosed, modeName = DEFAULT_MODE) {
    this.id = 'm' + nextRoomId++;
    this.onClosed = onClosed;
    this.closed = false;
    this.phase = 'live'; // live | done
    this.timer = 0;

    this.seats = seats.map((s, i) => ({
      pid: i,
      slot: i,
      name: s.name,
      bot: s.bot,
      conn: s.conn || null,
      color: COLORS[i],
    }));
    for (const s of this.seats) {
      if (s.conn) { s.conn.room = this; s.conn.pid = s.pid; }
    }

    this.mode = SPEED_MODES[modeName] ? modeName : DEFAULT_MODE;
    this.match = new Match(
      this.seats.map((s) => ({ pid: s.pid, name: s.name, bot: s.bot, slot: s.slot })),
      (Math.random() * 0xffffffff) >>> 0,
      this.mode,
    );

    const roster = this.seats.map((s) => ({ pid: s.pid, name: s.name, color: s.color, bot: s.bot }));
    // The heightmap goes over the wire once, so the client renders and predicts
    // against the exact bytes the server collides against.
    const terrain = packTerrain(this.match.hmap);
    for (const s of this.seats) {
      this.sendTo(s.pid, {
        t: 'match',
        room: this.id,
        you: s.pid,
        players: roster,
        terrain,
        hmapN: HMAP_N,
        world: WORLD,
        maxH: MAX_H,
        matchTime: MATCH_TIME,
        ammo: AMMO,
        playRadius: PLAY_RADIUS,
        speedScale: this.match.k,
        speedMode: this.mode,
      });
    }
  }

  seatOf(pid) { return this.seats.find((s) => s.pid === pid); }

  send(msg) {
    const text = JSON.stringify(msg);
    for (const s of this.seats) {
      if (s.conn && s.conn.socket.readyState === 1) s.conn.socket.send(text);
    }
  }

  sendTo(pid, msg) {
    const s = this.seatOf(pid);
    if (s?.conn && s.conn.socket.readyState === 1) s.conn.socket.send(JSON.stringify(msg));
  }

  onInput(pid, msg) {
    const p = this.match.players.find((q) => q.pid === pid);
    if (!p || p.bot || !p.alive) return;
    const c = (v) => Math.max(-1, Math.min(1, Number(v) || 0));
    p.in.pitch = c(msg.p);
    p.in.roll = c(msg.r);
    p.in.yaw = c(msg.y);
    p.in.throttle = Math.max(0, Math.min(1, Number(msg.th) || 0));
    p.in.fire = !!msg.f;
  }

  // If someone bails, a bot takes the stick. The other pilot still gets a fight.
  onLeave(pid) {
    const s = this.seatOf(pid);
    if (!s) return;
    s.conn = null;
    s.bot = true;
    const p = this.match.players.find((q) => q.pid === pid);
    if (p) { p.bot = true; p.botT = 0; }
    this.send({ t: 'left', pid });
    if (!this.seats.some((x) => x.conn)) this.close();
  }

  tick(dt) {
    if (this.closed) return;

    if (this.phase === 'live') {
      for (const p of this.match.players) {
        if (p.bot && p.alive) botThink(this.match, p, dt);
      }
      this.match.step(dt);
      this.send(this.match.snapshot());

      if (this.match.over) {
        this.phase = 'done';
        this.timer = MATCH_END_LINGER;
        this.send({
          t: 'matchEnd',
          winner: this.match.winner,
          outcome: this.match.outcome, // 'saved' | 'fell'
          cause: this.match.players.map((p) => [p.pid, p.cause]),
        });
      }
      return;
    }

    this.timer -= dt;
    if (this.timer <= 0) this.close();
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    for (const s of this.seats) {
      if (s.conn) {
        this.sendTo(s.pid, { t: 'closed' });
        s.conn.room = null;
        s.conn.pid = null;
      }
    }
    this.onClosed(this);
  }
}

export const ROOM_CAP = MAX_PLAYERS;
