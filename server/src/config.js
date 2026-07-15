import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = path.resolve(here, '..');

// Minimal .env reader — avoids pulling in dotenv for six variables.
const envFile = path.join(ROOT, '.env');
if (fs.existsSync(envFile)) {
  for (const raw of fs.readFileSync(envFile, 'utf8').split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const k = line.slice(0, eq).trim();
    let v = line.slice(eq + 1).trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    if (process.env[k] === undefined) process.env[k] = v;
  }
}

const need = (k) => {
  const v = process.env[k];
  if (!v && process.env.NODE_ENV === 'production') {
    console.error(`[sortie] Missing required env var: ${k}`);
    process.exit(1);
  }
  return v || '';
};

export const config = {
  port: parseInt(process.env.PORT || '4020', 10),
  prod: process.env.NODE_ENV === 'production',
  publicUrl: process.env.PUBLIC_URL || 'http://localhost:4010',
  sessionSecret: process.env.SESSION_SECRET || crypto.randomBytes(32).toString('hex'),
  google: {
    clientId: need('GOOGLE_CLIENT_ID'),
    clientSecret: need('GOOGLE_CLIENT_SECRET'),
    get redirectUri() {
      return process.env.GOOGLE_REDIRECT_URI || `${config.publicUrl}/auth/google/callback`;
    },
  },
  // Set DEV_NO_AUTH=1 locally to skip Google entirely while you iterate.
  devNoAuth: process.env.DEV_NO_AUTH === '1',
  // Seconds a player waits for humans before bots fill the room.
  botFillAfter: parseFloat(process.env.BOT_FILL_AFTER || '12'),
};
