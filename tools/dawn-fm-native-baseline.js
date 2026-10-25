(async () => {
  const client = window.NcmGaplessClient.discover(window);
  const fixture = window.__ncmGaplessAlbumFixture;
  if (!fixture || fixture.items.length !== 16) throw new Error('DAWN_FM_FIXTURE_MISSING');
  const state = client.getState();
  if (!window.__ncmGaplessValidationBackup) window.__ncmGaplessValidationBackup = {
    queue: state.playingList.curPlayingList, current: state.playing.curPlaying,
  };
  client.store.dispatch({ type: 'playingList/replaceCurPlayingList', payload: { list: fixture.items } });
  client.replay(fixture.items[0]);
  return { requested: true, album: 'Dawn FM', tracks: fixture.items.length, patchInstalled: !!window.NcmGapless?.installed };
})()
