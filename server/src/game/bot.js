import {
  PLAY_RADIUS, BULLET_SPEED, FLAK_BURST_R, AMMO, CORNER_SPEED,
} from './constants.js';
import { clamp } from './flight.js';
import {
  v3, add, sub, scale, norm, len, dot, qRotate, qConj, fwdOf, upOf, rightOf,
} from './vec.js';

// A bot pilot. It flies the same model the humans do — same stall, same
// gravity, no cheating — so beating one actually means something.
const THINK_EVERY = 0.1;
// match.js kills you above 900. Bots turn round well before that.
const SOFT_CEIL = 700;

function toLocal(q, dir) {
  return qRotate(qConj(q), dir);
}

function bankOf(q) {
  const r = rightOf(q), u = upOf(q);
  return Math.atan2(-r.y, u.y);
}

/**
 * Steer toward a world-space point, the way a pilot actually does it: roll until
 * the target sits in the plane's vertical plane ("put it above the canopy"),
 * then pull.
 *
 * The naive version — roll proportional to the target's local x — has a dead
 * spot: a target directly behind gives x=0, so the aircraft rolls not at all and
 * loops instead of turning. Using atan2(x, y) has authority all the way round.
 * Roll is also a *rate*, not an angle, so wings-level is a separate correction;
 * without it a bot holding roll just barrel-rolls forever.
 */
function steerTo(p, aim) {
  const dir = norm(sub(aim, p.pos));
  const lt = toLocal(p.q, dir);

  const pitchErr = Math.atan2(Math.hypot(lt.x, lt.y), -lt.z); // 0 = dead ahead, PI = dead astern
  const rollErr = Math.atan2(lt.x, lt.y);                     // 0 = target above the canopy

  if (pitchErr < 0.18) {
    // Nose is on it — stop turning and level the wings, or the banked lift
    // vector will quietly drag the nose back off target.
    p.in.roll = clamp(-bankOf(p.q) * 1.5, -1, 1);
    p.in.pitch = clamp(-lt.y * -2.0, -1, 1);
  } else {
    p.in.roll = clamp(rollErr * 1.25, -1, 1);
    p.in.pitch = clamp(pitchErr * 1.7, -1, 1);
  }
  p.in.yaw = clamp(lt.x * 0.35, -1, 1);
}

/** Wings level, nose up — but roll upright first, or "up" flies you into a hill. */
function recover(p) {
  const bank = bankOf(p.q);
  p.in.roll = clamp(-bank * 1.9, -1, 1);
  p.in.yaw = 0;
  p.in.pitch = Math.abs(bank) > 0.7 ? 0.15 : 1;
  p.in.throttle = 1;
  p.in.fire = false;
}

export function botThink(m, p, dt) {
  p.botT -= dt;
  if (p.botT > 0) return;
  p.botT = THINK_EVERY;

  const f = fwdOf(p.q);
  const ground = m.groundAt(p.pos.x, p.pos.z);

  // 1. Don't fly into the island. Everything else is negotiable.
  const look = add(p.pos, scale(f, p.speed * 2.6));
  const groundAhead = m.groundAt(look.x, look.z);
  if (p.pos.y < ground + 70 || look.y < groundAhead + 90 || p.pos.y < 60) {
    recover(p);
    return;
  }

  // 2. Flak about to go off nearby? Break away from it.
  for (const s of m.shells) {
    if (s.fuse > 1.5) continue;
    const burst = add(s.pos, scale(s.vel, s.fuse));
    if (len(sub(burst, p.pos)) < FLAK_BURST_R * 1.9) {
      const away = norm(sub(p.pos, burst));
      steerTo(p, add(p.pos, scale(add(away, v3(0, 0.35, 0)), 400)));
      p.in.throttle = 1;
      p.in.fire = false;
      return;
    }
  }

  // 3. Too high — get back down before the ceiling starts counting.
  if (p.pos.y > SOFT_CEIL + 60) {
    steerTo(p, add(p.pos, scale(v3(f.x, -0.8, f.z), 500)));
    p.in.throttle = 0.6;
    p.in.fire = false;
    return;
  }

  // 4. Drifting off the map — come back before the boundary starts biting.
  const flat = Math.hypot(p.pos.x, p.pos.z);
  if (flat > PLAY_RADIUS * 0.82) {
    steerTo(p, v3(0, Math.max(260, ground + 200), 0));
    p.in.throttle = 1;
    p.in.fire = false;
    return;
  }

  // 5. Out of energy — unload, get the nose down, rebuild speed. Pulling harder
  //    when you're already slow just digs the hole deeper.
  if (p.speed < CORNER_SPEED * m.k) {
    steerTo(p, add(p.pos, scale(v3(f.x, -0.55, f.z), 420)));
    p.in.throttle = 1;
    p.in.fire = false;
    return;
  }

  // 6. Hunt.
  const foe = m.players.find((q) => q.pid !== p.pid && q.alive);
  if (!foe) { recover(p); return; }

  const toFoe = sub(foe.pos, p.pos);
  const range = len(toFoe);

  // Lead the shot: aim where they'll be, not where they are.
  const tof = range / (BULLET_SPEED * m.k + p.speed);
  let aim = add(foe.pos, scale(fwdOf(foe.q), foe.speed * tof));

  // Bots re-roll a small aim error every so often. Without it they're perfect
  // deflection shooters and no human ever wins.
  if (p.botErrT === undefined || p.botErrT <= 0) {
    p.botErrT = 0.55;
    const e = range * (p.botSkill === undefined ? 0.035 : p.botSkill);
    p.botErr = v3((Math.random() * 2 - 1) * e, (Math.random() * 2 - 1) * e, (Math.random() * 2 - 1) * e);
  }
  p.botErrT -= THINK_EVERY;
  aim = add(aim, p.botErr || v3());

  // Keep the fight in the box. The floor stops them chasing each other into a
  // hill; the roof stops the climb war — two bots each trying to get above the
  // other will spiral up until the ceiling kills them both.
  const aimGround = m.groundAt(aim.x, aim.z);
  aim.y = clamp(aim.y, aimGround + 110, SOFT_CEIL);

  // Refuse the head-on. Trading bursts nose-to-nose is a mutual kill, which
  // reads as a coin flip rather than a dogfight.
  const foeNoseOnUs = dot(fwdOf(foe.q), norm(sub(p.pos, foe.pos)));
  if (foeNoseOnUs > 0.995 && range < 320 && dot(f, norm(toFoe)) > 0.97) {
    steerTo(p, add(p.pos, scale(v3(-f.z, 0.5, f.x), 400)));
    p.in.throttle = 1;
    p.in.fire = false;
    return;
  }

  steerTo(p, aim);

  // Don't overrun them; back off the throttle when you're close aboard.
  // Sit near corner speed in a turning fight; firewall it when reaching.
  p.in.throttle = range > 420 ? 1 : p.speed > CORNER_SPEED * m.k * 1.15 ? 0.55 : 0.9;

  // Fire only when the rounds would actually arrive somewhere useful. A fixed
  // angular cone is the wrong test: five degrees is a hit at 100m and a clean
  // miss at 700m. Convert the angle into a miss distance at this range instead.
  const aimDir = norm(sub(aim, p.pos));
  const off = Math.acos(clamp(dot(f, aimDir), -1, 1));
  const missDist = off * range;
  p.in.fire = missDist < 13 * (p.botNerve || 1) && range < 720 * m.k && p.ammo > 0;
}
