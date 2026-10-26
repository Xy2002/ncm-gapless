const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

test('Mac native progress strings prove playback restoration', async () => {
  let progress;
  const bridge = Object.assign(Object.create({ callAdapter() {} }), {
    appendRegisterCall(name, namespace, callback) { progress = callback; },
    removeRegisterCall() { progress = null; },
  });
  const client = { platform: 'macos', sdk: { Bridge: { _Adapter: bridge,
    appendRegisterCall: bridge.appendRegisterCall, removeRegisterCall: bridge.removeRegisterCall } },
    states: { Playing: 2 }, getState: () => ({ playing: { playingState: 2 } }) };
  const patch = { installed: true, status: () => ({ active: true, position: 12 }),
    async uninstall() { this.installed = false; return { officialPlaybackRestored: true }; } };
  const source = fs.readFileSync(path.join(__dirname, '../tools/verify-disable.js'), 'utf8');
  const result = await vm.runInNewContext(source, {
    window: { NcmGaplessClient: { discover: () => client }, NcmGapless: patch },
    setTimeout(callback) { progress('fixture', '12.5'); callback(); },
  });
  assert.equal(result.pass, true);
  assert.equal(result.nativeProgressEvents, 1);
  assert.equal(result.nativePosition, 12.5);
  assert.equal(progress, null);
});
