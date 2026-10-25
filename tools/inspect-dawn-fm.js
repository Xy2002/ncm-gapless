(async () => {
  const require = window.__ncmGaplessProbeRequire;
  if (!require) throw new Error('Run inspect-modules.js first');
  const modules = Object.entries(require.c).filter(([id]) => String(require.m[id]).includes('/api/cloudsearch/pc'));
  if (modules.length !== 1) throw new Error('SEARCH_API_UNSUPPORTED');
  const search = modules[0][1].exports.Y;
  if (typeof search !== 'function') throw new Error('SEARCH_API_UNSUPPORTED');
  const response = await search({ s: 'Dawn FM', type: 10, limit: 20, offset: 0 });
  const albums = response.result?.albums || response.albums || response.data?.albums || [];
  const matching = albums.filter(album => album.name === 'Dawn FM' &&
    [album.artist, ...(album.artists || [])].some(artist => artist?.name === 'The Weeknd'));
  const helpers = [];
  for (const [id, module] of Object.entries(require.c)) {
    const object = module.exports;
    if (!object || !['object', 'function'].includes(typeof object)) continue;
    for (const key of Object.keys(object)) {
      const value = object[key];
      if (typeof value !== 'function') continue;
      const source = String(value);
      if (/\/api\/(v\d\/)?album\//.test(source)) helpers.push({ id, key, source: source.slice(0, 1800) });
    }
  }
  return { code: response.code, responseKeys: Object.keys(response), matches: matching.map(album => ({ id: album.id, name: album.name,
    artist: album.artist?.name, tracks: album.size })), helpers: helpers.slice(0, 12) };
})()
