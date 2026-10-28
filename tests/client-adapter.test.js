const assert = require('node:assert/strict');
const { test } = require('node:test');
const { discover, startupReadiness } = require('../src/client-adapter');

function fixture(platform) {
  const calls = [];
  const adapter = () => Object.assign(Object.create({
    callAdapter(name, callback, args) { calls.push({ receiver: this, name, args }); callback?.('native'); return 'forwarded'; },
  }), { registerCallMap: {}, _registerCallQueue(name) { return (...args) => this.registerCallMap[name]?.(...args); } });
  const primary = adapter(), legacy = adapter();
  const sdk = { AudioPlayer: { setPreloadInfoResult: async () => false },
    Bridge: { _Adapter: primary, triggerRegisterCall() {},
      appendRegisterCall(name, namespace, callback) { primary.registerCallMap[namespace + '.on' + name] = callback; },
      removeRegisterCall(name, namespace) { delete primary.registerCallMap[namespace + '.on' + name]; },
      createPromiseFromNativeRegisterCall(name, namespace, { filter_result }) {
        return new Promise(resolve => {
          const key = namespace + '.on' + name;
          primary.registerCallMap[key] = (...args) => {
            if (!filter_result(null, args)) return;
            delete primary.registerCallMap[key]; resolve(args);
          };
        });
      },
    } };
  const state = { playing: { playId: 'fixture', curPlaying: {} }, playingList: {} };
  const store = { getState: () => state, dispatch() {}, subscribe() {} };
  const modules = { sdk: { exports: sdk }, functions: { exports: {
    async preload({ curPlayId, preloadIndex }) {
      await sdk.AudioPlayer.setPreloadInfoResult({ params: { curPlayId, preloadIndex }, code: 1, info: { musicurl: 'fixture' } });
    },
    async refresh({ soundQuality }, skipLocalRpcCache) { return { soundQuality, skipLocalRpcCache, immerseType: '' }; },
    states: { Playing: 2, Pause: 1, Stop: 0 },
  } } };
  const require = { c: modules, m: {} };
  const target = {
    navigator: { userAgent: platform === 'macos' ? 'Macintosh NeteaseMusicDesktop/3.1.12.3444' : 'Windows NT NeteaseMusicDesktop/3.1.42.205594' },
    webpackJsonp: { push(chunk) { Object.values(chunk[1])[0]({}, {}, require); } },
    document: { getElementById: () => ({ _reactRootContainer: { _internalRoot: { current: { memoizedProps: { store } } } } }) },
    legacyNativeCmder: { _envAdapter: legacy },
  };
  if (platform === 'macos') target.ncmChannelOSX = { postMessage() {} };
  else target.channel = { call: primary.callAdapter };
  return { target, sdk, primary, legacy, calls, store };
}

for (const documentState of ['loading', 'interactive', 'complete']) {
  test('startup waits for playback interfaces instead of page resources: ' + documentState, () => {
    const { target, calls } = fixture('windows');
    target.document.readyState = documentState;
    const original = target.channel.call;
    assert.deepEqual(startupReadiness(target), { ready: true, error: null, documentState });
    assert.equal(target.channel.call, original);
    assert.deepEqual(calls, []);
  });
}
test('startup remains pending without the playback interfaces', () => {
  const { target } = fixture('windows');
  target.document.readyState = 'complete';
  target.document.getElementById = () => null;
  assert.equal(startupReadiness(target).ready, false);
});
test('startup refuses an incomplete contract on a new Windows client before any native call', () => {
  const { target, calls } = fixture('windows');
  target.navigator.userAgent = 'Windows NT NeteaseMusicDesktop/9.9.9';
  assert.equal(startupReadiness(target).error, 'CLIENT_PLAYBACK_CONTRACT_UNSUPPORTED');
  assert.deepEqual(calls, []);
});
function futureWindows() {
  const value = fixture('windows');
  value.target.navigator.userAgent = 'Windows NT NeteaseMusicDesktop/3.2.0.999999';
  value.target.AudioContext = function () {};
  value.target.fetch = async () => {};
  value.target.AbortController = AbortController;
  value.sdk.AudioPlayer.play = async () => {};
  value.store.getState().playingList.curPlayingList = [];
  return value;
}
test('a compatible Windows update qualifies without intercepting playback', () => {
  const { target, calls } = futureWindows();
  const original = target.channel.call;
  assert.equal(discover(target).compatibility, 'detected-playback-contract');
  assert.equal(startupReadiness(target).ready, true);
  assert.equal(target.channel.call, original);
  assert.deepEqual(calls, []);
});
for (const missing of ['play', 'events', 'queue', 'audio', 'fetch']) {
  test('a new Windows client with changed ' + missing + ' fails closed', () => {
    const { target, sdk, store, calls } = futureWindows();
    if (missing === 'play') delete sdk.AudioPlayer.play;
    if (missing === 'events') delete sdk.Bridge.appendRegisterCall;
    if (missing === 'queue') store.getState().playingList.curPlayingList = null;
    if (missing === 'audio') delete target.AudioContext;
    if (missing === 'fetch') delete target.fetch;
    assert.throws(() => discover(target), /CLIENT_PLAYBACK_CONTRACT_UNSUPPORTED/);
    assert.deepEqual(calls, []);
  });
}

