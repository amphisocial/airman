import fs from 'node:fs';
import session from 'express-session';

// express-session's built-in MemoryStore never prunes and forgets everyone on
// restart — so every `pm2 restart fusebox` would sign the whole player base out.
// This keeps sessions in memory (fast) and mirrors them to one small JSON file.
export class FileStore extends session.Store {
  constructor(file, flushMs = 5000) {
    super();
    this.file = file;
    this.tmp = file + '.tmp';
    this.sessions = new Map();
    this.dirty = false;
    this.#load();

    this.flushTimer = setInterval(() => this.#flush(), flushMs);
    this.flushTimer.unref?.();
    this.pruneTimer = setInterval(() => this.#prune(), 60 * 60 * 1000);
    this.pruneTimer.unref?.();
    for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => this.#flush());
  }

  #load() {
    try {
      const raw = JSON.parse(fs.readFileSync(this.file, 'utf8'));
      for (const [k, v] of Object.entries(raw)) this.sessions.set(k, v);
      this.#prune();
      console.log(`[sortie] restored ${this.sessions.size} session(s)`);
    } catch {
      // No file yet, or it's corrupt. Either way: start clean, don't crash.
    }
  }

  #flush() {
    if (!this.dirty) return;
    this.dirty = false;
    try {
      fs.writeFileSync(this.tmp, JSON.stringify(Object.fromEntries(this.sessions)));
      fs.renameSync(this.tmp, this.file); // atomic: never leaves a half-written file
    } catch (e) {
      console.error('[sortie] could not save sessions:', e.message);
    }
  }

  #prune() {
    const now = Date.now();
    let dropped = 0;
    for (const [sid, sess] of this.sessions) {
      const exp = sess?.cookie?.expires ? Date.parse(sess.cookie.expires) : 0;
      if (exp && exp < now) { this.sessions.delete(sid); dropped++; }
    }
    if (dropped) this.dirty = true;
  }

  get(sid, cb) {
    const s = this.sessions.get(sid);
    process.nextTick(() => cb(null, s ? JSON.parse(JSON.stringify(s)) : null));
  }

  set(sid, sess, cb) {
    this.sessions.set(sid, JSON.parse(JSON.stringify(sess)));
    this.dirty = true;
    process.nextTick(() => cb(null));
  }

  destroy(sid, cb) {
    this.sessions.delete(sid);
    this.dirty = true;
    process.nextTick(() => cb(null));
  }

  touch(sid, sess, cb) {
    const s = this.sessions.get(sid);
    if (s) { s.cookie = JSON.parse(JSON.stringify(sess.cookie)); this.dirty = true; }
    process.nextTick(() => cb(null));
  }

  length(cb) { cb(null, this.sessions.size); }
  clear(cb) { this.sessions.clear(); this.dirty = true; cb(null); }
}
