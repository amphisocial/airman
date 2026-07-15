// Just enough 3D maths for the flight model. Godot convention: -Z is forward,
// +Y is up, so the client can use these values without flipping anything.

export const v3 = (x = 0, y = 0, z = 0) => ({ x, y, z });
export const add = (a, b) => v3(a.x + b.x, a.y + b.y, a.z + b.z);
export const sub = (a, b) => v3(a.x - b.x, a.y - b.y, a.z - b.z);
export const scale = (a, s) => v3(a.x * s, a.y * s, a.z * s);
export const dot = (a, b) => a.x * b.x + a.y * b.y + a.z * b.z;
export const len = (a) => Math.sqrt(dot(a, a));
export const dist = (a, b) => len(sub(a, b));

export function norm(a) {
  const l = len(a);
  return l > 1e-9 ? scale(a, 1 / l) : v3(0, 0, -1);
}

export function cross(a, b) {
  return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}

// --- quaternions (x, y, z, w) --------------------------------------------

export const qId = () => ({ x: 0, y: 0, z: 0, w: 1 });

export function qMul(a, b) {
  return {
    x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
    y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
    z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
  };
}

export const qConj = (q) => ({ x: -q.x, y: -q.y, z: -q.z, w: q.w });

export function qNorm(q) {
  const l = Math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
  if (l < 1e-9) return qId();
  return { x: q.x / l, y: q.y / l, z: q.z / l, w: q.w / l };
}

export function qAxis(axis, angle) {
  const h = angle * 0.5;
  const s = Math.sin(h);
  return { x: axis.x * s, y: axis.y * s, z: axis.z * s, w: Math.cos(h) };
}

export function qRotate(q, v) {
  // v' = q * v * q^-1, expanded
  const { x, y, z, w } = q;
  const tx = 2 * (y * v.z - z * v.y);
  const ty = 2 * (z * v.x - x * v.z);
  const tz = 2 * (x * v.y - y * v.x);
  return v3(
    v.x + w * tx + (y * tz - z * ty),
    v.y + w * ty + (z * tx - x * tz),
    v.z + w * tz + (x * ty - y * tx),
  );
}

export const fwdOf = (q) => qRotate(q, v3(0, 0, -1));
export const upOf = (q) => qRotate(q, v3(0, 1, 0));
export const rightOf = (q) => qRotate(q, v3(1, 0, 0));

export function qLook(dir, up = v3(0, 1, 0)) {
  const f = norm(dir);
  let r = cross(up, scale(f, -1));
  if (len(r) < 1e-5) r = v3(1, 0, 0);
  r = norm(r);
  const u = cross(scale(f, -1), r);
  // Build a quaternion from the basis (r, u, -f)
  const m00 = r.x, m01 = u.x, m02 = -f.x;
  const m10 = r.y, m11 = u.y, m12 = -f.y;
  const m20 = r.z, m21 = u.z, m22 = -f.z;
  const tr = m00 + m11 + m22;
  let q;
  if (tr > 0) {
    const s = Math.sqrt(tr + 1) * 2;
    q = { w: 0.25 * s, x: (m21 - m12) / s, y: (m02 - m20) / s, z: (m10 - m01) / s };
  } else if (m00 > m11 && m00 > m22) {
    const s = Math.sqrt(1 + m00 - m11 - m22) * 2;
    q = { w: (m21 - m12) / s, x: 0.25 * s, y: (m01 + m10) / s, z: (m02 + m20) / s };
  } else if (m11 > m22) {
    const s = Math.sqrt(1 + m11 - m00 - m22) * 2;
    q = { w: (m02 - m20) / s, x: (m01 + m10) / s, y: 0.25 * s, z: (m12 + m21) / s };
  } else {
    const s = Math.sqrt(1 + m22 - m00 - m11) * 2;
    q = { w: (m10 - m01) / s, x: (m02 + m20) / s, y: (m12 + m21) / s, z: 0.25 * s };
  }
  return qNorm(q);
}

// Closest approach of a moving point to a sphere, over one step.
// Bullets cover ~23 units a tick and planes are 6 across — a naive point test
// would shoot straight through them.
export function segHitsSphere(p0, p1, c, r) {
  const d = sub(p1, p0);
  const f = sub(p0, c);
  const a = dot(d, d);
  if (a < 1e-9) return dot(f, f) <= r * r;
  const b = 2 * dot(f, d);
  const cc = dot(f, f) - r * r;
  const disc = b * b - 4 * a * cc;
  if (disc < 0) return false;
  const sq = Math.sqrt(disc);
  const t1 = (-b - sq) / (2 * a);
  const t2 = (-b + sq) / (2 * a);
  return (t1 >= 0 && t1 <= 1) || (t2 >= 0 && t2 <= 1) || (t1 < 0 && t2 > 1);
}
