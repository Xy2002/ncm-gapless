(async () => {
  const client = window.NcmGaplessClient.discover(window);
  const player = client.sdk.AudioPlayer;
  const originalPlay = player.play;
  const originalError = console.error;
  const calls = [], errors = [];
  const clean = value => String(value?.message || value).split('\n')[0].replace(/https?:\/\/\S+/g, '<url>').replace(/[A-Za-z0-9_=-]{48,}/g, '<redacted>').slice(0, 220);
  const adapter = client.sdk.Bridge._Adapter;
  const originalAdapter = adapter.callAdapter;
  adapter.callAdapter = function (name) {
    if (/^(audioplayer|audioeffect)\./.test(name)) calls.push(name);
    return originalAdapter.apply(this, arguments);
  };
  player.play = function (info) {
    calls.push('SDK.play');
    return Promise.resolve(originalPlay.apply(this, arguments)).catch(error => { errors.push(clean(error)); throw error; });
  };
  console.error = function () { errors.push(...Array.from(arguments).map(clean)); return originalError.apply(this, arguments); };
  try {
    client.replay();
    await new Promise(resolve => setTimeout(resolve, 3000));
    const state = client.getState().playing;
    return { calls: calls.slice(-35), errors: errors.slice(-8), state: state.playingState, hasPlayId: !!state.playId,
      sourceItemKeys: Object.keys(state.curPlaying || {}), currentTrackKeys: Object.keys(state.curTrack || {}),
      status: window.NcmGapless?.status?.() };
  } finally {
    adapter.callAdapter = originalAdapter;
    delete player.play;
    if (player.play !== originalPlay) player.play = originalPlay;
    console.error = originalError;
  }
})()
