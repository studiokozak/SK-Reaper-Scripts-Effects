-- @description SK Harmonic Compass
-- @author      Studio Kozak
-- @version     2.0
-- @changelog   v2.0 — Add Listen Mode



-- ============================================================
-- SECTION 1 — DEPENDENCY CHECK
-- Abort early if ReaImGui is not installed.
-- ============================================================
if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox(
    "ReaImGui not found. Please install it via ReaPack.", "Error", 0)
  return
end

-- ============================================================
-- SECTION 2 — CONTEXT & CONSTANTS
-- ============================================================
local ctx        = reaper.ImGui_CreateContext('Harmonic Compass')

-- Chromatic note names (C = 0 … B = 11).
local note_names = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}

-- Circle of fifths: maps sector index (1–12) to pitch class (0–11).
local circle_fifths = {0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5}

-- ============================================================
-- SECTION 3 — SCRIPT STATE
-- All mutable state is declared here for clarity.
-- ============================================================
local selected_root_idx   = 1     -- Pitch-class index of the current tonic.
local selected_sector_idx = 1     -- Visual sector highlighted in the circle.
local is_minor_mode       = false -- true = minor; false = major.
local duration_idx        = 5     -- Default: quarter note.
local octave              = 4     -- Base octave for note insertion.
local color_idx           = 1     -- Selected color extension (1 = plain triad).
local voicing_idx         = 1     -- Manual voicing preset index (1 = closed position).
local voicing_override    = false -- false = auto voice leading; true = manual voicing.
local last_bass           = -1    -- Last bass MIDI note played (-1 = none).
local minor_mode_idx      = 1     -- Index into minor_modes table.
local major_mode_idx      = 1     -- Index into major_modes table.
local pattern_idx         = 1     -- Selected rhythmic pattern (1 = Block).
local humanize_idx        = 1     -- Humanization level: 1=Off, 2=Med, 3=High.

-- ============================================================
-- SECTION 3b — LISTEN MODE STATE
-- ============================================================
local listen_mode         = false  -- Toggle: true = preview on hover active.
local listen_hovered_deg  = nil    -- Degree index (1–7) currently being previewed, or nil.
local listen_hovered_shift= nil    -- Shift state at last degree preview (true/false/nil).
local listen_hovered_sub  = nil    -- String key of the substitution MenuItem being previewed,
                                   -- or nil.  Format: "family:index" e.g. "tri:1", "dia:2".
local listen_notes        = {}     -- MIDI note numbers currently sounding (for Note Off).
local listen_end_time     = 0      -- reaper.time_precise() deadline for Note Off.
local listen_track_state  = nil    -- Saved track arm/monitoring state, restored on toggle-off.
                                   -- { armed, monitoring }

-- ============================================================
-- SECTION 4a — NOTE DURATIONS
-- Multipliers are expressed relative to a quarter note = 1.
-- ============================================================
local duration_names = {
  "Whole", "Dotted Half", "Half", "Dotted Quarter",
  "Quarter", "Dotted Eighth", "Eighth", "Sixteenth",
}
local duration_mults = {4, 3, 2, 1.5, 1, 0.75, 0.5, 0.25}

-- Short labels for the duration button bar.
-- Expressed as fractions of a 4/4 bar for maximum clarity.
local duration_icons = {
  "1/1",   -- Whole
  "3/4",   -- Dotted half
  "1/2",   -- Half
  "3/8",   -- Dotted quarter
  "1/4",   -- Quarter
  "3/16",  -- Dotted eighth
  "1/8",   -- Eighth
  "1/16",  -- Sixteenth
}

-- ============================================================
-- SECTION 4a-bis — RHYTHMIC PATTERNS
--
-- Each pattern entry contains:
--   name      : display label for the combo box.
--   min_beats : minimum duration in quarter notes required for this
--               pattern to make musical sense.  If the chosen duration
--               is shorter, insertion is cancelled and the user is
--               informed via ShowMessageBox.
--   fn        : function(notes, B, D) → list of {midi, ts, te, vel}
--
-- Parameters received by fn:
--   notes : voiced MIDI note list, bass first.
--   B     : one quarter-note duration in PPQ ticks (real project PPQ).
--   D     : total chosen duration in PPQ ticks (= q_e - q_s).
--
-- All ts / te values are PPQ offsets from q_s (not absolute).
-- The inserter clamps them to [0, D] and skips events where te <= ts.
-- Velocities are per-event and reflect musical phrasing.
-- ============================================================

-- Helper: round to nearest integer.
local function r(v) return math.floor(v + 0.5) end

