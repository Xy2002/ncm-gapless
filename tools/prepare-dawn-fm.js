(async () => {
  const require = window.__ncmGaplessProbeRequire;
  if (!require) throw new Error('Run inspect-modules.js first');
  const id = Object.keys(require.c).find(id => String(require.m[id]).includes('/api/cloudsearch/pc'));
  if (!id) throw new Error('OFFICIAL_API_MISSING');
  const source = String(require.m[id]);
  const key = /\.d\(\w+,"([^"]+)",\(function\(\)\{return da\}\)\)/.exec(source)?.[1];
  if (!key || typeof require.c[id].exports[key] !== 'function') throw new Error('ALBUM_API_MISSING');
  const album = await require.c[id].exports[key]({ id: '138513905' }, { formatOption: { id: '138513905' } });
  if (!album.tracks?.length) return { albumKeys: Object.keys(album), found: false };
  const items = album.tracks.map((track, index) => ({
    id: String(track.id), resourceId: String(track.id), trackId: String(track.id), resourceType: 'track',
    displayOrder: index, randomOrder: index, isPlayedOnce: false, ai: '', aiRcmd: false,
    scene: 'album', href: '/album?id=138513905', text: 'Dawn FM', localTrack: {}, track,
    fromInfo: { originalScene: 'album', originalResourceType: 'album', computeSourceResourceType: 'album', originalResourceId: '138513905' },
  }));
  window.__ncmGaplessAlbumFixture = { albumId: '138513905', items };
  return { found: true, albumId: '138513905', count: items.length,
    tracks: items.slice(0, 5).map(item => ({ id: item.resourceId, name: item.track.name, duration: item.track.duration,
      privilegePresent: !!item.track.privilege })) };
})()
