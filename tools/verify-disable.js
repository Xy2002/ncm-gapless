(async () => {
  const client = window.NcmGaplessClient.discover(window);
  const before = window.NcmGapless.status();
  if (!before.active) throw new Error('ACTIVE_PATCH_REQUIRED');
  let disabled = false;
  const positions = [];
  const handler = (id, position) => { if (disabled && Number.isFinite(position)) positions.push(position); };
  client.sdk.Bridge.appendRegisterCall('PlayProgress', 'audioplayer', handler);
  try {
    const result = await window.NcmGapless.uninstall();
    disabled = true;
    await new Promise(resolve => setTimeout(resolve, 1600));
    const state = client.getState().playing;
    return { pass: !window.NcmGapless.installed && String(window.channel.call).includes('[native code]') && positions.length > 0,
      installed: window.NcmGapless.installed, originalBridgeRestored: String(window.channel.call).includes('[native code]'),
      nativeProgressEvents: positions.length, nativePosition: positions[positions.length - 1],
      requestedRestorePosition: before.position, officialPlaying: state.playingState === client.states.Playing,
      restoreRequested: result.officialPlaybackRestored };
  } finally { client.sdk.Bridge.removeRegisterCall('PlayProgress', 'audioplayer', handler); }
})()
