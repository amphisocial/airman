import {
  MIN_SPEED, MAX_SPEED, THRUST_K, TURN_DRAG, PITCH_RATE, ROLL_RATE, YAW_RATE,
  TURN_COEF, CLIMB_DRAG, STALL_SPEED, CORNER_SPEED,
} from './constants.js';
import { v3, add, scale, norm, qMul, qNorm, qAxis, qAxis as _qa, fwdOf, upOf, rightOf, qLook } from './vec.js';

export const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
const moveToward = (v, t, d) => (Math.abs(t - v) <= d ? t : v + Math.sign(t - v) * d);

const WORLD_UP = v3(0, 1, 0);
const LOCAL_FWD = v3(0, 0, -1);
const LOCAL_RIGHT = v3(1, 0, 0);
const LOCAL_UP = v3(0, 1, 0);

/**
 * One step of the flight model. Arcade, not a simulator: speed rides along the
 * nose, banking drags you round, and climbing costs you energy. That's enough
 * to make a dogfight feel like a dogfight without teaching anyone about lift.
 *
 * PORTED TO client/autoload/GameState.gd — keep the two in step.
 */
export function stepFlight(p, input, dt, k = 1) {
  const pitch = clamp(input.pitch || 0, -1, 1);
  const roll = clamp(input.roll || 0, -1, 1);
  const yaw = clamp(input.yaw || 0, -1, 1);
  const throttle = clamp(input.throttle === undefined ? 0.7 : input.throttle, 0, 1);

  // Controls go soggy as you bleed off speed. Stall and you're a passenger.
  // Every speed threshold scales; every angular rate does not.
  const minS = MIN_SPEED * k;
  const maxS = MAX_SPEED * k;
  const stallS = STALL_SPEED * k;
  const cornerS = CORNER_SPEED * k;

  const auth = clamp((p.speed - minS * 0.55) / (stallS - minS * 0.55), 0.22, 1);

  // Corner speed. Turn rate peaks in the middle of the envelope: too slow and
  // the wing can't generate the lift, too fast and you can't pull the G. Without
  // this, speed buys you nothing and every fight stalemates into a flat orbit.
  const rate = p.speed <= cornerS
    ? clamp(p.speed / cornerS, 0.3, 1)
    : clamp(cornerS / p.speed, 0.55, 1);

  let q = p.q;
  q = qMul(q, qAxis(LOCAL_FWD, roll * ROLL_RATE * dt * auth));
  q = qMul(q, qAxis(LOCAL_RIGHT, pitch * PITCH_RATE * dt * auth * rate));
  q = qMul(q, qAxis(LOCAL_UP, -yaw * YAW_RATE * dt * auth));
  q = qNorm(q);

  // A banked wing pulls the nose around — this is what makes turning feel like
  // flying rather than steering a car.
  const up = upOf(q);
  const right = rightOf(q);
  const bank = Math.atan2(-right.y, up.y);
  const turn = -Math.sin(bank) * TURN_COEF * auth * rate;
  q = qNorm(qMul(qAxis(WORLD_UP, turn * dt), q));

  // Energy. Thrust tapers off as you approach the throttle's target speed, so
  // drag can actually win — which is the whole point. Climbing costs you speed,
  // and so does pulling G: without induced drag a flat max-rate turn is free and
  // two evenly matched pilots just orbit each other until the clock runs out.
  const target = minS + throttle * (maxS - minS);
  p.speed += (target - p.speed) * THRUST_K * dt;
  let f = fwdOf(q);
  p.speed -= f.y * CLIMB_DRAG * k * dt;
  p.speed -= Math.abs(pitch) * auth * TURN_DRAG * k * dt;
  p.speed = clamp(p.speed, 22 * k, maxS * 1.3);

  // Stalled: the nose sags toward the ground whether you like it or not.
  if (p.speed < stallS) {
    const droop = (1 - p.speed / stallS) * 1.6 * dt;
    q = qLook(norm(add(f, v3(0, -droop, 0))), upOf(q));
    f = fwdOf(q);
  }

  p.q = q;
  p.pos = add(p.pos, scale(f, p.speed * dt));
}
