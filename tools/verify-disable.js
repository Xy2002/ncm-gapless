(async () => {
  const client = window.NcmGaplessClient.discover(window);
  const before = window.NcmGapless.status();
  if (!before.active) throw new Error('ACTIVE_PATCH_REQUIRED');
  const bridges = [client.sdk.Bridge._Adapter, window.legacyNativeCmder?._envAdapter].filter(Boolean);
  const restored = () => client.platform === 'windows' ? String(window.channel.call).includes('[native code]') :
    bridges.every(bridge => bridge.callAdapter === Object.getPrototypeOf(bridge).callAdapter);
  let disabled = false;
  const positions = [];
  const handler = (id, position) => {
    const seconds = typeof position === 'string' && position.trim() ? Number(position) : position;
    if (disabled && Number.isFinite(seconds)) positions.push(seconds);
  };
  client.sdk.Bridge.appendRegisterCall('PlayProgress', 'audioplayer', handler);
  try {
    const result = await window.NcmGapless.uninstall();
    disabled = true;
    await new Promise(resolve => setTimeout(resolve, 1600));
    const state = client.getState().playing;
    const nativePosition = positions[positions.length - 1];
    const positionRestored = Number.isFinite(nativePosition) && nativePosition >= before.position - 0.1 && nativePosition < before.position + 4;
    return { pass: !window.NcmGapless.installed && restored() && positions.length > 0 && positionRestored,
      installed: window.NcmGapless.installed, originalBridgeRestored: restored(),
      nativeProgressEvents: positions.length, nativePosition, positionRestored,
      requestedRestorePosition: before.position, officialPlaying: state.playingState === client.states.Playing,
      restoreRequested: result.officialPlaybackRestored };
  } finally { client.sdk.Bridge.removeRegisterCall('PlayProgress', 'audioplayer', handler); }
})()
