// Airman — authoritative constants.
// client/autoload/GameState.gd mirrors the FLIGHT block for local prediction.
// If you change anything in that block, change it there too.

export const TICK_HZ = 30;
export const DT = 1 / TICK_HZ;

// --- world ---------------------------------------------------------------
export const WORLD = 3000;        // island spans -1500..1500 on X and Z
export const HMAP_N = 128;        // heightmap resolution (sent to clients once)
export const MAX_H = 240;         // tallest terrain
export const SEA_LEVEL = 0;
export const PLATEAU_R = 190;     // flat ground the castle sits on
export const PLATEAU_H = 150;
export const PLAY_RADIUS = 1400;  // leave this and you start bleeding
export const OOB_GRACE = 6;       // seconds outside before damage starts
export const OOB_DPS = 14;

// --- FLIGHT (mirrored on the client) -------------------------------------
export const MIN_SPEED = 60;
export const MAX_SPEED = 170;
export const THRUST_K = 0.55;     // thrust tapers as you approach target speed
export const TURN_DRAG = 20;      // hauling on the stick costs energy
export const PITCH_RATE = 1.4;    // rad/s
export const ROLL_RATE = 3.2;
export const YAW_RATE = 0.45;     // rudder
export const TURN_COEF = 0.95;    // how hard a bank drags the nose round
export const CLIMB_DRAG = 34;     // speed lost pulling straight up, per second
export const STALL_SPEED = 66;
export const CORNER_SPEED = 115;  // best turn rate; slower is lift-limited, faster is G-limited
export const PLANE_R = 6;         // hit sphere
export const GROUND_CLEAR = 4;    // below terrain + this = you're a crater
// --- end FLIGHT ----------------------------------------------------------

export const MAX_HP = 100;

// --- guns ----------------------------------------------------------------
export const AMMO = 500;
export const FIRE_HZ = 12;
export const BULLET_SPEED = 700;
export const BULLET_LIFE = 2.0;
export const BULLET_DMG = 26;     // ~4 hits to kill: about 2s of someone tracking you.
                                  // Swept this: below ~18 two evenly matched pilots
                                  // simply never finish, and every match times out.
export const GUN_SPREAD = 0.005;  // radians

// --- castle flak ---------------------------------------------------------
// Four guns on the towers. They fire at whoever's in range — the crews can't
// tell friend from foe in a furball, which is exactly what makes it a hazard.
export const FLAK_RANGE = 1300;
export const FLAK_SPEED = 260;
export const FLAK_BURST_R = 58;
export const FLAK_DMG = 36;       // at the centre of the burst, falls off to 0
export const FLAK_FIRST = 9;      // seconds of peace at the start
export const FLAK_GAP_START = 9.0;
export const FLAK_GAP_END = 3.5;  // the guns warm up as the match drags on
export const FLAK_RAMP = 240;     // seconds to reach FLAK_GAP_END
export const FLAK_LEAD_ERR = 0.16;// fraction of the lead solution they fumble
export const TOWERS = [
  { x: -128, y: PLATEAU_H + 62, z: -128 },
  { x: 128, y: PLATEAU_H + 62, z: -128 },
  { x: -128, y: PLATEAU_H + 62, z: 128 },
  { x: 128, y: PLATEAU_H + 62, z: 128 },
];

// --- match ---------------------------------------------------------------
export const MATCH_TIME = 300;
export const MAX_PLAYERS = 2;
export const MATCH_END_LINGER = 11;
export const SPAWN_DIST = 900;
export const SPAWN_ALT = 260;

export const COLORS = ['#e8563f', '#3fa9e8'];
export const CALLSIGNS = ['Vulture', 'Hornet', 'Shrike', 'Kestrel', 'Magpie'];