for (const platform of ['windows', 'macos']) {
  test(platform + ' intercepts and restores every playback bridge', () => {
    const { target, primary, legacy, calls } = fixture(platform);
    const client = discover(target);
    assert.equal(client.platform, platform);
    const bridges = platform === 'macos' ? [primary, legacy] : [target.channel];
    const method = platform === 'macos' ? 'callAdapter' : 'call';
    const descriptors = bridges.map(bridge => Object.getOwnPropertyDescriptor(bridge, method));
    const originals = bridges.map(bridge => bridge[method]);
    const restore = client.intercept((name, callback, args, forward) => {
      if (name === 'audioplayer.play') return callback('patched');
      return forward(name, callback, args);
    });
    for (const bridge of bridges) {
      bridge[method]('audioplayer.play', value => assert.equal(value, 'patched'), []);
      assert.equal(bridge[method]('other.command', value => assert.equal(value, 'native'), [17]), 'forwarded');
      assert.equal(calls.at(-1).receiver, bridge);
      assert.deepEqual(calls.at(-1).args, [17]);
    }
    client.callNative('audioplayer.play', value => assert.equal(value, 'native'), []);
    restore();
    for (let i = 0; i < bridges.length; i++) {
      assert.equal(bridges[i][method], originals[i]);
      assert.deepEqual(Object.getOwnPropertyDescriptor(bridges[i], method), descriptors[i]);
    }
  });

  test(platform + ' captures official prefetch and emits positional events', async () => {
    const { target, sdk, primary, legacy } = fixture(platform);
    const client = discover(target);
    const descriptor = Object.getOwnPropertyDescriptor(sdk.AudioPlayer, 'setPreloadInfoResult');
    assert.deepEqual(await client.nextInfo(), { musicurl: 'fixture' });
    assert.deepEqual(Object.getOwnPropertyDescriptor(sdk.AudioPlayer, 'setPreloadInfoResult'), descriptor);
    const received = [];
    for (const bridge of [primary, legacy]) bridge.registerCallMap['audioplayer.onFixture'] = (...args) => received.push(args);
    client.emit('Fixture', 'track', { code: 0 }, 17);
    assert.deepEqual(received, [['track', { code: 0 }, 17], ['track', { code: 0 }, 17]]);
    const abort = new AbortController(); abort.abort();
    await assert.rejects(client.nextInfo(abort.signal), /PREFETCH_CANCELLED/);
  });
}

test('unknown versions and mismatched platforms fail before interception', () => {
  for (const agent of ['Macintosh NeteaseMusicDesktop/3.1.42.205594', 'Windows NT NeteaseMusicDesktop/3.1.12.3444',
    'Linux NeteaseMusicDesktop/3.1.12.3444', 'Macintosh NeteaseMusicDesktop/9.9.9']) {
    const { target } = fixture('macos');
    target.navigator.userAgent = agent;
    assert.throws(() => discover(target), /CLIENT_VERSION_UNVERIFIED|CLIENT_BRIDGE_MISSING/);
  }
});

test('restoring the Mac bridge preserves a subsequently installed hook', () => {
  const { target, primary } = fixture('macos');
  const restore = discover(target).intercept(() => {});
  const later = () => {};
  primary.callAdapter = later;
  restore();
  assert.equal(primary.callAdapter, later);
});

test('Mac restore refuses a missing or different authorized source', async () => {
  const { target } = fixture('macos');
  const client = discover(target);
  for (const info of [undefined, { songId: 'other', musicurl: 'fixture' }]) {
    await assert.rejects(client.restorePlayback({}, 20, false, info), /NATIVE_RESTORE_SOURCE_MISMATCH/);
  }
});

for (const [platform, pending] of [['windows', false], ['macos', false], ['macos', true]]) {
  test(platform + ' restores ' + (pending ? 'pending' : 'decoded') + ' native position and pause', async () => {
    const { target, store, primary, sdk } = fixture(platform);
    let loaded = platform === 'windows', position = 0, paused = false, nativeSeeks = 0, nativePauses = 0;
    sdk.Bridge.call = async (name, id, tag, value) => {
      assert.equal(name, 'audioplayer.seek');
      assert.equal(loaded, true);
      nativeSeeks++; position = value;
      primary.registerCallMap['audioplayer.onSeek'](id, tag, '0', value);
    };
    sdk.AudioPlayer.play = async info => {
      assert.equal(info.songId, 'fixture');
      await new Promise(resolve => setImmediate(resolve)); loaded = true;
      store.getState().playing.playId = info.songId;
    };
    sdk.AudioPlayer.pause = async ({ playId, resumeOrPauseId }) => {
      assert.equal(resumeOrPauseId, 'fixture|pause|official');
      await new Promise(resolve => setImmediate(resolve)); nativePauses++;
      primary.registerCallMap['audioplayer.onPlayState'](playId, resumeOrPauseId, '2');
    };
    store.dispatch = action => {
      if (action.type === 'playing/setPlaying') {
        assert.ok(platform === 'windows' || pending, 'Decoded Mac restore must not replay the asynchronous queue pipeline');
        if (pending) return sdk.AudioPlayer.play({ songId: 'fixture', musicurl: 'fixture' });
      } else if (action.type === 'playing/setPlayingPosition' && loaded) position = action.payload.duration;
      else if (action.type === 'playing/pause') {
        paused = true;
        if (platform === 'macos') sdk.AudioPlayer.pause({ playId: 'fixture', resumeOrPauseId: 'fixture|pause|official' });
      }
    };
    if (pending) store.getState().playing.playId = 'previous';
    const originalPlay = sdk.AudioPlayer.play;
    await discover(target).restorePlayback({}, 20, false, { songId: 'fixture', musicurl: 'fixture' }, pending);
    assert.equal(position, 20, 'An early native seek was ignored');
    assert.equal(paused, true);
    assert.equal(nativeSeeks, platform === 'macos' ? 1 : 0);
    assert.equal(nativePauses, platform === 'macos' ? 1 : 0);
    assert.equal(sdk.AudioPlayer.play, originalPlay);
    assert.equal(primary.registerCallMap['audioplayer.onPlayProgress'], undefined);
  });
}