local patterns = {

  -- 1. BLOCK
  -- All notes simultaneously for the full duration.
  -- Velocity: uniform 100. Always valid regardless of duration.
  {
    name      = "Block",
    min_beats = 0,
    fn = function(notes, B, D)
      local evts = {}
      for _, midi_n in ipairs(notes) do
        evts[#evts+1] = { midi=midi_n, ts=0, te=D, vel=100 }
      end
      return evts
    end,
  },

  -- 2. ANTICIPATE
  -- The chord lands one eighth note BEFORE the barline — a classic
  -- anticipation that pulls the harmony forward into the next beat.
  -- Bass holds through, upper voices hit early then sustain to end.
  -- Universal technique in jazz, soul, and modern pop production.
  -- min_beats = 1 to leave room for the anticipation offset.
  {
    name      = "Anticipate",
    min_beats = 1,
    fn = function(notes, B, D)
      local evts = {}
      local N    = #notes
      local E    = r(B / 2)        -- Eighth note offset.
      local late = r(B * 0.92)     -- Slightly shorter than a full beat for breathing room.
      -- Bass: hits right on the downbeat, holds full duration.
      evts[#evts+1] = { midi=notes[1], ts=0, te=D, vel=88 }
      -- Upper voices: anticipated — enter E ticks before the end, sustain to D.
      -- If D > E the anticipation is meaningful; inserter clamps automatically.
      local ant = math.max(0, D - E)
      for i = 2, N do
        evts[#evts+1] = { midi=notes[i], ts=ant, te=D, vel=82 }
      end
      return evts
    end,
  },

  -- 3. PUSH & HOLD
  -- Short punchy hit on beat 1, brief silence, then a soft chord
  -- lands on the "2 and" and floats to the end.
  -- Inspired by J Dilla / Madlib keyboard work — slightly off-kilter,
  -- never lands squarely on the downbeat after the initial stab.
  {
    name      = "Push & Hold",
    min_beats = 2,
    fn = function(notes, B, D)
      local evts = {}
      local N    = #notes
      local S    = r(B / 4)        -- Sixteenth — short stab duration.
      local E    = r(B / 2)        -- Eighth note.
      -- Beat 1: full chord, short and punchy.
      for _, midi_n in ipairs(notes) do
        evts[#evts+1] = { midi=midi_n, ts=0, te=S, vel=96 }
      end
      -- "2 and": soft chord floats to the end.
      local t2 = r(B * 1.5)
      for _, midi_n in ipairs(notes) do
        evts[#evts+1] = { midi=midi_n, ts=t2, te=D, vel=70 }
      end
      return evts
    end,
  },

  -- 4. STAB x2
  -- Two crisp stabs on irregular syncopated positions —
  -- beat 1 and the "3 and" — leaving the rest of the bar open.
  -- Minimalist comping; gives the rhythm section room to breathe.
  -- Works equally well in neo-soul, hip-hop, and modern jazz.
  {
    name      = "Stab x2",
    min_beats = 2,
    fn = function(notes, B, D)
      local evts = {}
      local S    = r(B * 0.4)      -- Slightly longer than a 16th for warmth.
      -- Stab 1: beat 1, strong.
      for _, midi_n in ipairs(notes) do
        evts[#evts+1] = { midi=midi_n, ts=0, te=S, vel=92 }
      end
      -- Stab 2: "3 and" = 2.5 beats in, slightly softer.
      local t2 = r(B * 2.5)
      for _, midi_n in ipairs(notes) do
        evts[#evts+1] = { midi=midi_n, ts=t2, te=t2+S, vel=80 }
      end
      return evts
    end,
  },

  -- 5. SWELL
  -- Notes enter bottom-to-top on a decelerating square-root curve,
  -- each sustaining to the end — fast at the bottom, slowing as the
  -- chord fills out.  Feels orchestral, like strings or a pad opening.
  -- Great for tension builds and cinematic transitions.
  {
    name      = "Swell",
    min_beats = 1,
    fn = function(notes, B, D)
      local evts  = {}
      local N     = #notes
      local vels  = { 92, 86, 80, 76, 72, 68, 65 }
      local window = r(B * 1.8)    -- Entry spread: 1.8 beats.
      for i, midi_n in ipairs(notes) do
        local frac = (i - 1) / math.max(N - 1, 1)
        local ts   = r(window * (1 - math.sqrt(1 - frac)))
        evts[#evts+1] = { midi=midi_n, ts=ts, te=D,
          vel=vels[math.min(i, #vels)] }
      end
      return evts
    end,
  },

  -- 6. ROLL
  -- Fast upward arpeggio — each note enters one 32nd note after the
  -- previous, all sustaining to the end.  Like a pianist rolling a
  -- chord from the wrist, or a guitarist strumming up.
  -- Very natural, one-shot gesture.
  {
    name      = "Roll",
    min_beats = 0.25,
    fn = function(notes, B, D)
      local evts   = {}
      local N      = #notes
      local stagger = r(B / 8)     -- 32nd note between each voice.
      local vels    = { 88, 84, 80, 77, 74, 71, 68 }
      for i, midi_n in ipairs(notes) do
        local ts = r((i - 1) * stagger)
        evts[#evts+1] = { midi=midi_n, ts=ts, te=D,
          vel=vels[math.min(i, #vels)] }
      end
      return evts
    end,
  },

  -- 7. PULSE 8TH
  -- The chord repeats on every eighth note for the full duration,
  -- with alternating strong/soft velocities (downbeat vs upbeat).
  -- Creates a hypnotic, driving groove — house, deep techno, soul.
  -- Each hit is a 16th note long for crisp separation.
  {
    name      = "Pulse 8th",
    min_beats = 1,
    fn = function(notes, B, D)
      local evts    = {}
      local E       = r(B / 2)     -- Eighth note interval.
      local S       = r(B / 4)     -- 16th note duration per hit.
      local n_hits  = math.floor(D / E)
      local vels_db = { 90, 72 }   -- Alternating: downbeat strong, upbeat soft.
      for k = 0, n_hits - 1 do
        local ts  = r(k * E)
        local vel = vels_db[(k % 2) + 1]
        for _, midi_n in ipairs(notes) do
          evts[#evts+1] = { midi=midi_n, ts=ts, te=ts+S, vel=vel }
        end
      end
      return evts
    end,
  },

  -- 8. DRUNK
  -- Full chord on beat 1, then two ghost repeats at intentionally
  -- irregular (non-quantized) timing — slightly late, asymmetric.
  -- Inspired by J Dilla's "drunk" feel applied to chord stabs.
  -- The irregularity is deterministic (not random) so the feel is
  -- consistent across multiple insertions of the same pattern.
  {
    name      = "Drunk",
    min_beats = 2,
    fn = function(notes, B, D)
      local evts = {}
      local S    = r(B * 0.35)     -- Short stab, slightly longer than a 16th.
      -- Beat 1: on the grid, strong.
      for _, midi_n in ipairs(notes) do
        evts[#evts+1] = { midi=midi_n, ts=0, te=S, vel=94 }
      end
      -- Ghost 1: deliberately late — sits between "1 and" and beat 2.
      local t1 = r(B * 0.72)
      for _, midi_n in ipairs(notes) do
        evts[#evts+1] = { midi=midi_n, ts=t1, te=t1+S, vel=62 }
      end
      -- Ghost 2: also irregular — lands just after "2 and".
      local t2 = r(B * 1.58)
      for _, midi_n in ipairs(notes) do
        evts[#evts+1] = { midi=midi_n, ts=t2, te=t2+S, vel=54 }
      end
      return evts
    end,
  },

  -- 9. BREATH
  -- Full chord on beat 1, a silence (the "breath"), then a softer
  -- re-attack on beat 3 that sustains to the end.
  -- Mimics the natural phrasing of a singer or horn player — attack,
  -- release, inhale, resolve.  Works in any tempo and style.
  {
    name      = "Breath",
    min_beats = 2,
    fn = function(notes, B, D)
      local evts   = {}
      local phrase = r(B * 0.85)   -- First phrase ends just before beat 2.
      -- Beat 1: full chord, confident.
      for _, midi_n in ipairs(notes) do
        evts[#evts+1] = { midi=midi_n, ts=0, te=phrase, vel=92 }
      end
      -- Beat 3 (re-attack): softer, sustains to end.
      local t2 = r(B * 2)
      if t2 < D then
        for _, midi_n in ipairs(notes) do
          evts[#evts+1] = { midi=midi_n, ts=t2, te=D, vel=72 }
        end
      end
      return evts
    end,
  },

  -- 10. CHOP
  -- Four evenly-spaced 32nd-note stabs across the bar — very short,
  -- very tight.  Evokes the sound of a chopped soul sample: the chord
  -- flickers rather than sustains.  Madlib / Pete Rock aesthetic.
  -- Velocities vary to avoid a mechanical feel.
  {
    name      = "Chop",
    min_beats = 2,
    fn = function(notes, B, D)
      local evts  = {}
      local chop  = r(B / 8)       -- 32nd note — stab duration.
      local gap   = r(D / 4)       -- Four equal chops across the duration.
      local vels  = { 90, 76, 84, 70 }
      for k = 0, 3 do
        local ts = r(k * gap)
        for _, midi_n in ipairs(notes) do
          evts[#evts+1] = { midi=midi_n, ts=ts, te=ts+chop, vel=vels[k+1] }
        end
      end
      return evts
    end,
  },
}

-- Null-delimited combo string for the Pattern selector.
local PATTERN_COMBO_STR = (function()
  local t = {}
  for _, p in ipairs(patterns) do t[#t+1] = p.name end
  return table.concat(t, "\0") .. "\0"
end)()

-- ============================================================
-- SECTION 4a-ter — PATTERN INSERTER
--
-- Validates that the chosen duration meets the pattern's min_beats
-- requirement, applies humanization, then calls the pattern function
-- to generate {midi, ts, te, vel} events and inserts them into the
-- take via MIDI_InsertNote.
-- Returns true on success, false if the duration check failed.
-- ============================================================
local function insert_pattern(take, voiced_notes, q_s, q_e, cursor_pos)
  local pat       = patterns[pattern_idx]
  local tempo     = reaper.Master_GetTempo()
  -- One quarter-note in PPQ ticks, computed from project time.
  local beat_sec  = 60.0 / tempo
  local ppq_end   = reaper.MIDI_GetPPQPosFromProjTime(take, cursor_pos + beat_sec)
  local ppq_start = reaper.MIDI_GetPPQPosFromProjTime(take, cursor_pos)
  local B         = ppq_end - ppq_start   -- One beat in PPQ.
  local D         = q_e - q_s             -- Total chosen duration in PPQ.

  -- Duration compatibility check.
  if pat.min_beats > 0 then
    local chosen_beats = D / B
    if chosen_beats < pat.min_beats then
      reaper.ShowMessageBox(
        'Pattern "' .. pat.name .. '" requires at least '
        .. pat.min_beats .. ' beat(s).\n\n'
        .. 'Current duration: '
        .. string.format("%.2f", chosen_beats) .. ' beat(s).\n\n'
        .. 'Please select a longer duration or choose a different pattern.',
        "Harmonic Compass — Pattern Warning", 0)
      return false
    end
  end

  -- Humanization parameters indexed by humanize_idx.
  -- timing_var : max timing offset in PPQ ticks (±).
  -- vel_var    : max velocity offset (±).
  -- dur_var    : max duration offset in PPQ ticks (±).
  local hum = {
    { timing_var=0,        vel_var=0,  dur_var=0        },  -- 1: Off
    { timing_var=r(B/16),  vel_var=6,  dur_var=r(B/32)  },  -- 2: Med  (±1/64)
    { timing_var=r(B/8),   vel_var=12, dur_var=r(B/16)  },  -- 3: High (±1/32)
  }
  local h = hum[humanize_idx]

  -- Applies timing, velocity and duration micro-variations to one event.
  -- Offsets are random within the window defined by the current level.
  -- ts and te are PPQ offsets from q_s; vel is the target velocity.
  local function humanize(ts, te, vel)
    if humanize_idx > 1 then
      local t_off = (h.timing_var > 0)
                    and math.random(-h.timing_var, h.timing_var) or 0
      local d_off = (h.dur_var > 0)
                    and math.random(-h.dur_var,    h.dur_var)    or 0
      local v_off = (h.vel_var > 0)
                    and math.random(-h.vel_var,    h.vel_var)    or 0
      ts  = ts  + t_off
      te  = te  + t_off + d_off
      vel = math.max(1, math.min(127, vel + v_off))
    end
    return ts, te, vel
  end

  -- Generate and insert events.
  local evts = pat.fn(voiced_notes, B, D)
  for _, ev in ipairs(evts) do
    local ts, te, vel = humanize(ev.ts, ev.te, ev.vel or 100)
    ts = q_s + math.max(0, math.min(D, ts))
    te = q_s + math.max(0, math.min(D, te))
    if te > ts then
      local midi_n = math.max(0, math.min(127, ev.midi))
      reaper.MIDI_InsertNote(take, false, false, ts, te, 1, midi_n, vel, false)
    end
  end
  return true
end

-- ============================================================
-- SECTION 4b — MINOR SCALE MODES
-- ============================================================
local minor_modes = {
  {
    name    = "Natural",
    ivs     = {0,2,3,5,7,8,10},
    types   = {"min","dim","maj","min","min","maj","maj"},
    degrees = {"i","iio","III","iv","v","VI","VII"},
  },
  {
    name    = "Harmonic",
    ivs     = {0,2,3,5,7,8,11},
    types   = {"min","dim","aug","min","maj","maj","dim"},
    degrees = {"i","iio","III+","iv","V","VI","viio"},
  },
  {
    name    = "Melodic",
    ivs     = {0,2,3,5,7,9,11},
    types   = {"min","min","aug","maj","maj","dim","dim"},
    degrees = {"i","ii","III+","IV","V","vio","viio"},
  },
  {
    name    = "Dorian",
    ivs     = {0,2,3,5,7,9,10},
    types   = {"min","min","maj","maj","min","dim","maj"},
    degrees = {"i","ii","III","IV","v","vio","VII"},
  },
  {
    name    = "Phrygian",
    ivs     = {0,1,3,5,7,8,10},
    types   = {"min","maj","maj","min","dim","maj","min"},
    degrees = {"i","II","III","iv","vo","VI","vii"},
  },
  {
    name    = "Phr. Dominant",
    ivs     = {0,1,4,5,7,8,10},
    types   = {"maj","dim","min","min","dim","maj","min"},
    degrees = {"I","IIo","iii","iv","vo","VI","vii"},
  },
  {
    name    = "Locrian",
    ivs     = {0,1,3,5,6,8,10},
    types   = {"dim","maj","min","min","maj","maj","min"},
    degrees = {"io","II","iii","iv","V","VI","vii"},
  },
}

local MINOR_MODE_COMBO_STR = (function()
  local t = {}
  for _, m in ipairs(minor_modes) do t[#t+1] = m.name end
  return table.concat(t, "\0") .. "\0"
end)()

-- ============================================================
-- SECTION 4c — MAJOR SCALE MODES
-- ============================================================
local major_modes = {
  {
    name    = "Major",
    ivs     = {0,2,4,5,7,9,11},
    types   = {"maj","min","min","maj","maj","min","dim"},
    degrees = {"I","ii","iii","IV","V","vi","viio"},
  },
  {
    name    = "Lydian",
    ivs     = {0,2,4,6,7,9,11},
    types   = {"maj","min","dim","maj","maj","min","min"},
    degrees = {"I","ii","iiio","#IV","V","vi","vii"},
  },
  {
    name    = "Mixolydian",
    ivs     = {0,2,4,5,7,9,10},
    types   = {"maj","min","dim","maj","min","min","maj"},
    degrees = {"I","ii","iiio","IV","v","vi","VII"},
  },
  {
    name    = "Lyd. Dominant",
    ivs     = {0,2,4,6,7,9,10},
    types   = {"maj","min","dim","aug","maj","min","dim"},
    degrees = {"I","ii","iiio","#IV","V","vi","viio"},
  },
}

local MAJOR_MODE_COMBO_STR = (function()
  local t = {}
  for _, m in ipairs(major_modes) do t[#t+1] = m.name end
  return table.concat(t, "\0") .. "\0"
end)()

-- ============================================================
-- SECTION 5 — CHORD INTERVAL TABLE
-- ============================================================
local chords = {
  -- Triads (indices 1–6)
  { "",       {0,4,7}              },   -- 1  Major
  { "m",      {0,3,7}              },   -- 2  Minor
  { "dim",    {0,3,6}              },   -- 3  Diminished
  { "aug",    {0,4,8}              },   -- 4  Augmented
  { "sus2",   {0,2,7}              },   -- 5  Suspended 2nd
  { "sus4",   {0,5,7}              },   -- 6  Suspended 4th
  -- Seventh chords (indices 7–12)
  { "maj7",   {0,4,7,11}           },   -- 7  Major 7th
  { "m7",     {0,3,7,10}           },   -- 8  Minor 7th
  { "7",      {0,4,7,10}           },   -- 9  Dominant 7th
  { "m7b5",   {0,3,6,10}           },   -- 10 Half-diminished
  { "dim7",   {0,3,6,9}            },   -- 11 Fully diminished 7th
  { "mMaj7",  {0,3,7,11}           },   -- 12 Minor major 7th
  -- Ninth chords (indices 13–18)
  { "add9",   {0,4,7,14}           },   -- 13 Major add9
  { "madd9",  {0,3,7,14}           },   -- 14 Minor add9
  { "maj9",   {0,4,7,11,14}        },   -- 15 Major 9th
  { "m9",     {0,3,7,10,14}        },   -- 16 Minor 9th
  { "9",      {0,4,7,10,14}        },   -- 17 Dominant 9th
  { "9b5",    {0,4,6,10,14}        },   -- 18 Dominant 9th b5
  -- Eleventh chords (indices 19–21)
  { "11",     {0,4,7,10,14,17}     },   -- 19 Dominant 11th
  { "m11",    {0,3,7,10,14,17}     },   -- 20 Minor 11th
  { "maj11",  {0,4,7,11,14,17}     },   -- 21 Major 11th
  -- Thirteenth chords (indices 22–24)
  { "13",     {0,4,7,10,14,17,21}  },   -- 22 Dominant 13th
  { "m13",    {0,3,7,10,14,17,21}  },   -- 23 Minor 13th
  { "maj13",  {0,4,7,11,14,17,21}  },   -- 24 Major 13th
  -- Sixth chords (indices 25–28)
  { "6",      {0,4,7,9}            },   -- 25 Major 6th
  { "m6",     {0,3,7,9}            },   -- 26 Minor 6th
  { "6/9",    {0,4,7,9,14}         },   -- 27 Major 6/9
  { "m6/9",   {0,3,7,9,14}         },   -- 28 Minor 6/9
  -- Add extensions without 7th (indices 29–32)
  { "add11",  {0,4,7,17}           },   -- 29 Major add11
  { "madd11", {0,3,7,17}           },   -- 30 Minor add11
  { "add13",  {0,4,7,21}           },   -- 31 Major add13
  { "madd13", {0,3,7,21}           },   -- 32 Minor add13
}

-- ============================================================
-- SECTION 6 — COLOR EXTENSIONS
-- ============================================================
local color_extensions = {
  { "Triad",              1,   2,   3  },
  { "Aug triad",          4,   4,   4  },
  { "sus2",               5,   5,   5  },
  { "sus4",               6,   6,   6  },
  { "6th",               25,  26,  11  },
  { "6/9",               27,  28,  11  },
  { "Minor 7th (b7)",     9,   8,  10  },
  { "Major 7th",          7,  12,   7  },
  { "Dominant 7th",       9,   8,  11  },
  { "Half-dim 7th",      10,  10,  10  },
  { "add9",              13,  14,   3  },
  { "9th",               17,  16,  17  },
  { "Major 9th",         15,  16,  15  },
  { "add11",             29,  30,   3  },
  { "11th",              19,  20,  19  },
  { "Major 11th",        21,  20,  21  },
  { "add13",             31,  32,   3  },
  { "13th",              22,  23,  22  },
  { "Major 13th",        24,  23,  24  },
}

local function build_color_combo_str()
  local t = {}
  for _, ce in ipairs(color_extensions) do t[#t+1] = ce[1] end
  return table.concat(t, "\0") .. "\0"
end
local COLOR_COMBO_STR = build_color_combo_str()

local function get_chord_idx(deg_type, cidx)
  local ce = color_extensions[cidx]
  if     deg_type == "maj" then return ce[2]
  elseif deg_type == "min" then return ce[3]
  elseif deg_type == "aug" then return 4
  else                          return ce[4]
  end
end

-- ============================================================
-- SECTION 6b — VOICING PRESETS
-- ============================================================
local voicing_defs = {
  { name = "Closed",          def = {{0,0},{1,0},{2,0},{3,0},{4,0},{5,0},{6,0}} },
  { name = "1st Inversion",   def = {{1,0},{2,0},{3,0},{4,0},{5,0},{6,0},{0,1}} },
  { name = "2nd Inversion",   def = {{2,0},{3,0},{4,0},{5,0},{6,0},{0,1},{1,1}} },
  { name = "3rd Inversion",   def = {{3,0},{4,0},{5,0},{6,0},{0,1},{1,1},{2,1}} },
  { name = "Open",            def = {{0,0},{2,0},{1,1},{3,1},{4,1},{5,1},{6,1}} },
  { name = "Drop 2",          def = {{0,0},{2,0},{3,0},{4,0},{1,1},{5,0},{6,0}} },
  { name = "Drop 3",          def = {{0,0},{1,0},{3,0},{4,0},{2,1},{5,0},{6,0}} },
  { name = "Jazz (no 5th)",   def = {{0,0},{3,0},{1,1},{4,1},{5,1},{6,1}}       },
  { name = "Spread",          def = {{0,0},{2,1},{1,1},{3,2},{4,2},{5,2},{6,2}} },
}

local VOICING_COMBO_STR = (function()
  local t = {}
  for _, v in ipairs(voicing_defs) do t[#t+1] = v.name end
  return table.concat(t, "\0") .. "\0"
end)()

-- ============================================================
-- SECTION 7 — VOICING ENGINE
-- ============================================================
function build_base_notes(root_midi, intervals)
  local base_notes = {}
  for _, interval in ipairs(intervals) do
    local oct_off = math.floor(interval / 12)
    local note_12 = (root_midi % 12 + interval % 12) % 12
    local midi_n  = note_12 + (math.floor(root_midi / 12) + oct_off) * 12
    if oct_off == 0 and midi_n < root_midi then midi_n = midi_n + 12 end
    base_notes[#base_notes + 1] = midi_n
  end
  return base_notes
end

function apply_inversion(base_notes, inv)
  local n   = #base_notes
  inv       = inv % n
  local ordered = {}
  for i = inv + 1, n do ordered[#ordered + 1] = base_notes[i] end
  for i = 1, inv   do ordered[#ordered + 1] = base_notes[i] end
  local result = { ordered[1] }
  for i = 2, #ordered do
    local note = ordered[i]
    while note <= result[#result] do note = note + 12 end
    result[#result + 1] = note
  end
  return result
end

function best_voicing_voice_leading(base_notes, prev_bass)
  local n         = #base_notes
  local best      = nil
  local best_bass = nil
  local best_dist = 999
  for inv = 0, n - 1 do
    local candidate = apply_inversion(base_notes, inv)
    for _, shift in ipairs({0, -12, 12}) do
      local b = candidate[1] + shift
      if b >= 36 and b <= 96 then
        local dist = math.abs(b - prev_bass)
        if dist < best_dist then
          best_dist = dist
          best_bass = b
          best = {}
          for _, note in ipairs(candidate) do
            best[#best + 1] = note + shift
          end
        end
      end
    end
  end
  return best or apply_inversion(base_notes, 0), best_bass or base_notes[1]
end

function apply_voicing(root_midi, intervals, vidx)
  local base_notes = build_base_notes(root_midi, intervals)
  local inv        = math.min(vidx - 1, #base_notes - 1)
  return apply_inversion(base_notes, inv)
end

-- ============================================================
-- SECTION 7b — LISTEN MODE ENGINE
--
-- listen_note_off()
--   Sends MIDI Note Off (0x80) for every note currently stored in
--   listen_notes, then clears the table and resets the timer.
--   Safe to call even when listen_notes is empty.
--
-- listen_note_on(voiced_notes)
--   Sends MIDI Note On (0x90) for each note in voiced_notes at
--   velocity 90, stores them in listen_notes, and sets listen_end_time
--   to now + the currently selected duration (in seconds).
--   Calls listen_note_off() first to silence any previously ringing notes.
--
-- listen_tick()
--   Must be called every frame from the main loop.
--   Checks whether listen_end_time has elapsed and triggers Note Off
--   if it has, regardless of whether the mouse is still hovering.
--
-- listen_arm_track(track)
--   Saves the current arm + monitoring state of the track, then arms
--   it and enables input monitoring (mode 1 = monitor input).
--
-- listen_restore_track()
--   Restores the saved arm + monitoring state.  Called when Listen is
--   toggled off or the script closes.
-- ============================================================

local function listen_note_off()
  for _, midi_n in ipairs(listen_notes) do
    reaper.StuffMIDIMessage(0, 0x80, midi_n, 0)
  end
  listen_notes    = {}
  listen_end_time = 0
end

local function listen_note_on(voiced_notes)
  -- Silence previous chord immediately before starting a new one.
  listen_note_off()

  local duration_sec = (60.0 / reaper.Master_GetTempo()) * duration_mults[duration_idx]
  listen_end_time    = reaper.time_precise() + duration_sec

  for _, midi_n in ipairs(voiced_notes) do
    local safe_n = math.max(0, math.min(127, midi_n))
    reaper.StuffMIDIMessage(0, 0x90, safe_n, 90)
    listen_notes[#listen_notes + 1] = safe_n
  end
end

local function listen_tick()
  -- If notes are sounding and the timer has expired, send Note Off.
  if #listen_notes > 0 and reaper.time_precise() >= listen_end_time then
    listen_note_off()
    -- Allow re-trigger: clear all hover trackers so the next hover
    -- fires a fresh preview even if the same item is still under the mouse.
    listen_hovered_deg   = nil
    listen_hovered_shift = nil
    listen_hovered_sub   = nil
  end
end

local function listen_arm_track(track)
  if not track then return end
  -- Save current state so we can restore it on toggle-off.
  listen_track_state = {
    armed      = reaper.GetMediaTrackInfo_Value(track, "I_RECARM"),
    monitoring = reaper.GetMediaTrackInfo_Value(track, "I_RECMON"),
  }
  -- Arm the track.
  reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1)
  -- Enable input monitoring (1 = monitor when armed).
  reaper.SetMediaTrackInfo_Value(track, "I_RECMON", 1)
end

local function listen_restore_track()
  local track = reaper.GetSelectedTrack(0, 0)
  if track and listen_track_state then
    reaper.SetMediaTrackInfo_Value(track, "I_RECARM",
      listen_track_state.armed)
    reaper.SetMediaTrackInfo_Value(track, "I_RECMON",
      listen_track_state.monitoring)
  end
  listen_track_state = nil
end

-- Compute a voiced note list for a degree without inserting anything.
-- Mirrors the voicing logic inside insert_chord_custom().
local function get_voiced_notes_for_preview(chord_root, intervals)
  local tonic_midi = circle_fifths[selected_root_idx] + (octave + 1) * 12
  local root_midi  = chord_root + (octave + 1) * 12
  if root_midi < tonic_midi then root_midi = root_midi + 12 end

  local voiced
  if not voicing_override and last_bass >= 0 then
    local base_notes = build_base_notes(root_midi, intervals)
    voiced, _ = best_voicing_voice_leading(base_notes, last_bass)
  elseif not voicing_override and last_bass < 0 then
    local base_notes = build_base_notes(root_midi, intervals)
    voiced = apply_inversion(base_notes, 0)
  else
    voiced = apply_voicing(root_midi, intervals, voicing_idx)
  end
  return voiced
end

-- Same as get_voiced_notes_for_preview() but applies negative harmony
-- transformation first, mirroring the is_negative branch in insert_chord_custom().
local function get_voiced_notes_for_preview_neg(chord_root, intervals)
  local root_tonality = circle_fifths[selected_root_idx]

  local orig_notes = {}
  for _, iv in ipairs(intervals) do
    orig_notes[#orig_notes + 1] = (chord_root + iv) % 12
  end
  local neg_notes = {}
  for _, note in ipairs(orig_notes) do
    neg_notes[#neg_notes + 1] = get_negative_note(note, root_tonality)
  end
  table.sort(neg_notes)
  local neg_root = neg_notes[1]
  local neg_ivs  = {}
  for _, note in ipairs(neg_notes) do
    neg_ivs[#neg_ivs + 1] = (note - neg_root + 12) % 12
  end

  return get_voiced_notes_for_preview(neg_root, neg_ivs)
end

-- ============================================================
-- SECTION 8 — HARMONIC LOGIC
-- ============================================================
function get_negative_note(note, root)
  return ((root * 2) + 7 - note) % 12
end

function insert_chord_custom(root_note, intervals, is_negative)
  local track = reaper.GetSelectedTrack(0, 0)
  if not track then
    reaper.ShowMessageBox("Please select a track first.", "Error", 0)
    return
  end

  local cursor_pos = reaper.GetCursorPosition()
  local length_sec = (60 / reaper.Master_GetTempo()) * duration_mults[duration_idx]
  local q_end_time = cursor_pos + length_sec

  local take = reaper.MIDIEditor_GetTake(reaper.MIDIEditor_GetActive())
  if not take then
    for i = 0, reaper.GetTrackNumMediaItems(track) - 1 do
      local item  = reaper.GetTrackMediaItem(track, i)
      local i_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local i_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      if cursor_pos >= i_pos - 0.001 and cursor_pos < (i_pos + i_len) then
        take = reaper.GetActiveTake(item)
        break
      end
    end
  end
  if not take then
    local ni = reaper.CreateNewMIDIItemInProj(track, cursor_pos, q_end_time)
    if ni then take = reaper.GetActiveTake(ni) end
  end
  if not take then return end

  reaper.Undo_BeginBlock()

  local q_s           = reaper.MIDI_GetPPQPosFromProjTime(take, cursor_pos)
  local q_e           = reaper.MIDI_GetPPQPosFromProjTime(take, q_end_time)
  local root_tonality = circle_fifths[selected_root_idx]

  local final_intervals = intervals
  if is_negative then
    local orig_notes = {}
    for _, iv in ipairs(intervals) do
      orig_notes[#orig_notes + 1] = (root_note + iv) % 12
    end
    local neg_notes = {}
    for _, note in ipairs(orig_notes) do
      neg_notes[#neg_notes + 1] = get_negative_note(note, root_tonality)
    end
    table.sort(neg_notes)
    root_note       = neg_notes[1]
    final_intervals = {}
    for _, note in ipairs(neg_notes) do
      final_intervals[#final_intervals + 1] = (note - root_note + 12) % 12
    end
  end

  local tonic_midi = circle_fifths[selected_root_idx] + (octave + 1) * 12
  local root_midi  = root_note + (octave + 1) * 12
  if root_midi < tonic_midi then root_midi = root_midi + 12 end

  local voiced_notes
  if not voicing_override and last_bass >= 0 then
    local base_notes = build_base_notes(root_midi, final_intervals)
    local new_bass
    voiced_notes, new_bass = best_voicing_voice_leading(base_notes, last_bass)
    last_bass = new_bass
  elseif not voicing_override and last_bass < 0 then
    local base_notes = build_base_notes(root_midi, final_intervals)
    voiced_notes     = apply_inversion(base_notes, 0)
    last_bass        = voiced_notes[1]
  else
    voiced_notes = apply_voicing(root_midi, final_intervals, voicing_idx)
    last_bass    = voiced_notes[1]
  end

  -- Insert notes via the selected rhythmic pattern.
  -- Returns false if the chosen duration is incompatible with the pattern.
  local ok = insert_pattern(take, voiced_notes, q_s, q_e, cursor_pos)
  if not ok then
    reaper.Undo_EndBlock("Harmonic Compass: Insert Chord", -1)
    return
  end

  local item = reaper.GetMediaItemTake_Item(take)
  if item then
    local cname     = guess_chord_name(final_intervals)
    local item_name = note_names[root_note + 1] .. cname
    if is_negative then item_name = item_name .. " (neg)" end
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", item_name, true)
  end

  reaper.SetEditCurPos(q_end_time, true, false)
  reaper.Undo_EndBlock("Harmonic Compass: Insert Chord", -1)
  reaper.UpdateArrange()
end

-- ============================================================
-- SECTION 8b — DISPLAY UTILITIES
-- ============================================================
function get_chord_display(root_note, chord_name, intervals, is_neg)
  local root_tonality = circle_fifths[selected_root_idx]
  local final_root    = root_note
  local final_ivs     = intervals

  if is_neg then
    local orig = {}
    for _, iv in ipairs(intervals) do
      orig[#orig + 1] = (root_note + iv) % 12
    end
    local neg = {}
    for _, n in ipairs(orig) do
      neg[#neg + 1] = get_negative_note(n, root_tonality)
    end
    table.sort(neg)
    final_root = neg[1]
    final_ivs  = {}
    for _, n in ipairs(neg) do
      final_ivs[#final_ivs + 1] = (n - final_root + 12) % 12
    end
    chord_name = guess_chord_name(final_ivs)
  end

  local note_list = {}
  for _, iv in ipairs(final_ivs) do
    note_list[#note_list + 1] = note_names[(final_root + iv) % 12 + 1]
  end

  return note_names[final_root + 1] .. chord_name, note_list
end

function guess_chord_name(ivs)
  local s   = table.concat(ivs, ",")
  local map = {
    ["0,4,7"]          = "",
    ["0,3,7"]          = "m",
    ["0,3,6"]          = "dim",
    ["0,4,8"]          = "aug",
    ["0,2,7"]          = "sus2",
    ["0,5,7"]          = "sus4",
    ["0,4,7,11"]       = "maj7",
    ["0,3,7,10"]       = "m7",
    ["0,4,7,10"]       = "7",
    ["0,3,6,10"]       = "m7b5",
    ["0,3,6,9"]        = "dim7",
    ["0,3,7,11"]       = "mMaj7",
    ["0,4,7,14"]       = "add9",
    ["0,3,7,14"]       = "madd9",
    ["0,4,7,9"]        = "6",
    ["0,3,7,9"]        = "m6",
    ["0,4,7,10,14"]    = "9",
    ["0,3,7,10,14"]    = "m9",
    ["0,4,7,11,14"]    = "maj9",
    ["0,3,8"]          = "mb5",
    ["0,2,5,8"]        = "7alt",
  }
  return map[s] or "?"
end

-- ============================================================
-- SECTION 8c — SUBSTITUTION LOGIC
-- ============================================================

local function chord_notes_str(root, intervals)
  local t = {}
  for _, iv in ipairs(intervals) do
    t[#t+1] = note_names[(root + iv) % 12 + 1]
  end
  return table.concat(t, "-")
end

local function get_tritone_sub(root)
  local tri_root = (root + 6) % 12
  local ivs      = chords[9][2]
  return { { root = tri_root, ivs = ivs,
    label = note_names[tri_root + 1] .. "7  (bII7)" } }
end

local function get_relative_sub(root, deg_type)
  local results = {}
  if deg_type == "maj" then
    local r = (root + 9) % 12
    results[#results+1] = { root = r, ivs = chords[2][2],
      label = note_names[r+1] .. "m  (relative minor)" }
  elseif deg_type == "min" or deg_type == "dim" then
    local r = (root + 3) % 12
    results[#results+1] = { root = r, ivs = chords[1][2],
      label = note_names[r+1] .. "  (relative major)" }
  elseif deg_type == "aug" then
    local r1 = (root + 4) % 12
    local r2 = (root + 8) % 12
    results[#results+1] = { root = r1, ivs = chords[4][2],
      label = note_names[r1+1] .. "aug  (enharmonic root +4)" }
    results[#results+1] = { root = r2, ivs = chords[4][2],
      label = note_names[r2+1] .. "aug  (enharmonic root +8)" }
  end
  return results
end

local function get_diatonic_subs(source_root)
  local mm      = is_minor_mode and minor_modes[minor_mode_idx]
                                 or  major_modes[major_mode_idx]
  local tonic   = circle_fifths[selected_root_idx]
  local results = {}

  local src_deg = nil
  for d = 1, 7 do
    if (tonic + mm.ivs[d]) % 12 == source_root then
      src_deg = d; break
    end
  end
  if not src_deg then return results end

  local func_map = { 1, 2, 1, 2, 3, 1, 3 }
  local src_func = func_map[src_deg]

  for d = 1, 7 do
    if d ~= src_deg and func_map[d] == src_func then
      local r    = (tonic + mm.ivs[d]) % 12
      local cidx = get_chord_idx(mm.types[d], color_idx)
      local ivs  = chords[cidx][2]
      results[#results+1] = { root = r, ivs = ivs,
        label = mm.degrees[d] .. "  " .. note_names[r+1] .. chords[cidx][1] }
    end
  end
  return results
end

local function get_modal_borrowing_subs(source_root)
  local tonic     = circle_fifths[selected_root_idx]
  local results   = {}
  local mm_active = is_minor_mode and minor_modes[minor_mode_idx]
                                   or  major_modes[major_mode_idx]

  local src_deg = nil
  for d = 1, 7 do
    if (tonic + mm_active.ivs[d]) % 12 == source_root then
      src_deg = d; break
    end
  end
  if not src_deg then return results end

  local function scan(mode_list, active_idx, family)
    for mi, mode in ipairs(mode_list) do
      local is_active = (family == "minor" and is_minor_mode     and mi == active_idx)
                     or (family == "major" and not is_minor_mode  and mi == active_idx)
      if not is_active then
        local r    = (tonic + mode.ivs[src_deg]) % 12
        local cidx = get_chord_idx(mode.types[src_deg], color_idx)
        local ivs  = chords[cidx][2]
        results[#results+1] = { root = r, ivs = ivs,
          label = mode.name .. "  " .. note_names[r+1] .. chords[cidx][1] }
      end
    end
  end

  scan(minor_modes, minor_mode_idx, "minor")
  scan(major_modes, major_mode_idx, "major")
  return results
end

-- ============================================================
-- SECTION 8d — SUBSTITUTION CONTENT RENDERER
--
-- Draws the four substitution families inside an already-open
-- popup context.  Each MenuItem triggers chord insertion on click
-- and, when Listen Mode is active, previews the chord on hover.
-- listen_hovered_sub tracks the currently previewed substitution
-- as a "family:index" key to avoid re-triggering on every frame.
-- ============================================================
local function render_substitution_content(chord_root, deg_type, cidx, deg_name)
  local src_name = note_names[chord_root + 1] .. chords[cidx][1]
  reaper.ImGui_TextDisabled(ctx,
    "Substitutions for  " .. deg_name .. "  —  " .. src_name)
  reaper.ImGui_Separator(ctx)

  -- Helper: draws one substitution MenuItem, handles click and Listen hover.
  -- key : unique string identifying this item for listen_hovered_sub tracking.
  local function sub_item(s, key)
    if reaper.ImGui_MenuItem(ctx,
        s.label .. "   [" .. chord_notes_str(s.root, s.ivs) .. "]") then
      insert_chord_custom(s.root, s.ivs, false)
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    -- Listen Mode: preview on hover, re-trigger only when item changes.
    if listen_mode and reaper.ImGui_IsItemHovered(ctx) then
      if listen_hovered_sub ~= key then
        listen_hovered_sub   = key
        -- Entering a substitution clears the degree tracker so that
        -- going back to a degree button re-triggers it correctly.
        listen_hovered_deg   = nil
        listen_hovered_shift = nil
        local voiced = get_voiced_notes_for_preview(s.root, s.ivs)
        listen_note_on(voiced)
      end
    end
  end

  -- ---- 1. Tritone Substitution ----
  reaper.ImGui_TextDisabled(ctx, "Tritone Sub")
  for si, s in ipairs(get_tritone_sub(chord_root)) do
    sub_item(s, "tri:" .. si)
  end

  reaper.ImGui_Separator(ctx)

  -- ---- 2. Relative Substitution ----
  reaper.ImGui_TextDisabled(ctx, "Relative Sub")
  local rel = get_relative_sub(chord_root, deg_type)
  if #rel == 0 then
    reaper.ImGui_TextDisabled(ctx, "  (not applicable for this quality)")
  else
    for si, s in ipairs(rel) do
      sub_item(s, "rel:" .. si)
    end
  end

  reaper.ImGui_Separator(ctx)

  -- ---- 3. Diatonic Substitution ----
  reaper.ImGui_TextDisabled(ctx, "Diatonic Sub  (same harmonic function)")
  local dia = get_diatonic_subs(chord_root)
  if #dia == 0 then
    reaper.ImGui_TextDisabled(ctx, "  (no other degree shares this function)")
  else
    for si, s in ipairs(dia) do
      sub_item(s, "dia:" .. si)
    end
  end

  reaper.ImGui_Separator(ctx)

  -- ---- 4. Modal Borrowing ----
  reaper.ImGui_TextDisabled(ctx, "Modal Borrowing")
  local bor = get_modal_borrowing_subs(chord_root)
  if #bor == 0 then
    reaper.ImGui_TextDisabled(ctx, "  (none available)")
  else
    for si, s in ipairs(bor) do
      sub_item(s, "bor:" .. si)
    end
  end
end

-- ============================================================
-- SECTION 9 — CIRCLE OF FIFTHS — GEOMETRY & RENDERING
-- ============================================================
local CHILD_W   = 320
local CHILD_H   = 320
local CX        = CHILD_W / 2
local CY        = CHILD_H / 2

local R_OUT_MAX = 148
local R_OUT_MIN = 108
local R_MID_MIN = 68
local R_OUT_LBL = 128
local R_MID_LBL = 88

local minor_rel_names    = {"Am","Em","Bm","F#m","C#m","G#m","D#m","A#m","Fm","Cm","Gm","Dm"}
local rel_minor_root_idx = {4, 5, 6, 7, 8, 9, 10, 11, 12, 1, 2, 3}

local SECTOR_A = 0x1E4A8AFF
local SECTOR_B = 0x153A72FF
local INNER_A  = 0x2A6090FF
local INNER_B  = 0x1E5080FF
local SEL_OUT  = 0x3A8FCFFF
local SEL_IN   = 0x2A70AAFF
local COL_TEXT = 0xE8F4FFFF
local COL_BDR  = 0x4A7AABFF
local COL_CTR  = 0x0A1830FF
local COL_CTXT = 0xB0D4F0FF

function draw_annular_sector(dl, cx, cy, r_min, r_max, a0, a1, color, steps)
  steps  = steps or 10
  local da = (a1 - a0) / steps
  for s = 0, steps - 1 do
    local ta = a0 + s * da
    local tb = ta + da
    local ca, sa = math.cos(ta), math.sin(ta)
    local cb, sb = math.cos(tb), math.sin(tb)
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      cx + r_min * ca, cy + r_min * sa,
      cx + r_max * ca, cy + r_max * sa,
      cx + r_max * cb, cy + r_max * sb, color)
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      cx + r_min * ca, cy + r_min * sa,
      cx + r_max * cb, cy + r_max * sb,
      cx + r_min * cb, cy + r_min * sb, color)
  end
end

-- ============================================================
-- SECTION 10 — CIRCLE DRAWING
-- ============================================================
function draw_circle_of_fifths()
  local dl     = reaper.ImGui_GetWindowDrawList(ctx)
  local wx, wy = reaper.ImGui_GetWindowPos(ctx)
  local abs_cx = wx + CX
  local abs_cy = wy + CY

  local slice = 2 * math.pi / 12
  local half  = slice / 2
  local GAP   = 0.025

  reaper.ImGui_DrawList_AddCircleFilled(dl, abs_cx, abs_cy, R_OUT_MAX, 0x0A1A3AFF, 64)

  for i = 1, 12 do
    local ac  = (i - 1) * slice - math.pi / 2
    local a0  = ac - half + GAP
    local a1  = ac + half - GAP
    local sel = (selected_sector_idx == i)

    local co = sel and SEL_OUT or (i % 2 == 0 and SECTOR_B or SECTOR_A)
    draw_annular_sector(dl, abs_cx, abs_cy, R_OUT_MIN, R_OUT_MAX, a0, a1, co)

    local ci = sel and SEL_IN or (i % 2 == 0 and INNER_B or INNER_A)
    draw_annular_sector(dl, abs_cx, abs_cy, R_MID_MIN, R_OUT_MIN, a0, a1, ci)

    reaper.ImGui_DrawList_AddLine(dl,
      abs_cx + R_MID_MIN * math.cos(ac - half),
      abs_cy + R_MID_MIN * math.sin(ac - half),
      abs_cx + R_OUT_MAX * math.cos(ac - half),
      abs_cy + R_OUT_MAX * math.sin(ac - half),
      COL_BDR, 1.2)
  end

  reaper.ImGui_DrawList_AddCircleFilled(dl, abs_cx, abs_cy, R_MID_MIN - 1, COL_CTR, 64)
  reaper.ImGui_DrawList_AddCircle(dl, abs_cx, abs_cy, R_OUT_MAX, COL_BDR, 64, 2)
  reaper.ImGui_DrawList_AddCircle(dl, abs_cx, abs_cy, R_OUT_MIN, COL_BDR, 64, 1)
  reaper.ImGui_DrawList_AddCircle(dl, abs_cx, abs_cy, R_MID_MIN, COL_BDR, 64, 1)

  local sel_note = note_names[circle_fifths[selected_root_idx] + 1]
  local sel_mode = is_minor_mode and "m" or "M"
  local lbl_ctr  = sel_note .. sel_mode
  reaper.ImGui_DrawList_AddText(dl,
    abs_cx - #lbl_ctr * 3.5, abs_cy - 7, COL_CTXT, lbl_ctr)

  for i = 1, 12 do
    local ac  = (i - 1) * slice - math.pi / 2
    local maj = note_names[circle_fifths[i] + 1]
    reaper.ImGui_DrawList_AddText(dl,
      abs_cx + R_OUT_LBL * math.cos(ac) - #maj * 3.5,
      abs_cy + R_OUT_LBL * math.sin(ac) - 7,
      COL_TEXT, maj)
    local mnm = minor_rel_names[i]
    reaper.ImGui_DrawList_AddText(dl,
      abs_cx + R_MID_LBL * math.cos(ac) - #mnm * 3.0,
      abs_cy + R_MID_LBL * math.sin(ac) - 6,
      0xDDEEFFFF, mnm)
  end

  local CB  = reaper.ImGui_Col_Button()
  local CBH = reaper.ImGui_Col_ButtonHovered()
  local CBA = reaper.ImGui_Col_ButtonActive()
  local BW, BH = 30, 24

  reaper.ImGui_PushStyleColor(ctx, CB,  0x00000000)
  reaper.ImGui_PushStyleColor(ctx, CBH, 0x33FFFFFF55)
  reaper.ImGui_PushStyleColor(ctx, CBA, 0x55FFFFFF77)

  for i = 1, 12 do
    local ac = (i - 1) * slice - math.pi / 2

    reaper.ImGui_SetCursorPos(ctx,
      CX + R_OUT_LBL * math.cos(ac) - BW / 2,
      CY + R_OUT_LBL * math.sin(ac) - BH / 2)
    if reaper.ImGui_Button(ctx, "##M" .. i, BW, BH) then
      selected_root_idx   = i
      selected_sector_idx = i
      is_minor_mode       = false
      last_bass           = -1
    end

    reaper.ImGui_SetCursorPos(ctx,
      CX + R_MID_LBL * math.cos(ac) - BW / 2,
      CY + R_MID_LBL * math.sin(ac) - BH / 2)
    if reaper.ImGui_Button(ctx, "##m" .. i, BW, BH) then
      selected_root_idx   = rel_minor_root_idx[i]
      selected_sector_idx = i
      is_minor_mode       = true
      last_bass           = -1
    end
  end

  reaper.ImGui_PopStyleColor(ctx, 3)
  reaper.ImGui_SetCursorPos(ctx, CHILD_W - 1, CHILD_H - 1)
  reaper.ImGui_Dummy(ctx, 1, 1)
end

-- ============================================================
-- SECTION 11 — MAIN LOOP
-- ============================================================
function loop()
  local wf = reaper.ImGui_WindowFlags_AlwaysAutoResize()

  local N_COLORS = 24
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(),          0x0D1B2AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(),           0x0A1628FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(),     0x0F2040FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgCollapsed(),  0x0A1628AA)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),            0x1E3F6FFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),     0x2E5A9CFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),      0x4080C8FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),           0x0F2540FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(),    0x1A3860FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),     0x254E80FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),            0x1E3F6FCC)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(),     0x2E5A9CFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),      0x4080C8FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),              0xD0E4F7FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TextDisabled(),      0x5A7A9AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(),         0x2A4A70FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SeparatorHovered(),  0x4080C8FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SeparatorActive(),   0x4080C8FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(),         0x5BA8E8FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrab(),        0x3A6AABFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrabActive(),  0x5BA8E8FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarBg(),       0x0A1A30FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrab(),     0x1E3F6FFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(),           0x0D1B2AEF)

  -- ---- Listen Mode: tick the timer every frame ----
  -- Must run before Begin() so that Note Off fires even when the
  -- window is not hovered.
  if listen_mode then listen_tick() end

  local visible, open = reaper.ImGui_Begin(ctx, 'SK Harmonic Compass', true, wf)

  if visible then

    -- ---- SECTION 1: Parameters ----
    reaper.ImGui_Text(ctx, "1. PARAMETERS")

    if reaper.ImGui_RadioButton(ctx, "Major", not is_minor_mode) then
      is_minor_mode = false
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "Minor", is_minor_mode) then
      is_minor_mode = true
    end

    -- ---- Listen Mode toggle button ----
    -- Rendered on the same line as Major/Minor to save vertical space.
    -- Button is green when active, standard colour when inactive.
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_SameLine(ctx)

    if listen_mode then
      -- Active state: bright green tint.
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x2A8040FF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x3AAA55FF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x50CC70FF)
      if reaper.ImGui_Button(ctx, "  Listen ON  ##listen", 0, 0) then
        -- Toggle OFF: silence any ringing notes and restore track state.
        listen_note_off()
        listen_hovered_deg = nil
        listen_restore_track()
        listen_mode = false
      end
      reaper.ImGui_PopStyleColor(ctx, 3)
    else
      if reaper.ImGui_Button(ctx, " Listen OFF ##listen", 0, 0) then
        -- Toggle ON: arm the selected track and enable monitoring.
        local track = reaper.GetSelectedTrack(0, 0)
        if not track then
          reaper.ShowMessageBox(
            "Please select a track before enabling Listen mode.", "Error", 0)
        else
          listen_arm_track(track)
          listen_hovered_deg = nil
          listen_mode        = true
        end
      end
    end

    if reaper.ImGui_IsItemHovered(ctx) then
      reaper.ImGui_BeginTooltip(ctx)
        reaper.ImGui_Text(ctx, "Listen Mode — hover a degree button to preview the chord")
        reaper.ImGui_Text(ctx, "Arms the selected track and enables input monitoring.")
        reaper.ImGui_Text(ctx, "Toggle off to restore the original track state.")
      reaper.ImGui_EndTooltip(ctx)
    end

    reaper.ImGui_SetNextItemWidth(ctx, 175)
    if is_minor_mode then
      local cm, nm = reaper.ImGui_Combo(ctx, "Mode", minor_mode_idx - 1, MINOR_MODE_COMBO_STR)
      if cm then minor_mode_idx = nm + 1; last_bass = -1 end
    else
      local cm, nm = reaper.ImGui_Combo(ctx, "Mode", major_mode_idx - 1, MAJOR_MODE_COMBO_STR)
      if cm then major_mode_idx = nm + 1; last_bass = -1 end
    end

    -- ---- Duration button bar ----
    reaper.ImGui_Text(ctx, "Duration:")
    reaper.ImGui_SameLine(ctx)
    for i = 1, #duration_names do
      local is_sel = (duration_idx == i)
      if is_sel then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x4080C8FF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x50A0E0FF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x60B8F8FF)
      end
      if reaper.ImGui_Button(ctx, duration_icons[i] .. "##dur" .. i, 34, 22) then
        duration_idx = i
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_BeginTooltip(ctx)
          reaper.ImGui_Text(ctx, duration_names[i])
        reaper.ImGui_EndTooltip(ctx)
      end
      if is_sel then reaper.ImGui_PopStyleColor(ctx, 3) end
      if i < #duration_names then reaper.ImGui_SameLine(ctx) end
    end

    reaper.ImGui_SetNextItemWidth(ctx, 175)
    local co, no = reaper.ImGui_SliderInt(ctx, "Octave", octave, 1, 7)
    if co then octave = no end

    reaper.ImGui_SetNextItemWidth(ctx, 175)
    local cp, np = reaper.ImGui_Combo(ctx, "Pattern", pattern_idx - 1, PATTERN_COMBO_STR)
    if cp then pattern_idx = np + 1 end

    -- ---- Humanization button bar ----
    reaper.ImGui_Text(ctx, "Humanize:")
    reaper.ImGui_SameLine(ctx)
    local hum_labels = { "Off", "Med", "High" }
    local hum_tips   = {
      "No humanization — perfectly quantized",
      "Subtle: timing ±1/64, velocity ±6",
      "Expressive: timing ±1/32, velocity ±12",
    }
    for i = 1, 3 do
      local is_sel = (humanize_idx == i)
      if is_sel then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x4080C8FF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x50A0E0FF)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x60B8F8FF)
      end
      if reaper.ImGui_Button(ctx, hum_labels[i] .. "##hum" .. i, 44, 22) then
        humanize_idx = i
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_BeginTooltip(ctx)
          reaper.ImGui_Text(ctx, hum_tips[i])
        reaper.ImGui_EndTooltip(ctx)
      end
      if is_sel then reaper.ImGui_PopStyleColor(ctx, 3) end
      if i < 3 then reaper.ImGui_SameLine(ctx) end
    end

    reaper.ImGui_Separator(ctx)

    -- ---- SECTION 2: Circle of Fifths ----
    reaper.ImGui_Text(ctx, "2. KEY  [outer = Major  |  inner = Relative minor]")

    local mods     = reaper.ImGui_GetKeyMods(ctx)
    local is_shift = (mods & reaper.ImGui_Mod_Shift()) ~= 0

    local child_flags  = reaper.ImGui_ChildFlags_None and reaper.ImGui_ChildFlags_None() or 0
    local window_flags = reaper.ImGui_WindowFlags_NoScrollbar()
                       | reaper.ImGui_WindowFlags_NoScrollWithMouse()

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), 0x00000000)
    local child_ok = reaper.ImGui_BeginChild(
      ctx, "##circle", CHILD_W, CHILD_H, child_flags, window_flags)
    reaper.ImGui_PopStyleColor(ctx, 1)

    if child_ok then draw_circle_of_fifths() end
    reaper.ImGui_EndChild(ctx)

    reaper.ImGui_Separator(ctx)

    -- ---- SECTION 3: Scale Degrees ----
    local sel_note_name = note_names[circle_fifths[selected_root_idx] + 1]
    local mode_label    = is_minor_mode
                          and minor_modes[minor_mode_idx].name
                          or  major_modes[major_mode_idx].name

    reaper.ImGui_Text(ctx,
      "3. DEGREES  —  " .. sel_note_name .. " " .. mode_label ..
      "     [L-Click = insert  |  R-Click = substitutions  |  Shift+L = neg. harmony]")

    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local cc, nc = reaper.ImGui_Combo(ctx, "Color", color_idx - 1, COLOR_COMBO_STR)
    if cc then color_idx = nc + 1 end

    local ca, new_auto = reaper.ImGui_Checkbox(
      ctx, "Auto voicing (voice leading)", not voicing_override)
    if ca then
      voicing_override = not new_auto
      last_bass        = -1
    end
    if not voicing_override then
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Reset bass##rb", 80, 0) then
        last_bass = -1
      end
    end

    if voicing_override then
      reaper.ImGui_SetNextItemWidth(ctx, 200)
      local cv, nv = reaper.ImGui_Combo(ctx, "Voicing", voicing_idx - 1, VOICING_COMBO_STR)
      if cv then voicing_idx = nv + 1 end
    else
      reaper.ImGui_BeginDisabled(ctx, true)
      reaper.ImGui_SetNextItemWidth(ctx, 200)
      reaper.ImGui_Combo(ctx, "Voicing", voicing_idx - 1, VOICING_COMBO_STR)
      reaper.ImGui_EndDisabled(ctx)
    end

    local mm        = is_minor_mode and minor_modes[minor_mode_idx]
                                     or  major_modes[major_mode_idx]
    local deg_names = mm.degrees
    local deg_ivs   = mm.ivs
    local deg_types = mm.types
    local root_tonality = circle_fifths[selected_root_idx]

    -- ---- Degree buttons ----
    -- Left-click        → insert chord.
    -- Right-click       → substitution context menu.
    -- Hover (Listen ON) → preview chord via StuffMIDIMessage.
    for i = 1, 7 do
      local chord_root = (root_tonality + deg_ivs[i]) % 12
      local cidx       = get_chord_idx(deg_types[i], color_idx)
      local chord_name = chords[cidx][1]
      local root_name  = note_names[chord_root + 1]
      local lbl        = deg_names[i] .. "\n" .. root_name .. chord_name
      local popup_id   = "subpopup" .. i

      reaper.ImGui_PushID(ctx, i)

      -- Left click → insert.
      if reaper.ImGui_Button(ctx, lbl, 60, 44) then
        insert_chord_custom(chord_root, chords[cidx][2], is_shift)
      end

      -- Right click → substitution popup.
      if reaper.ImGui_BeginPopupContextItem(ctx, popup_id) then
        render_substitution_content(chord_root, deg_types[i], cidx, deg_names[i])
        reaper.ImGui_EndPopup(ctx)
      end

      -- ---- Listen Mode: hover detection ----
      -- Re-triggers when: (a) the hovered degree changes, OR
      --                   (b) the Shift key state toggles (normal ↔ negative harmony).
      -- Entering a degree button clears listen_hovered_sub so that returning
      -- from the substitution popup re-triggers the degree preview correctly.
      if listen_mode and reaper.ImGui_IsItemHovered(ctx) then
        if listen_hovered_deg ~= i or listen_hovered_shift ~= is_shift then
          listen_hovered_deg   = i
          listen_hovered_shift = is_shift
          listen_hovered_sub   = nil   -- Clear sub tracker on degree entry.
          local voiced
          if is_shift then
            voiced = get_voiced_notes_for_preview_neg(chord_root, chords[cidx][2])
          else
            voiced = get_voiced_notes_for_preview(chord_root, chords[cidx][2])
          end
          listen_note_on(voiced)
        end
      end

      reaper.ImGui_PopID(ctx)

      -- Hover tooltip (always shown, Listen mode or not).
      if reaper.ImGui_IsItemHovered(ctx) then
        local full_name, note_list = get_chord_display(
          chord_root, chord_name, chords[cidx][2], false)
        local neg_name, neg_list = get_chord_display(
          chord_root, chord_name, chords[cidx][2], true)
        reaper.ImGui_BeginTooltip(ctx)
          reaper.ImGui_Text(ctx,
            full_name .. " :  " .. table.concat(note_list, " - "))
          reaper.ImGui_Text(ctx,
            "Neg : " .. neg_name .. "  " .. table.concat(neg_list, " - "))
          reaper.ImGui_Text(ctx,
            "L-Click = insert  |  R-Click = substitutions  |  Shift+L = neg. harmony")
        reaper.ImGui_EndTooltip(ctx)
      end

      if i < 7 then reaper.ImGui_SameLine(ctx) end
    end

    reaper.ImGui_End(ctx)
  else
    reaper.ImGui_End(ctx)
  end

  reaper.ImGui_PopStyleColor(ctx, N_COLORS)

  if open then
    reaper.defer(loop)
  else
    -- Window closed: ensure notes are silenced and track state restored.
    listen_note_off()
    listen_restore_track()
  end
end

reaper.defer(loop)
