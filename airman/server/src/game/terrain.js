import { WORLD, HMAP_N, MAX_H, PLATEAU_R, PLATEAU_H } from './constants.js';

// Seeded value noise. Nothing fancy — an island only needs to look like an island.
function hash2(x, y, seed) {
  let h = x * 374761393 + y * 668265263 + seed * 2246822519;
  h = (h ^ (h >>> 13)) >>> 0;
  h = Math.imul(h, 1274126177) >>> 0;
  return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
}

const smooth = (t) => t * t * (3 - 2 * t);

function valueNoise(x, y, seed) {
  const xi = Math.floor(x), yi = Math.floor(y);
  const xf = x - xi, yf = y - yi;
  const a = hash2(xi, yi, seed);
  const b = hash2(xi + 1, yi, seed);
  const c = hash2(xi, yi + 1, seed);
  const d = hash2(xi + 1, yi + 1, seed);
  const u = smooth(xf), v = smooth(yf);
  return a * (1 - u) * (1 - v) + b * u * (1 - v) + c * (1 - u) * v + d * u * v;
}

function fbm(x, y, seed) {
  let sum = 0, amp = 0.5, freq = 1, norm = 0;
  for (let o = 0; o < 5; o++) {
    sum += valueNoise(x * freq, y * freq, seed + o * 977) * amp;
    norm += amp;
    amp *= 0.5;
    freq *= 2.05;
  }
  return sum / norm;
}

const smoothstep = (e0, e1, x) => {
  const t = Math.min(1, Math.max(0, (x - e0) / (e1 - e0)));
  return t * t * (3 - 2 * t);
};

/**
 * Builds the island as a quantized Uint8 heightmap.
 *
 * Quantizing matters: the client renders and predicts against the exact bytes
 * the server collides against, so nobody can clip a hill the other side thinks
 * is solid. Reimplementing this noise in GDScript would risk float drift, so
 * the map travels over the wire instead.
 */
export function makeTerrain(seed) {
  const h = new Uint8Array(HMAP_N * HMAP_N);
  const half = WORLD / 2;

  for (let j = 0; j < HMAP_N; j++) {
    for (let i = 0; i < HMAP_N; i++) {
      const x = -half + (i / (HMAP_N - 1)) * WORLD;
      const z = -half + (j / (HMAP_N - 1)) * WORLD;

      // Radial falloff turns a noise field into an island with a shoreline.
      const r = Math.sqrt(x * x + z * z) / (WORLD * 0.44);
      const island = Math.pow(Math.max(0, 1 - r * r), 1.6);

      const n = fbm(x / 420, z / 420, seed);
      const ridged = 1 - Math.abs(fbm(x / 900, z / 900, seed + 4001) * 2 - 1);
      let height = (n * 0.62 + ridged * 0.38) * island * MAX_H;

      // Flatten the ground the castle stands on, and blend the skirt out.
      const d = Math.sqrt(x * x + z * z);
      const t = 1 - smoothstep(PLATEAU_R, PLATEAU_R + 190, d);
      height = height * (1 - t) + PLATEAU_H * t;

      h[j * HMAP_N + i] = Math.max(0, Math.min(255, Math.round((height / MAX_H) * 255)));
    }
  }
  return h;
}

/** Bilinear height at a world position. Identical maths on the client. */
export function heightAt(hmap, x, z) {
  const half = WORLD / 2;
  const fx = ((x + half) / WORLD) * (HMAP_N - 1);
  const fz = ((z + half) / WORLD) * (HMAP_N - 1);
  if (fx < 0 || fz < 0 || fx > HMAP_N - 1 || fz > HMAP_N - 1) return 0; // open sea

  const i = Math.floor(fx), j = Math.floor(fz);
  const i2 = Math.min(HMAP_N - 1, i + 1), j2 = Math.min(HMAP_N - 1, j + 1);
  const tx = fx - i, tz = fz - j;

  const a = hmap[j * HMAP_N + i];
  const b = hmap[j * HMAP_N + i2];
  const c = hmap[j2 * HMAP_N + i];
  const d = hmap[j2 * HMAP_N + i2];
  const top = a * (1 - tx) + b * tx;
  const bot = c * (1 - tx) + d * tx;
  return ((top * (1 - tz) + bot * tz) / 255) * MAX_H;
}

export const packTerrain = (hmap) => Buffer.from(hmap).toString('base64');
