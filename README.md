# Album Mix

A [Lyrion Music Server](https://lyrion.org/) plugin that creates continuous, discovery-driven playlists from any seed album. Pick an album and Album Mix plays it, then keeps queuing similar albums using Last.fm track similarity. Albums can come from your local library or from an online service (TIDAL, Spotify).

## How it works

1. Open any album's context menu and select **Create Album Mix**
2. The seed album starts playing straight away
3. When the current album is nearly finished, the plugin picks a track from it and asks Last.fm for similar tracks
4. It works out which album each similar track belongs to and queues the first one that passes the checks below
5. The process repeats — each queued album seeds the next

## How the next album is chosen

1. **Seed track** — a random track from the last queued album, between its second and second-to-last track (the first and last tracks are often intros, outros or hidden tracks). Tracks you add to the queue yourself after that album are not used.
2. **Similar tracks** — Last.fm `track.getSimilar` returns up to 50 similar tracks, closest match first.
3. **Album lookup** — for each similar track, Last.fm `track.getInfo` gives the album it belongs to.
4. **Checks** — an album is skipped if:
   - it was already played in this mix
   - its artist is on cooldown (see **Artist Cooldown**)
   - it was already tried in this mix and couldn't be queued
   - Discovery Mode is on and the album is already in your local library
5. **Queue** — the plugin looks for the album in your library and/or online service (see **Settings**). Online search results must match both the artist and the album title, so a different album by the same artist is never queued. Minor differences such as "(Deluxe Edition)" or "- 2011 Remaster" are ignored. If the album can't be found anywhere, the plugin moves on to the next candidate.

If no similar track leads to an album that can be queued, the plugin falls back to artist similarity: Last.fm `artist.getSimilar` → `artist.getTopAlbums`, trying each artist's albums in turn with the same checks.

Following the sound of specific songs tends to give more interesting and varied results than pure artist similarity.

## Requirements

- Lyrion Music Server 8.0+
- A free [Last.fm API key](https://www.last.fm/api/account/create)
- At least one music source: your local library, or an online service plugin (TIDAL, or Spotty for Spotify)

## Installation

### From the plugin repository (recommended)

1. In LMS go to **Settings → Manage Plugins**
2. At the bottom, under **Additional Repositories**, add:
   ```
   https://raw.githubusercontent.com/mattkoopmans/lms-albummix/main/repo.xml
   ```
3. Click **Apply**, then find **Album Mix** in the plugin list, tick it and click **Apply** again
4. Restart LMS when prompted
5. Open the Album Mix settings (**Settings → Advanced → Album Mix**, or the **Settings** link next to Album Mix in **Manage Plugins**) and enter your Last.fm API key

LMS will then offer new versions automatically.

### Manual install

1. Download `AlbumMix-x.y.z.zip` from the [latest release](https://github.com/mattkoopmans/lms-albummix/releases/latest)
2. Extract it into your LMS Plugins folder so you end up with a `Plugins/AlbumMix` folder, for example:
   ```bash
   cd /usr/share/squeezeboxserver/Plugins
   sudo unzip /path/to/AlbumMix-x.y.z.zip
   sudo chown -R squeezeboxserver:nogroup AlbumMix
   ```
3. Restart LMS:
   ```bash
   sudo systemctl restart lyrionmusicserver
   ```
4. Go to **Settings → Manage Plugins** and confirm Album Mix is listed and enabled
5. Open the Album Mix settings and enter your Last.fm API key

> **Note:** The Plugins folder location varies by installation. Check **Settings → Information → Plugin Folders** in LMS for the correct location on your system.

## Settings

| Setting | Default | Description |
|---|---|---|
| Last.fm API Key | *(empty)* | Required. Get one free at [last.fm/api](https://www.last.fm/api/account/create) |
| Prefer Local Library | On | Look in your local library first, then online services. Ignored when Discovery Mode is on |
| Discovery Mode | Off | Only queue albums that are **not** in your local library, played from your online service. The album you start the mix from is always played |
| Artist Cooldown | 5 | Number of albums that must be queued before the same artist can appear again. 0 turns it off |
| Album History Size | 50 | Number of albums remembered per mix to avoid repeats |
| Queue Lookahead | 2 | Number of tracks left in the queue when the next album is looked up |

## Stopping a mix

- Open any album's context menu while a mix is active and select **Stop Album Mix**, or
- Clear the queue, or start playing something else — the mix stops by itself

## Compatibility

- Works with the default LMS web interface and Material Skin
- Each player runs its own mix (synced players share one mix)
- The seed album can be from your library or an online service
- Online services: TIDAL is tested. Spotify (via Spotty) is supported but untested. Qobuz and Deezer are not supported yet

## Changelog

### 1.1.3
- Discovery Mode now skips albums that are already in your local library
- If a chosen album can't be found (in the library or online), the plugin tries the next candidate instead of giving up
- Online search results must match the album title as well as the artist
- The mix stops when the queue is cleared or replaced
- Seed tracks are only taken from the last album the mix queued, not from tracks added after it
- A lookup that never finishes no longer stalls the mix

### 1.1.2
- Fixed TIDAL discovery (search response format and album link)
- Replaced `JSON::XS::VersionOneAndTwo` with `JSON::XS`

## Releasing (maintainer notes)

Releases are built by GitHub Actions (`.github/workflows/release.yml`):

1. Update `<version>` in `install.xml` and the changelog above, then commit and push
2. Tag and push, e.g. `git tag v1.2.0 && git push origin v1.2.0`

The workflow builds the zip, attaches it to the release, checks the download, and only then updates `repo.xml`. Don't edit the version, URL or SHA in `repo.xml` by hand.

## Licence

GPL 3.0
