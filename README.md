# Album Mix

A [Lyrion Music Server](https://lyrion.org/) plugin that creates continuous, discovery-driven playlists from any seed album. Select an album, and Album Mix plays it then automatically queues sonically similar albums using Last.fm track similarity. Supports local library and online services (Spotify, TIDAL, Qobuz, Deezer).

## How it works

1. Right-click any album and select **Create Album Mix**
2. The seed album starts playing immediately
3. As you approach the end of the current album, the plugin picks a track from it and queries Last.fm for sonically similar tracks
4. It resolves the best match to an album, checks it hasn't been played already, and queues it
5. The process repeats — each album seeds the next

If track similarity returns no results, the plugin falls back to artist similarity (Last.fm `artist.getSimilar` → `artist.getTopAlbums`).

## Requirements

- Lyrion Music Server 8.0+
- A free [Last.fm API key](https://www.last.fm/api/account/create)
- At least one music source: local library, or an online service plugin (Spotty, TIDAL, Qobuz, Deezer)

## Installation

### Manual install

1. Download the latest release zip
2. Extract to your LMS Plugins directory:
   ```bash
   sudo mkdir -p /usr/share/squeezeboxserver/Plugins/AlbumMix
   cd /usr/share/squeezeboxserver/Plugins/AlbumMix
   sudo unzip /path/to/AlbumMix-1.0.0.zip
   sudo chown -R squeezeboxserver:nogroup /usr/share/squeezeboxserver/Plugins/AlbumMix
   ```
3. Restart LMS:
   ```bash
   sudo systemctl restart lyrionmusicserver
   ```
4. Go to **Settings → Plugins** and confirm Album Mix is listed and enabled
5. Go to **Settings → Advanced → Album Mix** and enter your Last.fm API key

> **Note:** The plugin directory path may vary by installation. Check **Settings → Information → Plugin Folders** in LMS for the correct location on your system.

## Settings

| Setting | Default | Description |
|---|---|---|
| Last.fm API Key | *(empty)* | Required. Get one free at [last.fm/api](https://www.last.fm/api/account/create) |
| Prefer Local Library | On | Search local library first before trying online services |
| Album History Size | 50 | Number of albums to remember per session to avoid repeats |
| Queue Lookahead | 2 | Tracks remaining before the next album is queued |

## Compatibility

- Works with the default LMS web interface and Material Skin
- Supports multiple players independently (each runs its own mix session)
- Works with both local and online service albums as the seed

## How similarity is determined

The plugin uses a **track-based** approach rather than artist-based:

1. A random track between the second and penultimate of the current album is selected as the seed
2. Last.fm `track.getSimilar` returns up to 50 sonically similar tracks
3. Each candidate track is resolved to its parent album via `track.getInfo`
4. The first album not already in the session history is queued

This tends to produce more interesting and varied results than pure artist similarity, as it follows the sound of specific songs rather than broad genre associations.

If track similarity fails, the plugin falls back to `artist.getSimilar` → `artist.getTopAlbums`.

## Stopping a mix

Right-click any album while a mix is active and select **Stop Album Mix**, or simply clear the playlist.

## Licence

<<<<<<< HEAD
=======
GPL 3.0
>>>>>>> 83e9036551dfb86ea71fefa18617a74f4941e36c
