import http from 'node:http';
import path from 'node:path';
import fs from 'node:fs';
import express from 'express';
import session from 'express-session';
import { config, ROOT } from './config.js';
import { FileStore } from './session-store.js';
import { router as authRouter, requireAuth } from './auth.js';
import { Lobby } from './lobby.js';
import { attachWs } from './net.js';

const app = express();
app.disable('x-powered-by');
app.set('trust proxy', 1); // nginx terminates TLS for us

const sessionParser = session({
  name: 'airman.sid',
  store: new FileStore(path.join(ROOT, '.sessions.json')),
  secret: config.sessionSecret,
  resave: false,
  saveUninitialized: false,
  rolling: true,
  cookie: {
    httpOnly: true,
    sameSite: 'lax',
    secure: config.prod,
    maxAge: 1000 * 60 * 60 * 24 * 14,
  },
});
app.use(sessionParser);

const lobby = new Lobby();

app.use('/auth', authRouter);

app.get('/api/me', (req, res) => {
  if (!req.session?.user) return res.status(401).json({ error: 'signed out' });
  res.json({ name: req.session.user.name });
});

app.get('/healthz', (req, res) => res.json({ ok: true, ...lobby.stats() }));

const PUB = path.join(ROOT, 'public');
const GAME_DIR = path.join(PUB, 'game');

// The Godot export lives behind sign-in. Everything else is public.
app.get('/game', requireAuth, (req, res, next) => {
  if (!fs.existsSync(path.join(GAME_DIR, 'index.html'))) {
    return res.status(503).sendFile(path.join(PUB, 'not-exported.html'));
  }
  next();
});
app.use('/game', requireAuth, express.static(GAME_DIR, {
  etag: true,
  lastModified: true,
  setHeaders(res) {
    // Godot's web export writes FIXED filenames — index.wasm, index.pck,
    // index.js — with no content hash. Far-future caching therefore pins every
    // player to the build they first loaded, and no amount of redeploying can
    // dislodge it. "no-cache" means revalidate, not "don't store": the browser
    // still keeps the bytes and a 304 costs nothing.
    res.setHeader('Cache-Control', 'no-cache');
  },
}));

app.use(express.static(PUB, { index: 'index.html', extensions: ['html'] }));

app.use((req, res) => res.status(404).sendFile(path.join(PUB, 'index.html')));

const server = http.createServer(app);
attachWs(server, sessionParser, lobby);

server.listen(config.port, '127.0.0.1', () => {
  console.log(`[airman] listening on 127.0.0.1:${config.port} (${config.prod ? 'production' : 'dev'})`);
  if (config.devNoAuth) console.log('[airman] DEV_NO_AUTH is on — Google sign-in is bypassed.');
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    console.log(`[airman] ${sig} — shutting down`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 3000).unref();
  });
}
