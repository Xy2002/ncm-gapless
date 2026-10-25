(() => {
  const root = document.getElementById('root')._reactRootContainer._internalRoot.current;
  const nodes = [root]; let store;
  while (nodes.length) {
    const fiber = nodes.pop();
    if (!fiber) continue;
    const candidate = fiber.memoizedProps && (fiber.memoizedProps.store || fiber.memoizedProps.value?.store);
    if (candidate?.getState) { store = candidate; break; }
    nodes.push(fiber.child, fiber.sibling);
  }
  const state = store.getState();
  const shape = object => Object.fromEntries(Object.entries(object || {}).map(([key, value]) => [key, value === null ? 'null' : Array.isArray(value) ? { type: 'array', length: value.length, firstKeys: Object.keys(value[0] || {}) } : typeof value]));
  return { playing: shape(state.playing.curPlaying), track: shape(state.playing.curTrack), queue: shape(state.playingList.curPlayingList), cacheFirst: shape(Object.values(state.playing.cachedTrackMap || {})[0]), bridgeMethods: Object.keys(window.__ncmGaplessProbeRequire.c[4].exports.Bridge._Adapter), state: { playingMode: state.playing.playingMode, playingState: state.playing.playingState, playingVolume: state.playing.playingVolume, playingSpeed: state.playing.playingSpeed } };
})()
