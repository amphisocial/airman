import express from 'express';
import crypto from 'node:crypto';
import { config } from './config.js';

const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';

// The id_token comes straight from Google's token endpoint over TLS, so per
// Google's own guidance we can read the payload without re-verifying the JWT
// signature. (If you ever accept an id_token from the browser instead, verify it.)
function decodeIdToken(idToken) {
  const payload = idToken.split('.')[1];
  return JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
}

export const router = express.Router();

router.get('/google', (req, res) => {
  if (config.devNoAuth) {
    req.session.user = { sub: 'dev', name: 'Dev Player', email: 'dev@localhost' };
    return res.redirect('/game');
  }
  const state = crypto.randomBytes(16).toString('hex');
  req.session.oauthState = state;
  req.session.next = typeof req.query.next === 'string' ? req.query.next : '/game';

  const url = new URL(AUTH_URL);
  url.searchParams.set('client_id', config.google.clientId);
  url.searchParams.set('redirect_uri', config.google.redirectUri);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('scope', 'openid email profile');
  url.searchParams.set('state', state);
  url.searchParams.set('prompt', 'select_account');
  res.redirect(url.toString());
});

router.get('/google/callback', async (req, res) => {
  try {
    const { code, state } = req.query;
    if (!code || !state || state !== req.session.oauthState) {
      return res.status(400).send('Sign-in failed: the request could not be verified. Head back and try again.');
    }
    delete req.session.oauthState;

    const body = new URLSearchParams({
      code: String(code),
      client_id: config.google.clientId,
      client_secret: config.google.clientSecret,
      redirect_uri: config.google.redirectUri,
      grant_type: 'authorization_code',
    });
    const r = await fetch(TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
    });
    if (!r.ok) {
      console.error('[airman] token exchange failed', r.status, await r.text());
      return res.status(502).send('Google rejected the sign-in. Try again in a moment.');
    }
    const tok = await r.json();
    const claims = decodeIdToken(tok.id_token);

    req.session.user = {
      sub: claims.sub,
      name: claims.given_name || claims.name || 'Player',
      email: claims.email,
    };
    const next = req.session.next || '/game';
    delete req.session.next;
    req.session.save(() => res.redirect(next));
  } catch (e) {
    console.error('[airman] oauth error', e);
    res.status(500).send('Sign-in hit an unexpected error. Try again.');
  }
});

router.get('/logout', (req, res) => {
  req.session.destroy(() => res.redirect('/'));
});

export function requireAuth(req, res, next) {
  if (req.session?.user) return next();
  // DEV_NO_AUTH already lets the WebSocket through without a session; gating the
  // page but not the socket would just be confusing.
  if (config.devNoAuth) {
    req.session.user = { sub: 'dev', name: 'Dev Player', email: 'dev@localhost' };
    return next();
  }
  res.redirect('/?next=' + encodeURIComponent(req.originalUrl));
}
