# Deploying Airman to airman.athenabot.ai

Same shape as Fusebox, so most of this will feel familiar. The differences that
actually matter: **port 4020**, the domain, and a fresh Google OAuth client.

You need: the EC2 box, Godot 4 on your Mac, and access to the DNS for
`athenabot.ai` and the Google Cloud console.

---

## 1. Point DNS at the box

Add an A record:

| Type | Name        | Value             |
|------|-------------|-------------------|
| A    | `airman`    | *your EC2 IP*     |

Check it before going further — certbot will fail if this hasn't propagated:

```bash
dig +short airman.athenabot.ai
```

---

## 2. Create the Google OAuth client

This is a **new client**, not the Fusebox one. Reusing Fusebox's client ID will
fail at sign-in, because the redirect URI won't match.

Google Cloud Console → **APIs & Services → Credentials → Create Credentials →
OAuth client ID → Web application**.

- **Authorised JavaScript origins:** `https://airman.athenabot.ai`
- **Authorised redirect URIs:** `https://airman.athenabot.ai/auth/google/callback`

The redirect URI must match `GOOGLE_REDIRECT_URI` in `.env` character for
character — trailing slashes included.

On the **OAuth consent screen**, add the scopes `userinfo.email` and
`userinfo.profile`, then **Publish** it. Left in "Testing", only accounts you
list by hand can sign in.

---

## 3. Export the game (on your Mac)

Unzip `airman.zip`, then:

```bash
cd airman/client
```

Open that folder in Godot 4. **Import the project first and let it finish** —
if you go to the export dialog before the initial import completes, the preset
shows the wrong main scene.

Then **Editor → Manage Export Templates → Download and Install** (once per Godot
version — the Web export is greyed out without it).

Now **Project → Export → Web**. The preset is already in the repo. Confirm:

- **Export Path:** `../server/public/game/index.html`
- **Thread Support:** **OFF**

That last one matters. Thread support requires the server to send
`Cross-Origin-Opener-Policy` and `Cross-Origin-Embedder-Policy` headers; the
nginx config here doesn't send them, so a threaded build loads a blank canvas.
Single-threaded just works.

Click **Export Project** (untick "Export With Debug").

You should end up with:

```
server/public/game/index.html
server/public/game/index.wasm
server/public/game/index.pck
server/public/game/index.js
server/public/game/index.audio.worklet.js
```

Commit and push:

```bash
cd ..
git init                       # if it's not a repo yet
git add -A
git commit -m "Airman"
git remote add origin <your remote>
git push -u origin main
```

---

## 4. Pull it onto EC2

```bash
ssh <your-ec2>
sudo mkdir -p /opt/apps && sudo chown -R $(whoami) /opt/apps
cd /opt/apps
git clone <your remote> airman
cd airman/server
npm install --omit=dev
```

**`npm install` runs in `server/`, not the repo root.** The root has no
`package.json` — this is exactly what produced the `ERR_MODULE_NOT_FOUND:
express` you hit on Fusebox.

If you get `EACCES`, fix the ownership rather than reaching for sudo:

```bash
sudo chown -R $(whoami) /opt/apps/airman
npm install --omit=dev
```

`sudo npm install` leaves root-owned files in `node_modules/` and the next
non-root deploy fails.

---

## 5. Configure secrets

```bash
cd /opt/apps/airman/server
cp .env.example .env
openssl rand -hex 32      # paste into SESSION_SECRET
nano .env
```

Fill in `SESSION_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`. Leave
`PORT=4020` alone. `.env` is gitignored — keep it that way.

---

## 6. Start it under pm2

```bash
cd /opt/apps/airman
pm2 start ecosystem.config.cjs
pm2 save
pm2 logs airman --lines 30
```

Expect:

```
[airman] listening on 127.0.0.1:4020 (production)
```

Check it locally on the box before involving nginx:

```bash
curl -s localhost:4020/healthz
# {"ok":true,"rooms":0,"queued":0,"players":0}
```

If pm2 nags about `pm2 update`, ignore it. That restarts **every** app on the
box, Fusebox included.

---

## 7. nginx + certbot

```bash
sudo cp /opt/apps/airman/nginx/airman.athenabot.ai.conf \
        /etc/nginx/sites-available/airman.athenabot.ai
sudo ln -s /etc/nginx/sites-available/airman.athenabot.ai \
           /etc/nginx/sites-enabled/
sudo nginx -t
```

If `nginx -t` says **"duplicate map"**, that's expected: the Fusebox config
already defines `map $http_upgrade $connection_upgrade` and the directive is
global. Delete the `map { … }` block at the top of the Airman file and re-test.

```bash
sudo systemctl reload nginx
sudo certbot --nginx -d airman.athenabot.ai
```

Certbot rewrites the file to add TLS and the HTTP→HTTPS redirect. Don't
hand-write those blocks.

Open **https://airman.athenabot.ai** — you should get the briefing page.

---

## Redeploying

```bash
# Mac: re-export from Godot if the client changed, then
git add -A && git commit -m "..." && git push

# EC2
cd /opt/apps/airman && git pull
cd server && npm install --omit=dev   # only if package.json changed
pm2 restart airman
```

---

## When something's wrong

| Symptom | Cause |
|---|---|
| `ERR_MODULE_NOT_FOUND: express` | `npm install` didn't run in `server/`. `cd /opt/apps/airman/server && npm install --omit=dev` |
| Briefing page loads, "Fly the mission" 503s | The Godot export isn't in `server/public/game/`. Re-export and push. |
| Blank canvas, console mentions `SharedArrayBuffer` | Thread Support was ON in the export. Turn it off and re-export. |
| Stuck on "Contacting the field…" | nginx `/ws` block missing the `Upgrade`/`Connection` headers. |
| `redirect_uri_mismatch` at sign-in | `GOOGLE_REDIRECT_URI` ≠ the URI in the Google console. |
| Sign-in works, then immediately signed out | `SESSION_SECRET` unset, or `app.set('trust proxy', 1)` not reaching nginx over TLS. |
| Only you can sign in | OAuth consent screen still in "Testing". Publish it. |
| nginx won't start after adding the site | Duplicate `map` directive. See step 7. |
| Aircraft rubber-bands | The FLIGHT block in `server/src/game/constants.js` and `client/autoload/GameState.gd` have drifted apart. They must match exactly. |
