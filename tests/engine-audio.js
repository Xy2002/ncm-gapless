async function verifyEngineAndAdapter(engineModule, adapterModule) {
  const assert = (value, message) => { if (!value) throw new Error(message); };
  const cases = [];
  for (const operation of ['adjacent', 'cancel-queued', 'seek', 'pause-resume', 'same-rate-during-second-track']) {
    const sampleRate = 44100, offset = operation === 'seek' ? 307 : 0;
    const aLength = 4093, bLength = operation === 'same-rate-during-second-track' ? 30017 : 6149, length = aLength - offset + bLength;
    const raw = new OfflineAudioContext(2, length + 5000, sampleRate);
    // OfflineAudioContext owns the real decoder/render graph. Only transport
    // suspend/resume is adapted because offline rendering has no wall clock.
    const context = { sampleRate, get currentTime() { return raw.currentTime; }, get state() { return raw.state; },
      destination: raw.destination, createGain: () => raw.createGain(), createBufferSource: () => raw.createBufferSource(),
      resume: async () => {}, suspend: async () => {}, close: async () => {} };
    const signal = (frame, channel) => Math.fround(Math.sin(frame * 0.073 + channel) * 0.3 + 0.11);
    const make = (frames, base, constant) => {
      const buffer = raw.createBuffer(2, frames, sampleRate);
      for (let channel = 0; channel < 2; channel++) for (let frame = 0; frame < frames; frame++) buffer.getChannelData(channel)[frame] = constant === undefined ? signal(base + frame, channel) : constant;
      return { buffer, info: {} };
    };
    const first = make(aLength, 0), second = make(bLength, aLength);
    const boundaries = [];
    const engine = new engineModule.Engine(context, { onBoundary: (a, b) => { if (b) boundaries.push(Math.round((b.start - a.end) * sampleRate)); } });
    engine.load(first);
    if (operation === 'cancel-queued') engine.queue(make(bLength, 0, -0.8)); else engine.queue(second);
    await engine.play();
    if (operation === 'cancel-queued') { engine.cancelNext(); engine.queue(second); }
    if (operation === 'seek') await engine.seek(offset / sampleRate);
    if (operation === 'pause-resume') { await engine.pause(); await engine.play(); }
    const start = Math.round(first.start * sampleRate);
    let reapply;
    if (operation === 'same-rate-during-second-track') {
      const frame = Math.ceil((second.start * sampleRate + 0.13 * sampleRate) / 128) * 128;
      reapply = raw.suspend(frame / sampleRate).then(async () => {
        assert(engine.current === second, 'Regression must reach the second track');
        await engine.setRate(1); // The official SDK reapplies the current rate at every handoff.
        await raw.resume();
      });
    }
    const output = await raw.startRendering();
    if (reapply) await reapply;
    let maxError = 0;
    for (let channel = 0; channel < 2; channel++) {
      const data = output.getChannelData(channel);
      for (let frame = 0; frame < data.length; frame++) {
        const local = frame - start;
        const expected = local < 0 || local >= length ? 0 : signal(local + offset, channel);
        maxError = Math.max(maxError, Math.abs(data[frame] - expected));
      }
    }
    assert(maxError < 0.000001, operation + ' altered rendered PCM: ' + maxError);
    assert(boundaries.length === 1 && boundaries[0] === 0, operation + ' boundary callback wrong');
    cases.push({ name: 'engine-' + operation, pass: true, maxError, boundaryDeltaFrames: boundaries[0] });
  }

  const client = adapterModule.discover(window);
  const key = 'audioplayer.onGaplessContractProbe';
  const adapters = [client.sdk.Bridge._Adapter, window.legacyNativeCmder?._envAdapter].filter(Boolean);
  const snapshots = adapters.map(adapter => ({ adapter, callback: Object.getOwnPropertyDescriptor(adapter.registerCallMap, key),
    stub: Object.getOwnPropertyDescriptor(adapter.registerCallStubs, key) }));
  const received = [];
  try {
    for (const adapter of adapters) adapter.registerCallMap[key] = (...args) => received.push(args);
    client.emit('GaplessContractProbe', 'fixture', { code: 0 }, 17);
    assert(received.length === adapters.length && received.every(args => args.length === 3 && args[0] === 'fixture' && args[1].code === 0 && args[2] === 17), 'Native event arguments are nested or lost');
    received.length = 0;
    client.sdk.Bridge.triggerRegisterCall('GaplessContractProbe', 'audioplayer', 'fixture', { code: 0 }, 17);
    assert(received.length === 1 && Array.isArray(received[0][0]), 'SDK negative control no longer reproduces argument nesting');
    assert(client.states.Playing === 2 && client.states.Pause === 1, 'Application state contract changed');
    cases.push({ name: 'official-sdk-positional-events', pass: true, consumers: adapters.length, nestedArrayNegativeControl: true });
    cases.push({ name: 'application-versus-native-state', pass: true, applicationPlaying: client.states.Playing, nativePlayingEvent: 1 });
  } finally {
    for (const item of snapshots) {
      if (item.callback) Object.defineProperty(item.adapter.registerCallMap, key, item.callback); else delete item.adapter.registerCallMap[key];
      if (item.stub) Object.defineProperty(item.adapter.registerCallStubs, key, item.stub); else delete item.adapter.registerCallStubs[key];
    }
  }
  return { pass: true, cases, noAudibleTestOutput: true };
}
