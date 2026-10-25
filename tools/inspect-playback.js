(async () => {
  const require = window.__ncmGaplessProbeRequire;
  const sdk = require.c[4].exports;
  const root = document.getElementById('root')._reactRootContainer._internalRoot.current;
  const pending = [root]; let store;
  while (pending.length) {
    const fiber = pending.pop();
    if (!fiber) continue;
    const candidate = fiber.memoizedProps?.store || fiber.memoizedProps?.value?.store;
    if (candidate?.getState) { store = candidate; break; }
    pending.push(fiber.child, fiber.sibling);
  }
  const native = await sdk.AudioPlayer.getPlaybackInfo(store.getState().playing.playId);
  const numericOnly = value => {
    if (typeof value === 'number' || typeof value === 'boolean' || value === null) return value;
    if (Array.isArray(value)) return value.map(numericOnly);
    if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).filter(([key]) => !/id|url|path|name|header|cookie|token/i.test(key)).map(([key, item]) => [key, numericOnly(item)]));
    return typeof value;
  };
  const helpers = [];
  for (const [id, module] of Object.entries(require.c)) {
    const root = module.exports;
    if (!root || !['object', 'function'].includes(typeof root)) continue;
    for (const key of Object.keys(root)) {
      let value; try { value = root[key]; } catch (_) { continue; }
      if (typeof value === 'function' && /preloadIndex/.test(String(value)) && /setPreloadInfoResult/.test(String(value))) helpers.push({ id, key, length: String(value).length });
    }
  }
  return { native: numericOnly(native), helpers, sdkCallbacks: Object.keys(sdk.Bridge._Adapter.registerCallMap).filter(key => key.startsWith('audioplayer.')) };
})()
