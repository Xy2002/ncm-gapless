const test = require('node:test');
const assert = require('node:assert/strict');
const { inspect, prepare } = require('../src/aac-timing.js');
const { timingFixture } = require('./helpers/aac-fixture.cjs');

for (const [name, options] of [
  ['48 kHz / 230 ms integer conversion', {}],
  ['48 kHz / coarse duration equal to the whole sample table', { rows: [[13, 1024]], editDuration: 256 }],
  ['44.1 kHz / 230 ms integer conversion', { sampleRate: 44100 }],
  ['movie ticks containing two source samples', { mediaScale: 24000, movieScale: 24000, editDuration: 5520 }],
]) {
  test(`reject ambiguous full AAC packets: ${name}`, () => {
    const bytes = timingFixture(options), original = Buffer.from(bytes).toString('hex');
    assert.throws(() => prepare(bytes), { message: 'AAC_END_PADDING_AMBIGUOUS' });
    assert.equal(Buffer.from(bytes).toString('hex'), original, 'reject without modifying the input');
  });
}

for (const [name, options, expected, exact] of [
  ['sample-accurate full-packet edit', { movieScale: 48000, editDuration: 11040 }, 11040, true],
  ['finer-than-sample movie scale', { movieScale: 96000, editDuration: 22080 }, 11040, true],
  ['coarse edit with independently precise sample-table tail', { rows: [[11, 1024], [1, 512]], editDuration: 224 }, 10752, true],
  ['rounded coarse edit with precise 44.1 kHz tail', { sampleRate: 44100, rows: [[12, 1024], [1, 123]], editDuration: 258 }, 11387, false],
]) {
  test(`preserve supported AAC timing: ${name}`, () => {
    const bytes = timingFixture(options), original = Buffer.from(bytes).toString('hex');
    const result = prepare(bytes);
    assert.equal(result.metadata.sourceFrames, expected);
    assert.equal(result.metadata.exactMovieTiming, exact);
    assert.equal(inspect(result.bytes).sourceFrames, expected);
    assert.equal(Buffer.from(bytes).toString('hex'), original);
  });
}
