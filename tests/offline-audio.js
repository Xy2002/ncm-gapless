/* Runs against the ACTUAL target client's OfflineAudioContext without sound. */
async function verifyGaplessCore(core) {
  const cases = [];
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  const lengths = [4093, 6149, 8191]; // Boundaries intentionally miss render quanta.
  const totalFrames = lengths.reduce((sum, frames) => sum + frames, 0);
  const sample = (frame, channel) => Math.fround(0.32 * Math.sin(frame * 0.103 + channel) + 0.13 * Math.cos(frame * 0.017));

  for (const rate of [44100, 48000, 96000]) {
    const startFrame = 137;
    const context = new OfflineAudioContext(2, startFrame + totalFrames + 128, rate);
    let offset = 0;
    const tracks = lengths.map(length => {
      const buffer = context.createBuffer(2, length, rate);
      for (let channel = 0; channel < 2; channel++) {
        const data = buffer.getChannelData(channel);
        for (let index = 0; index < length; index++) data[index] = sample(offset + index, channel);
      }
      offset += length;
      return { buffer };
    });
    const scheduled = core.schedule(context, tracks, { startFrame });
    const result = await context.startRendering();
    let maxError = 0;
    for (let channel = 0; channel < 2; channel++) {
      const actual = result.getChannelData(channel);
      for (let frame = 0; frame < actual.length; frame++) {
        const expected = frame < startFrame || frame >= startFrame + totalFrames ? 0 : sample(frame - startFrame, channel);
        maxError = Math.max(maxError, Math.abs(actual[frame] - expected));
      }
    }
    assert(maxError <= 0.000001, 'PCM mismatch at ' + rate + ': ' + maxError);
    assert(scheduled.frames === totalFrames, 'Scheduled length differs');
    cases.push({ name: 'sample-continuity-' + rate, pass: true, channels: 2,
      frames: totalFrames, boundaryFrames: scheduled.plan.slice(1).map(item => item.startFrame), maxError });
  }

  // An authored pause is part of the music and must survive untouched.
  {
    const context = new OfflineAudioContext(1, 1000, 48000);
    const first = context.createBuffer(1, 500, 48000);
    const second = context.createBuffer(1, 500, 48000);
    first.getChannelData(0).fill(0.2, 0, 450);
    second.getChannelData(0).fill(0.3, 50);
    core.schedule(context, [{ buffer: first }, { buffer: second }], { startFrame: 0 });
    const data = (await context.startRendering()).getChannelData(0);
    assert(data.slice(450, 550).every(value => value === 0), 'Authored silence removed');
    assert(data[449] > 0 && data[550] > 0, 'Music around silence changed');
    cases.push({ name: 'preserve-authored-silence', pass: true, silenceFrames: 100 });
  }

  // Explicit codec padding is removed without inspecting content loudness.
  {
    const context = new OfflineAudioContext(1, 256, 48000);
    const first = context.createBuffer(1, 180, 48000);
    first.getChannelData(0).fill(0.25, 10, 138);
    const second = context.createBuffer(1, 200, 48000);
    second.getChannelData(0).fill(0.5, 20, 148);
    core.schedule(context, [
      { buffer: first, trimStartFrames: 10, trimEndFrames: 42 },
      { buffer: second, trimStartFrames: 20, trimEndFrames: 52 },
    ], { startFrame: 0 });
    const data = (await context.startRendering()).getChannelData(0);
    assert(data.slice(0, 128).every(value => value === 0.25) && data.slice(128).every(value => value === 0.5), 'Codec padding remains');
    cases.push({ name: 'explicit-codec-trim', pass: true, frames: data.length });
  }

  // Demonstrate that our sample comparison catches both a gap and an overlap.
  for (const delta of [32, -32]) {
    const context = new OfflineAudioContext(1, 1024 + Math.max(delta, 0), 48000);
    for (const offset of [0, 512 + delta]) {
      const source = context.createBufferSource();
      source.buffer = context.createBuffer(1, 512, 48000);
      source.buffer.getChannelData(0).fill(0.25);
      source.connect(context.destination);
      source.start(offset / 48000);
    }
    const data = (await context.startRendering()).getChannelData(0);
    const differs = data.some((value, frame) => Math.abs(value - (frame < 1024 ? 0.25 : 0)) > 0.000001);
    assert(differs, 'Negative control did not detect a faulty transition');
    cases.push({ name: delta > 0 ? 'detect-inserted-gap' : 'detect-overlap', pass: true, deliberatelyWrongFrames: delta });
  }

  {
    const context = new OfflineAudioContext(1, 1024, 48000);
    const valid = context.createBuffer(1, 512, 48000);
    let rejected = false;
    try { core.schedule(context, [{ buffer: valid }, { buffer: valid, trimEndFrames: 512 }], { startFrame: 0 }); }
    catch (_) { rejected = true; }
    assert(rejected, 'Invalid trim accepted');
    const output = (await context.startRendering()).getChannelData(0);
    assert(output.every(value => value === 0), 'Partial sequence started before validation');
    cases.push({ name: 'invalid-sequence-plays-nothing', pass: true });
  }

  return { pass: cases.every(item => item.pass), cases };
}
