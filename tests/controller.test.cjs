const test = require('node:test');
const assert = require('node:assert/strict');
const { fixture } = require('./helpers/controller-fixture.cjs');

for (const phase of ['fetch', 'decode']) {
  for (const commands of [[], ['pause'], ['pause', 'play']]) {
    test(`uninstall during ${phase} restores native playback after ${commands.join('-') || 'load'}`, async t => {
      const f = fixture({ phase }); t.after(() => f.close()); f.begin(); await f.enterPhase();
      for (const command of commands) assert.equal(f.call(command), true);
      const result = await f.sandbox.NcmGapless.uninstall();
      assert.equal(f.nativeCalls.some(call => call.name === 'audioplayer.stop'), true);
      assert.equal(result.officialPlaybackRestored, true, 'pending takeover must restore the native track');
      assert.equal(f.replays.length, 1);
      assert.equal(f.replays[0].item, f.track);
      assert.equal(f.replays[0].bridgeRestored, true);
      const paused = commands.at(-1) === 'pause';
      assert.equal(f.actions.some(action => action.type === 'playing/pause'), paused, 'restore the latest requested state');
      assert.equal(f.actions.find(action => action.type === 'playing/setPlayingPosition').payload.duration, 0);
      assert.equal(f.requests[0].signal.aborted, true);
      await f.finish();
      assert.equal(f.events.some(event => event.name === 'Load'), false, 'late decode must not restart an uninstalled patch');
      assert.equal(f.starts.length, 0);
      await f.sandbox.NcmGapless.uninstall();
      assert.equal(f.replays.length, 1, 'uninstall remains idempotent');
    });
  }
  for (const commands of [['pause'], ['pause', 'play'], ['pause', 'play', 'pause'], ['pause', 'play', 'pause', 'play']]) {
    test(`latest ${commands.join('-')} request during ${phase} controls decoded playback`, async t => {
      const f = fixture({ phase }); t.after(() => f.close()); f.begin(); await f.enterPhase();
      for (const command of commands) assert.equal(f.call(command), true);
      await f.finish(); await f.advance(40);
      const paused = commands.at(-1) === 'pause';
      assert.equal(f.sandbox.NcmGapless.status().playing, !paused);
      assert.equal(f.events.filter(event => event.name === 'PlayState').at(-1)?.args[2], paused ? 2 : 1);
      assert.equal(f.nativeCalls.some(call => call.name === 'audioplayer.play'), false, 'pending play must not reach the stopped native player');
    });
  }
}

for (const id of ['', { playId: 'fixture-play' }]) {
  test(`pending controls accept ${typeof id === 'object' ? 'object' : 'empty'} play id`, async t => {
    const f = fixture(); t.after(() => f.close()); f.begin(); f.call('pause', id); f.call('play', id);
    await f.finish(); await f.advance(40);
    assert.equal(f.sandbox.NcmGapless.status().playing, true);
    assert.equal(f.nativeCalls.some(call => call.name === 'audioplayer.play' || call.name === 'audioplayer.pause'), false);
  });
}

test('a foreign play request does not change the paused pending track', async t => {
  const f = fixture(); t.after(() => f.close()); f.begin(); f.call('pause'); f.call('play', 'other-play');
  await f.finish(); await f.advance(40);
  assert.equal(f.sandbox.NcmGapless.status().playing, false);
  assert.equal(f.nativeCalls.filter(call => call.name === 'audioplayer.play').length, 1);
});

test('a stopped pending load is not replayed by uninstall', async t => {
  const f = fixture(); t.after(() => f.close()); f.begin(); f.call('stop');
  const result = await f.sandbox.NcmGapless.uninstall();
  assert.equal(result.officialPlaybackRestored, false);
  assert.equal(f.replays.length, 0);
});

test('uninstall still restores a decoded track at its current paused position', async t => {
  const f = fixture(); t.after(() => f.close()); f.begin(); await f.finish();
  f.contexts[0].currentTime = .31; f.call('pause'); await f.flush();
  const position = f.sandbox.NcmGapless.status().position;
  assert.equal(position, .25);
  const result = await f.sandbox.NcmGapless.uninstall();
  assert.equal(result.officialPlaybackRestored, true);
  assert.equal(f.actions.find(action => action.type === 'playing/setPlayingPosition').payload.duration, position);
  assert.equal(f.actions.some(action => action.type === 'playing/pause'), true);
});
