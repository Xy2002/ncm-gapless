/* One prefetch using the OFFICIAL client's existing queue and authentication.
 * Returns only capability booleans/counts; never URLs, cookies, IDs, or names.
 * Playback and official queue remain unchanged. No encrypted cache is decoded.
 */
(async () => {
  const require = window.__ncmGaplessProbeRequire;
  if (!require) throw new Error('Run inspect-modules.js first');
  let sdk, preload;
  for (const module of Object.values(require.c)) {
    const root = module.exports;
    if (!root || !['object', 'function'].includes(typeof root)) continue;
    if (root.AudioPlayer?.setPreloadInfoResult && root.Bridge?.triggerRegisterCall) sdk = root;
    for (const key of Object.keys(root)) {
      let value; try { value = root[key]; } catch (_) { continue; }
      if (typeof value === 'function' && /preloadIndex/.test(String(value)) && /setPreloadInfoResult/.test(String(value))) preload = value;
    }
  }
  const nodes = [document.getElementById('root')._reactRootContainer._internalRoot.current];
  let store;
  while (nodes.length) {
    const fiber = nodes.pop();
    if (!fiber) continue;
    const candidate = fiber.memoizedProps?.store || fiber.memoizedProps?.value?.store;
    if (candidate?.getState) { store = candidate; break; }
    nodes.push(fiber.child, fiber.sibling);
  }
  if (!sdk || !preload || !store) return { supported: false, reason: 'missing-interface' };
  const id = store.getState().playing.playId;
  const object = sdk.AudioPlayer;
  const descriptor = Object.getOwnPropertyDescriptor(object, 'setPreloadInfoResult');
  const original = object.setPreloadInfoResult;
  let captured;
  const controller = new AbortController();
  const deadline = setTimeout(() => controller.abort(), 12000);
  try {
    object.setPreloadInfoResult = function (result) {
      if (result?.params?.curPlayId === id) captured = result;
      return original.apply(this, arguments);
    };
    await Promise.race([
      preload({ curPlayId: id, preloadIndex: 0 }),
      new Promise((resolve, reject) => controller.signal.addEventListener('abort', () => reject(new Error('Prefetch timeout')), { once: true })),
    ]);
  } catch (error) {
    return { supported: false, stage: 'official-prefetch', error: error.name };
  } finally {
    if (descriptor) Object.defineProperty(object, 'setPreloadInfoResult', descriptor);
    else delete object.setPreloadInfoResult;
    clearTimeout(deadline);
  }
  const info = captured?.info;
  const summary = { officialPrefetchCaptured: !!captured, hasStreamUrl: !!info?.musicurl, hasLocalPath: !!info?.path, officialAllowed: captured?.code === 1,
    hasExtraHeaders: !!info?.extHeader, sourceScheme: info?.musicurl ? new URL(info.musicurl).protocol : null };
  let extraHeaders = info?.extHeader;
  try { if (typeof extraHeaders === 'string') extraHeaders = JSON.parse(extraHeaders); } catch (_) { extraHeaders = null; }
  summary.extraHeaderKeys = extraHeaders && typeof extraHeaders === 'object' ? Object.keys(extraHeaders) : [];
  if (!summary.officialAllowed || !summary.hasStreamUrl) return summary;
  if (store.getState().playing.playId !== id) return { ...summary, cancelled: 'track-changed' };
  const fetchController = new AbortController();
  const fetchDeadline = setTimeout(() => fetchController.abort(), 12000);
  try {
    let response = await fetch(info.musicurl, { signal: fetchController.signal });
    summary.httpOk = response.ok;
    summary.httpStatus = response.status;
    summary.responseType = response.type;
    if (!response.ok && new URL(info.musicurl).protocol === 'http:') {
      const secure = new URL(info.musicurl);
      secure.protocol = 'https:';
      // Same authorized URL, host, path, query, and credentials; only use TLS.
      response = await fetch(secure.href, { signal: fetchController.signal });
      summary.httpsOk = response.ok;
      summary.httpsStatus = response.status;
    }
    if (!response.ok && extraHeaders && typeof extraHeaders === 'object') {
      const secure = new URL(info.musicurl);
      secure.protocol = 'https:';
      response = await fetch(secure.href, { signal: fetchController.signal, headers: extraHeaders });
      summary.officialHeadersOk = response.ok;
      summary.officialHeadersStatus = response.status;
    }
    if (!response.ok) {
      const message = await response.text();
      summary.errorSignals = ['HTTPS', 'Forbidden', 'AccessDenied', 'expired', 'Blocked'].filter(signal => message.toLowerCase().includes(signal.toLowerCase()));
      // A bounded range request through the client's OWN transport separates
      // a browser limitation from an unavailable source. Never log its body.
      try {
        const secure = new URL(info.musicurl); secure.protocol = 'https:';
        const native = await Promise.race([
          sdk.Network.fetch({ url: info.musicurl, method: 'GET', headers: { ...(extraHeaders || {}), Range: 'bytes=0-4095' },
            retryCount: 0, isDecrypt: false, isXeapi: false, shouldIncludeHeaders: true }),
          new Promise((resolve, reject) => fetchController.signal.addEventListener('abort', () => reject(new Error('Native transport timeout')), { once: true })),
        ]);
        summary.nativeTransport = { scheme: new URL(info.musicurl).protocol, keys: Object.keys(native || {}), status: native?.status, code: native?.code,
          bodyType: typeof native?.body, dataType: typeof native?.data };
      } catch (error) { summary.nativeTransport = { error: error.name }; }
      return summary;
    }
    const maximum = 24 * 1024 * 1024;
    if (Number(response.headers.get('Content-Length')) > maximum) return { ...summary, cancelled: 'size-limit' };
    const reader = response.body.getReader();
    const chunks = []; let bytes = 0;
    for (;;) {
      const chunk = await reader.read();
      if (chunk.done) break;
      bytes += chunk.value.byteLength;
      if (bytes > maximum) { await reader.cancel(); return { ...summary, cancelled: 'size-limit' }; }
      chunks.push(chunk.value);
    }
    const data = new Uint8Array(bytes); let offset = 0;
    for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.length; }
    const context = new OfflineAudioContext(2, 1, 48000);
    const buffer = await context.decodeAudioData(data.buffer);
    return { ...summary, browserDecoded: true, bytes, frames: buffer.length,
      sampleRate: buffer.sampleRate, channels: buffer.numberOfChannels };
  } catch (error) {
    return { ...summary, browserDecoded: false, error: error.name };
  } finally { clearTimeout(fetchDeadline); }
})()
