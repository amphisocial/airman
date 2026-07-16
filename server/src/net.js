import { WebSocketServer } from 'ws';
import { config } from './config.js';

const MAX_MSG_PER_SEC = 90; // inputs run ~30Hz; anything past this is abuse

class Conn {
  constructor(socket, user) {
    this.socket = socket;
    this.user = user;
    this.room = null;
    this.pid = null;
    this.budget = MAX_MSG_PER_SEC;
    this.alive = true;
  }
  send(msg) {
    if (this.socket.readyState === 1) this.socket.send(JSON.stringify(msg));
  }
}

export function attachWs(server, sessionParser, lobby) {
  const wss = new WebSocketServer({ noServer: true, maxPayload: 4096 });
  const conns = new Set();

  server.on('upgrade', (req, socket, head) => {
    if (!req.url?.startsWith('/ws')) { socket.destroy(); return; }

    sessionParser(req, {}, () => {
      const user = req.session?.user
        || (config.devNoAuth ? { sub: 'dev', name: 'Dev Player' } : null);
      if (!user) {
        console.warn('[airman] ws rejected: no session on the upgrade request');
        socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
        socket.destroy();
        return;
      }
      wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req, user));
    });
  });

  wss.on('connection', (ws, req, user) => {
    const conn = new Conn(ws, user);
    conns.add(conn);
    conn.send({ t: 'hello', name: user.name });
    console.log(`[airman] ws open: ${user.name} (${conns.size} connected)`);

    ws.on('message', (data) => {
      if (conn.budget-- <= 0) return;
      let msg;
      try { msg = JSON.parse(data.toString()); } catch { return; }
      switch (msg.t) {
        case 'queue':
          conn.speedMode = typeof msg.speed === 'string' ? msg.speed : undefined;
          console.log(`[airman] queue request from ${conn.user.name} (speed: ${conn.speedMode || 'default'})`);
          if (!conn.room) lobby.enqueue(conn);
          break;
        case 'input':
          if (conn.room && conn.pid !== null) conn.room.onInput(conn.pid, msg);
          break;
        case 'leave':
          if (conn.room) conn.room.onLeave(conn.pid);
          else lobby.dequeue(conn);
          break;
        case 'ping':
          conn.send({ t: 'pong', ts: msg.ts });
          break;
      }
    });

    ws.on('pong', () => { conn.alive = true; });
    ws.on('error', () => {});
    ws.on('close', () => {
      console.log(`[airman] ws close: ${conn.user.name}`);
      conns.delete(conn);
      if (conn.room) conn.room.onLeave(conn.pid);
      lobby.dequeue(conn);
    });
  });

  const refill = setInterval(() => {
    for (const c of conns) c.budget = MAX_MSG_PER_SEC;
  }, 1000);
  refill.unref?.();

  // Drop half-open sockets so ghost rooms don't linger.
  const heartbeat = setInterval(() => {
    for (const c of conns) {
      if (!c.alive) { c.socket.terminate(); continue; }
      c.alive = false;
      try { c.socket.ping(); } catch { /* socket already gone */ }
    }
  }, 30000);
  heartbeat.unref?.();

  return { wss, conns };
}
