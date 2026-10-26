// Exercise the real controller and engine with controlled I/O and audio nodes.
// No client, network request, sound device, or wall-clock timer is used.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../..');
const flush = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };

function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function fixture({ phase = 'fetch' } = {}) {
  let clock = 0, nextTimer = 0;
  const timers = new Map();
  const schedule = (callback, delay, repeat) => {
    const id = ++nextTimer;
    timers.set(id, { callback, time: clock + Math.max(0, delay || 0), repeat });
    return id;
  };
  const fetched = deferred(), decoded = deferred();
  const nativeCalls = [], events = [], restorations = [], actions = [], starts = [], requests = [];
  const track = { id: 'fixture-track' };
  const state = { playing: { playId: 'fixture-play', curPlaying: track, playingVolume: .5, playingSpeed: 1 },
    playingList: { curPlayingList: [] }, setting: { quantity: {} } };
  const buffer = { length: 48000, sampleRate: 48000, numberOfChannels: 2, duration: 1 };
  const contexts = [];
  class AudioContext {
    constructor() { this.sampleRate = 48000; this.state = 'suspended'; this.currentTime = 0; this.destination = { channelCount: 2 }; contexts.push(this); }
    createGain() { return { gain: { value: 1, setValueAtTime() {} }, connect() {}, disconnect() {} }; }
    createBufferSource() { return { playbackRate: { value: 1 }, connect() {}, disconnect() {}, start(...args) { starts.push(args); }, stop() {} }; }
    async resume() { this.state = 'running'; }
    async suspend() { this.state = 'suspended'; }
    async close() { this.state = 'closed'; }
    async decodeAudioData() { return phase === 'decode' ? decoded.promise : buffer; }
  }
  const originalCall = (name, callback, args) => { nativeCalls.push({ name, args }); callback?.(); };
  const sandbox = { URL, AbortController, AudioContext,
    setTimeout: (callback, delay) => schedule(callback, delay, 0), clearTimeout: id => timers.delete(id),
    setInterval: (callback, delay) => schedule(callback, delay, delay), clearInterval: id => timers.delete(id),
    channel: { call: originalCall } };
  const client = { version: 'fixture', getState: () => state, subscribe: () => () => {}, nextInfo: async () => null,
    callNative: originalCall,
    intercept(handler) {
      sandbox.channel.call = (name, callback, args) => handler(name, callback, args, originalCall);
      return () => { sandbox.channel.call = originalCall; };
    },
    store: { dispatch(action) { actions.push(action); } },
    async restorePlayback(item, position, wasPlaying, info, pending) {
      restorations.push({ item, position, wasPlaying, info, pending, bridgeRestored: sandbox.channel.call === originalCall });
    },
    emit(name, ...args) {
      events.push({ name, args });
      if (name === 'Load') sandbox.channel.call('audioplayer.play', () => {}, ['fixture-play', 'after-load']);
    } };
  sandbox.NcmGaplessClient = { discover: () => client };
  sandbox.fetch = (url, { signal }) => {
    requests.push({ signal });
    signal.addEventListener('abort', () => fetched.reject(Object.assign(new Error('CANCELLED'), { name: 'AbortError' })), { once: true });
    return fetched.promise;
  };
  vm.createContext(sandbox);
  for (const file of ['gapless-engine.js', 'netease-gapless.js']) vm.runInContext(fs.readFileSync(path.join(root, 'src', file), 'utf8'), sandbox);
  sandbox.NcmGapless.install();
  const call = (command, id = 'fixture-play') => {
    let acknowledged = false;
    sandbox.channel.call('audioplayer.' + command, () => { acknowledged = true; }, [id, 'request']);
    return acknowledged;
  };
  const releaseFetch = () => fetched.resolve({ ok: true, headers: { get: () => null }, body: { getReader() {
    let done = false;
    return { async read() { if (done) return { done: true }; done = true; return { done: false, value: new Uint8Array(8) }; } };
  } } });
  return { sandbox, nativeCalls, events, restorations, actions, starts, requests, contexts, timers, track, call, flush,
    begin() { sandbox.channel.call('audioplayer.load', () => {}, ['fixture-play', { songId: 'fixture-track', musicurl: 'https://music.126.net/synthetic.wav' }]); },
    async enterPhase() { if (phase === 'decode') { releaseFetch(); await flush(); } },
    async finish() { releaseFetch(); decoded.resolve(buffer); await flush(); },
    async advance(milliseconds) {
      const target = clock + milliseconds;
      for (;;) {
        const next = [...timers].filter(([, timer]) => timer.time <= target).sort((a, b) => a[1].time - b[1].time)[0];
        if (!next) break;
        const [id, timer] = next; clock = timer.time;
        if (timer.repeat) timer.time += timer.repeat; else timers.delete(id);
        timer.callback(); await flush();
      }
      clock = target;
    },
    async close() { await sandbox.NcmGapless.uninstall(); await this.finish(); } };
}

module.exports = { fixture };
