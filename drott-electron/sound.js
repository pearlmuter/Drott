// sound.js — synthesised sound effects via Web Audio API (no asset files)
;(function() {
const D = (typeof window !== 'undefined' ? window : globalThis).D =
  (typeof window !== 'undefined' ? window : globalThis).D || {};

let _ctx = null;
D.muted = false;

function ac() {
  if (!_ctx) _ctx = new (window.AudioContext || window.webkitAudioContext)();
  if (_ctx.state === 'suspended') _ctx.resume();
  return _ctx;
}

function noise(a, dur) {
  const buf = a.createBuffer(1, Math.ceil(a.sampleRate * dur), a.sampleRate);
  const d = buf.getChannelData(0);
  for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
  const src = a.createBufferSource();
  src.buffer = buf;
  return src;
}

// Bright wooden klack — piece placed / moved
function playMove(a) {
  const t = a.currentTime;

  // Tonal click: high pitch drops fast → gives the "klack" character
  const osc = a.createOscillator();
  osc.type = 'sine';
  osc.frequency.setValueAtTime(1050, t);
  osc.frequency.exponentialRampToValueAtTime(240, t + 0.018);
  const og = a.createGain();
  og.gain.setValueAtTime(0.38, t);
  og.gain.exponentialRampToValueAtTime(0.001, t + 0.042);
  osc.connect(og); og.connect(a.destination);
  osc.start(t); osc.stop(t + 0.05);

  // Short high-band noise burst for the crisp attack click
  const n = noise(a, 0.012);
  const bpf = a.createBiquadFilter();
  bpf.type = 'bandpass'; bpf.frequency.value = 1400; bpf.Q.value = 1.2;
  const ng = a.createGain();
  ng.gain.setValueAtTime(0.35, t);
  ng.gain.exponentialRampToValueAtTime(0.001, t + 0.012);
  n.connect(bpf); bpf.connect(ng); ng.connect(a.destination);
  n.start(t);
}

// Sharper crack — piece captured
function playCapture(a) {
  const t = a.currentTime;

  // Bright transient: sawtooth into bandpass, pitch falls fast
  const osc = a.createOscillator();
  osc.type = 'sawtooth';
  osc.frequency.setValueAtTime(420, t);
  osc.frequency.exponentialRampToValueAtTime(75, t + 0.055);
  const bpf = a.createBiquadFilter();
  bpf.type = 'bandpass'; bpf.frequency.value = 900; bpf.Q.value = 0.7;
  const og = a.createGain();
  og.gain.setValueAtTime(0.55, t);
  og.gain.exponentialRampToValueAtTime(0.001, t + 0.11);
  osc.connect(bpf); bpf.connect(og); og.connect(a.destination);
  osc.start(t); osc.stop(t + 0.15);

  // High crack noise on the attack
  const n = noise(a, 0.025);
  const hpf = a.createBiquadFilter();
  hpf.type = 'highpass'; hpf.frequency.value = 1100;
  const ng = a.createGain();
  ng.gain.setValueAtTime(0.65, t);
  ng.gain.exponentialRampToValueAtTime(0.001, t + 0.025);
  n.connect(hpf); hpf.connect(ng); ng.connect(a.destination);
  n.start(t);
}

D.playSound = function(type) {
  if (D.muted) return;
  try {
    const a = ac();
    if (type === 'capture') playCapture(a);
    else playMove(a);
  } catch (_) {}
};

D.toggleMute = function() {
  D.muted = !D.muted;
  const btn = document.getElementById('mute-btn');
  if (btn) btn.classList.toggle('active', D.muted);
};

if (typeof module !== 'undefined' && module.exports) module.exports = {};
})();
