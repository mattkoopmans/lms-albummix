# Album Mix

A [Lyrion Music Server](https://lyrion.org/) plugin that creates continuous, discovery-driven playlists from any seed album. Pick an album and Album Mix plays it, then keeps queuing similar albums using Last.fm track similarity. Albums can come from your local library or from an online service (TIDAL, Spotify).

## How it works

1. Start a mix from a context menu (**More** / the **⋮** menu):
   - an album — **Create Album Mix**
   - a track — **Create Album Mix from This Track**
   - an artist — **Create Album Mix from This Artist** (artists in your library; online services' own artist pages may not offer it)
   - the song playing now — **Continue as Album Mix** (keeps your queue; when it is about to run out, similar albums are added, following on from the last album in it). Not offered for radio streams, which never end
2. What you started from plays first — the album, the track, or one of the artist's albums. Untick **Play the Starting Album or Track** to skip it and start straight away with the first similar album.
3. About halfway through the last album in the queue (or, at the latest, when only **Queue Lookahead** tracks are left), the plugin picks a track from it and asks Last.fm for similar tracks, so the next album is queued well before the music runs out
4. It works out which album each similar track belongs to and queues the first one that passes the checks below
5. A short message says what was queued and why (e.g. *Queued Tusk — Fleetwood Mac, like "Dreams"*); the server log has the full reason
6. The process repeats — each queued album seeds the next

## How the next album is chosen

1. **Seed track** — a random track from the last queued album, between its second and second-to-last track (the first and last tracks are often intros, outros or hidden tracks). Tracks you add to the queue yourself after that album are not used.
2. **Similar tracks** — Last.fm `track.getSimilar` returns up to 50 similar tracks, closest match first.
3. **Variety** — the closest few tracks (10 by default, see **Variety**) are shuffled so the same seed doesn't always lead to the same album. Closer matches are still more likely to come first.
4. **Album lookup** — for each similar track in that order, Last.fm `track.getInfo` gives the album it belongs to.
5. **Checks** — an album is skipped if:
   - it was already played in this mix
   - it was queued by any mix in the last 30 days (see **Don't Repeat Albums For**)
   - its artist is on cooldown (see **Artist Cooldown**)
   - its title marks it as a compilation, live album, single, EP or remix release (see the **Skip** settings)
   - it was already tried in this mix and couldn't be queued
   - **Source** is "Online only" and the album is already in your local library
6. **Queue** — the plugin looks for the album in your library and/or online service (see **Source**). Search results must match both the artist and the album title, so a different album by the same artist is never queued. Differences such as "(Deluxe Edition)", "- 2011 Remaster", "Remastered", accents ("Björk"/"Bjork"), "&"/"and" and "Vol."/"Volume" are ignored. Releases with fewer tracks than **Minimum Tracks per Album** are passed over where the track count is known. If the album can't be found anywhere, the plugin moves on to the next candidate.

If no similar track leads to an album that can be queued, the plugin falls back to artist similarity: Last.fm `artist.getSimilar` → `artist.getTopAlbums`. The closest artists are tried in a shuffled order (see **Variety**), and each artist's top albums in random order rather than most popular first, all with the same checks.

The album you start the mix from is always played, whatever the filters say.

Following the sound of specific songs tends to give more interesting and varied results than pure artist similarity.

## Don't Stop The Music

Album Mix can also be the provider for LMS's built-in **Don't Stop The Music**, which adds more music when a queue is about to end. Choose **Album Mix** for a player under *Settings > Player > Don't Stop The Music*.

- When the queue is nearly done (about 2 tracks left), Album Mix finds a similar album the same way as above and hands it to Don't Stop The Music, which adds it to the queue
- The player's Album Mix settings are used: **Source**, the **Skip** filters, **Minimum Tracks per Album**, **Variety**, **Artist Cooldown** and the saved history (**Don't Repeat Albums For**)
- It starts from the end of the queue: if that is an album, a random track from it (as above); if it is a playlist of different artists, one of its last 5 tracks at random, so the pick follows what was playing recently
- Albums already picked and the artist cooldown are remembered from one pick to the next
- If nothing suitable is found (for example with **Source** "Library only" and a small library), Don't Stop The Music plays something else instead, as it does for any provider
- While an Album Mix you started yourself is running on a player, Don't Stop The Music holds off there; Album Mix adds the next album itself

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

Settings are on two pages:

- **Settings → Advanced → Album Mix** — server-wide settings, and the defaults for every player
- **Settings → Player → Album Mix** (for each player) — tick **Use Own Settings for This Player** to give that player its own values for the settings marked *per player* below. Players that don't tick it use the server defaults. Synced players use the settings of the main player in the group.

| Setting | Default | Per player | Description |
|---|---|---|---|
| Last.fm API Key | *(empty)* | — | Required. Get one free at [last.fm/api](https://www.last.fm/api/account/create) |
| Play the Starting Album or Track | On | yes | Play what the mix starts from (album, track, or one of the artist's albums) before the similar albums. Off: start straight away with the first similar album, chosen from a track of the starting album (or the track itself, or the artist's similar artists) |
| Source | Library first | yes | Where albums come from: **Library only**, **Library first, then online**, **Online first, then library**, or **Online only** (only albums you don't own — discovery). The album you start from can always come from anywhere, even with Library only |
| Skip Compilations | On | yes | Don't queue greatest hits, best-of, collections, anthologies, soundtracks, tributes and similar |
| Skip Live Albums | On | yes | Don't queue live albums ("Live at …", "In Concert", "Unplugged", …) |
| Skip Singles and EPs | On | yes | Don't queue singles, EPs or remix releases |
| Minimum Tracks per Album | 5 | yes | With Skip Singles and EPs on, releases with fewer tracks are skipped where the track count is known (library, TIDAL, Spotify). 0 turns it off |
| Variety | 10 | yes | How many of the closest Last.fm matches to choose from at random (closer matches are more likely). 1 always takes the closest match |
| Artist Cooldown | 5 | yes | Number of albums that must be queued before the same artist can appear again. 0 turns it off |
| Queue Lookahead | 2 | yes | The next album is normally looked up about halfway through the last album in the queue. This setting is the latest point: if no lookup has started by then, it starts when only this many tracks are left |
| Album History Size | 50 | — | Number of albums remembered within one mix to avoid repeats |
| Don't Repeat Albums For | 30 days | — | An album queued by a mix isn't queued again for this many days. Remembered across mixes and server restarts. 0 turns it off |
| Saved History | Shared by all players | — | **Shared**: an album played on one player isn't repeated on another. **Separate for each player**: each player (sync group: its main player) has its own history |
| Clear Saved History | — | — | Tick and save to forget which albums have been played. The server page clears the shared history; a player's page clears that player's own history |

When upgrading from 1.2, **Source** is set from the old **Prefer Local Library** and **Discovery Mode** settings (Discovery on → Online only; Prefer Local on → Library first; both off → Online first). The old settings are kept in step, so going back to 1.2 works; 1.2 has no "Library only", so that becomes Prefer Local Library, which in 1.2 still falls back to online services. If you change those settings in 1.2 and then upgrade again, Source is set from them again.

The **Skip** filters work from album titles, so an album whose title doesn't say what it is (e.g. a live album called just "Stop Making Sense") can still get through, and once in a while a studio album whose title looks like one is skipped (e.g. "Live in Fear"). They are checked against both the title Last.fm gives and the title of the album actually found, so asking for "Rumours" can't end up queuing "Rumours (Live)".

## Testing versions

Test versions are published from the `Testing` branch as GitHub pre-releases. To try one, replace the repository URL in **Settings → Manage Plugins → Additional Repositories** with:

```
https://raw.githubusercontent.com/mattkoopmans/lms-albummix/main/repo-testing.xml
```

Switch back to the normal URL (`.../main/repo.xml`, see **Installation**) to return to normal releases. Use one URL or the other, not both.

## Stopping a mix

- Open any album's, track's or artist's context menu while a mix is active and select **Stop Album Mix**, or
- Clear the queue, or start playing something else — the mix stops by itself

## Compatibility

- Works with the default LMS web interface and Material Skin
- Each player runs its own mix (synced players share one mix)
- The seed album can be from your library or an online service
- Online services: TIDAL is tested. Spotify (via Spotty) is supported but untested. Qobuz and Deezer are not supported yet

## Changelog

### 1.9.5 (development build towards 2.0)
- Album Mix can be the provider for Don't Stop The Music (see **Don't Stop The Music**), using each player's Album Mix settings
- For a queue that ends with a playlist of different artists, it starts from one of the last 5 tracks at random
- Don't Stop The Music holds off on a player while your own Album Mix runs there
- The settings pages say that the settings also apply to Don't Stop The Music (translated)

### 1.9.4 (development build towards 2.0)
- Translated into every language LMS itself supports (Czech, Danish, Dutch, Finnish, French, German, Hebrew, Hungarian, Italian, Japanese, Norwegian, Polish, Portuguese, Russian, Simplified Chinese, Spanish and Swedish), using LMS's own words for its menus. Corrections from native speakers are welcome
- Saved Last.fm answers are kept in the server's cache folder (albummix-lastfm.json), so they survive a restart
- At most two Last.fm requests run at once, with real lookups ahead of fetching in advance, so Last.fm's rate limit isn't hit; a request isn't retried once it is 30 seconds old
- An online service (TIDAL, Spotify) that doesn't answer a search within 20 seconds is skipped and the next one is tried; its late answer can't add a second album
- While an album found online is still being added to the queue, no further album is looked up, so two albums can't be queued at once. If it hasn't appeared after 60 seconds, the mix looks for another one

### 1.9.3 (development build towards 2.0)
- Faster, more reliable Last.fm lookups: answers are kept for a while (similar tracks, similar artists and top albums for a day, album details for a week; only the parts the plugin uses, to save memory) instead of being asked again, a question already on its way isn't sent twice, and a request that fails for a passing reason (network, Last.fm busy or offline) is retried twice before giving up
- The albums of the next few candidate tracks are looked up in advance, so picking an album takes fewer round trips
- The next album is looked up about halfway through the current one, rather than when only Queue Lookahead tracks (2 by default) are left, so the queue is much less likely to run out on short albums or slow lookups. Queue Lookahead is now the latest point for the lookup
- All Last.fm requests go through one place in the code

### 1.9.2 (development build towards 2.0)
- Start a mix from a track, an artist, or the song playing now (**Continue as Album Mix**), as well as from an album
- New per-player setting **Play the Starting Album or Track**: untick it to skip the seed and start with the first similar album
- The pop-up says why each album was queued (*like "song"* or *similar artist to …*), and the log gives the full reason including the Last.fm match score
- A message appears when the Last.fm API key is missing, instead of the mix silently doing nothing

### 1.9.1 (development build towards 2.0)
- Fixed: the Source choices showed no names in the settings pages (seen in Material Skin)

### 1.9.0 (development build towards 2.0)
- Per-player settings: each player can use its own Source, Skip filters, Minimum Tracks, Variety, Artist Cooldown and Queue Lookahead, or the server defaults. Synced players use the main player's settings
- New **Source** setting (Library only / Library first / Online first / Online only) replaces Prefer Local Library and Discovery Mode; set automatically from them when upgrading
- New **Library only** option: the mix never searches online services
- **Saved History** can be shared by all players (as before) or kept separately for each player
- The Last.fm API key, album history size and repeat days stay server-wide

### 1.2
- Skips compilations, live albums, singles, EPs and remix releases (each can be turned off), plus releases with too few tracks
- Looser album name matching: ignores accents, more edition notes ("Remastered", "Super Deluxe Edition", "Legacy Edition"), "+"/"&"/"and", "Vol."/"Volume", "Pt."/"Part"
- Library lookups compare titles loosely, so "Rumours (Remastered)" finds your copy of "Rumours", while "Led Zeppelin" no longer matches "Led Zeppelin II"
- Online searches leave out bracketed notes from the album title, so more albums are found
- "Rumours" and "Rumours (Super Deluxe)" now count as the same album in the history
- Less predictable picks: chooses at random among the closest matches (Variety setting), and among an artist's top albums rather than always the most popular
- Saved history: albums aren't repeated for 30 days across mixes, players and restarts (setting, with a button to clear it)

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

1. Update `<version>` in `install.xml` and the changelog above, then commit and push the branch
2. Tag and push, e.g. `git tag v1.2.0 && git push origin v1.2.0`

The workflow builds the zip, attaches it to the release, checks the download, and only then updates `repo.xml`:

- a tag on a commit that is on `main` is a normal release and updates `repo.xml`
- a tag on a commit that is only on `Testing` is a pre-release and updates `repo-testing.xml`

Both files are on `main` (the workflow commits them there), so merging `Testing` into `main` never publishes a test version by accident. Push the branch before the tag, and pull before your next push to `main`. Don't edit the version, URL or SHA in either file by hand.

Work happens on `Development`. To publish a test build, merge `Development` into `Testing` and tag there; a tag on `Development` alone is refused. Test builds towards 2.0 are numbered 1.9.0, 1.9.1, … — plain numbers, so LMS always sees them as newer than 1.2 and older than 2.0. A published tag is never reused: a fix gets the next number.

To promote a tested version: merge `Testing` into `main` and push, then in the **Actions** tab run **Release** for the same tag. It reuses the zip you tested (same SHA), turns the pre-release into a normal release and updates `repo.xml`.

## Licence

GPL 3.0
