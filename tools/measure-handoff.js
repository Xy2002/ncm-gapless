// Temporary diagnostic seam: actual patch engine, bounded metadata only.
(() => {
  if (window.__ncmHandoffMeasurement) throw new Error('MEASUREMENT_ALREADY_ACTIVE');
  const prototype = window.NcmGaplessEngine.Engine.prototype;
  const position = prototype.position;
  let engine;
  prototype.position = function () { engine = this; return position.apply(this, arguments); };
  try { window.NcmGapless.status(); } finally { prototype.position = position; }
  if (!engine?.current || !engine.next) throw new Error('PREPARED_PAIR_REQUIRED');
  const rate = engine.context.sampleRate, tail = 2.5, head = 3;
  const events = [], restores = [];
  const snapshot = (name, value) => {
    if (events.length >= 150) return;
    events.push({ name, value, time: engine.context.currentTime, wall: performance.now(), state: engine.context.state,
      start: engine.current?.start, end: engine.current?.end, offset: engine.current?.offset });
  };
  const a = engine.current, b = engine.next;
  const sample = (entry, offset, seconds) => {
    const output = new Float32Array(Math.floor(seconds * rate));
    const channels = Array.from({ length: entry.buffer.numberOfChannels }, (_, c) => entry.buffer.getChannelData(c));
    const gain = Math.pow(10, (Number(entry.info?.volumeDelta) || 0) / 20);
    for (let i = 0; i < output.length; i++) {
      const index = (offset + i / rate) * entry.buffer.sampleRate, lower = Math.floor(index), fraction = index - lower;
      for (const data of channels) output[i] += ((data[lower] || 0) * (1 - fraction) + (data[lower + 1] || 0) * fraction) * gain / channels.length;
    }
    const bytes = new Uint8Array(output.buffer); let binary = '';
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary);
  };
  const reference = { rate, tail, head, a: sample(a, a.buffer.duration - tail, tail), b: sample(b, 0, head) };
  for (const name of ['play', 'pause', 'seek', 'setRate', 'load', 'clear', 'queue', 'cancelNext']) {
    const descriptor = Object.getOwnPropertyDescriptor(engine, name), original = engine[name];
    engine[name] = function (...args) {
      snapshot(name, ['seek', 'setRate'].includes(name) ? args[0] : undefined);
      return original.apply(this, args);
    };
    restores.push(() => {
      if (descriptor) Object.defineProperty(engine, name, descriptor); else delete engine[name];
    });
  }
  window.__ncmHandoffMeasurement = { engine, events, restores, reference,
    result() { return { events: events.slice(0, 150), reference, status: window.NcmGapless.status() }; },
    cleanup() { restores.forEach(restore => restore()); delete window.__ncmHandoffMeasurement; } };
  return { armed: true, nextReady: true, sampleRate: engine.context.sampleRate };
})()
