import { Room } from './room.js';
import { DT, TICK_HZ, MAX_PLAYERS, CALLSIGNS } from './game/constants.js';
import { config } from './config.js';

export class Lobby {
  constructor() {
    this.queue = [];
    this.rooms = new Set();
    // One loop drives every room. Simpler to reason about than a timer each.
    this.loop = setInterval(() => this.tick(), 1000 / TICK_HZ);
    this.loop.unref?.();
  }

  enqueue(conn) {
    if (conn.room || this.queue.includes(conn)) return;
    conn.queuedAt = Date.now();
    this.queue.push(conn);
    this.broadcastQueue();
    this.tryMatch();
  }

  dequeue(conn) {
    const i = this.queue.indexOf(conn);
    if (i >= 0) { this.queue.splice(i, 1); this.broadcastQueue(); }
  }

  broadcastQueue() {
    for (const c of this.queue) {
      c.send({ t: 'queued', waiting: this.queue.length, need: MAX_PLAYERS });
    }
  }

  tryMatch() {
    while (this.queue.length >= MAX_PLAYERS) {
      this.spawnRoom(this.queue.splice(0, MAX_PLAYERS));
    }
  }

  // Nobody else in the air? Scramble a bot. A sortie that never launches is
  // worse than a sortie against a machine.
  fillWithBots() {
    if (!this.queue.length) return;
    if (Date.now() - this.queue[0].queuedAt < config.botFillAfter * 1000) return;
    this.spawnRoom(this.queue.splice(0, MAX_PLAYERS));
  }

  spawnRoom(conns) {
    const seats = conns.map((c) => ({ name: c.user.name, bot: false, conn: c }));
    const humans = seats.length;
    const names = [...CALLSIGNS].sort(() => Math.random() - 0.5);
    while (seats.length < MAX_PLAYERS) {
      seats.push({ name: names.pop() || 'Bandit', bot: true, conn: null });
    }
    const room = new Room(seats, (r) => this.rooms.delete(r));
    this.rooms.add(room);
    console.log(`[airman] room ${room.id} launched: ${seats.map((s) => s.name + (s.bot ? ' (bot)' : '')).join(' vs ')}`
      + ` — ${humans} human, ${seats.length - humans} bot`);
    return room;
  }

  tick() {
    this.fillWithBots();
    for (const r of this.rooms) {
      try {
        r.tick(DT);
      } catch (e) {
        console.error('[airman] room tick failed', r.id, e);
        r.close();
      }
    }
  }

  stats() {
    return {
      rooms: this.rooms.size,
      queued: this.queue.length,
      players: [...this.rooms].reduce((n, r) => n + r.seats.filter((s) => s.conn).length, 0),
    };
  }
}
