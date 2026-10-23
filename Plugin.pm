package Plugins::AlbumMix::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use Scalar::Util qw(blessed);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use Slim::Networking::SimpleAsyncHTTP;

use File::Spec;
use JSON::XS qw(decode_json);
use URI::Escape qw(uri_escape_utf8);

use constant LASTFM_API_BASE      => 'https://ws.audioscrobbler.com/2.0/';
use constant DEFAULT_MAX_HISTORY      => 50;
use constant DEFAULT_LOOKAHEAD        => 2;
use constant DEFAULT_ARTIST_COOLDOWN  => 5;    # skip artist for N album picks after playing
use constant MAX_SIMILAR_TRACKS       => 50;   # candidates from track.getSimilar
use constant MAX_SIMILAR_ARTISTS      => 20;   # fallback: artist.getSimilar
use constant MAX_TOP_ALBUMS           => 10;   # fallback: artist.getTopAlbums
use constant START_GUARD_SECS         => 60;   # max time to ignore "queue replaced" events while the seed album loads
use constant LOOKUP_TIMEOUT_SECS      => 120;  # a lookup still pending after this long is treated as stuck
use constant LASTFM_CACHE_MAX         => 2000; # most Last.fm answers kept in memory
use constant LASTFM_RETRY_DELAYS      => (2, 5);   # seconds before the 1st and 2nd retry of a failed Last.fm request
use constant PREFETCH_TRACKS          => 3;    # similar tracks whose album is asked for ahead of time
use constant LASTFM_MAX_PARALLEL      => 2;    # Last.fm requests running at the same time
use constant LASTFM_MAX_AHEAD_WAITING => 6;    # fetch-ahead requests that may wait for a free slot
use constant LASTFM_HTTP_TIMEOUT      => 15;   # seconds to wait for one Last.fm request
use constant LASTFM_BUDGET_SECS       => 30;   # no retry is started after this long for one question
use constant LASTFM_SAVE_DELAY_SECS   => 300;  # saved Last.fm answers are written to disk at most this often
use constant ONLINE_SEARCH_TIMEOUT_SECS => 20; # an online service that doesn't answer in time is skipped
use constant ALBUM_ARRIVAL_SECS       => 60;   # how long to wait for a queued online album to appear in the queue
use constant DSTM_ALBUM_MIN_TRACKS    => 3;    # Don't Stop The Music: the queue ends with an album if its last this-many tracks share one
use constant DSTM_SEED_TRACKS         => 5;    # Don't Stop The Music: otherwise the seed is one of the last this-many tracks
use constant DEFAULT_VARIETY          => 10;   # pick at random among this many of the closest matches
use constant DEFAULT_REPEAT_DAYS      => 30;   # don't queue an album again within this many days
use constant DEFAULT_MIN_TRACKS       => 5;    # albums with fewer tracks count as singles/EPs
use constant MAX_SAVED_HISTORY        => 2000; # most albums kept in the saved history

# Accent folding ("Björk" = "Bjork") when Unicode::Normalize is available
my $canFoldAccents = eval { require Unicode::Normalize; 1 };

# Album titles that mark a release as something other than a studio album.
# Matched against the lower-case title, brackets included.
my %RELEASE_TYPE_PATTERNS = (
	compilation => qr{
		\bgreatest\s+hits\b | \bbest\s+of\b | \bvery\s+best\b
		| ^(?:the\s+)?hits\b | \b(?:biggest|number\s+ones?|smash|top)\s+hits\b
		| \bcollection$ | \bthe\s+collection\b | \bcollection\s+of\b
		| \banthology\b | \bthe\s+essential\b | \bessentials\b | \bb-sides\b | \brarities\b
		| \bnow\s+that'?s\s+what\s+i\s+call\b
		| \boriginal\s+(?:motion\s+picture\s+)?soundtrack\b | \bsoundtrack\)? \s* $ | [\(\[]\s*soundtrack
		| \boriginal\s+(?:motion\s+picture|score|cast\s+recording)\b
		| \bmusic\s+from\s+(?:and\s+inspired\s+by\s+)?the\s+(?:motion\s+picture|film|movie|series|tv|television|original)\b
		| \bkaraoke\b | \btribute\s+to\b
	}x,
	live => qr{
		(?:^|[\(\[:\-]\s*)live\s+(?:at|in|from)\b | [\(\[]\s*live\b | \s-\s+live\b | \blive\s+\d{4}\b
		| \bin\s+concert\b | \bunplugged\b | \blive\s+(?:album|recordings?|sessions?)\b | \bbbc\s+sessions\b
	}x,
	single => qr{
		\s-\s+single$ | \s-\s+ep$ | [\(\[]\s*(?:single|ep)\s*[\)\]] | \bep$ | \bremix(?:es|ed)?\b
	}x,
);

# Settings that can be set per player. Every other setting (Last.fm API
# key, album history size, repeat days, history scope) is server-wide.
# 'bool' settings are checkboxes (unticked = off); 'value' settings fall
# back to the server default when the player has no value of its own.
my %PLAYER_PREFS = (
	source              => 'value',
	filter_compilations => 'bool',
	filter_live         => 'bool',
	filter_singles      => 'bool',
	min_tracks          => 'value',
	variety             => 'value',
	artist_cooldown     => 'value',
	lookahead           => 'value',
	include_seed        => 'bool',
);

# Where to look for albums (the Source setting)
my %SOURCES = map { $_ => 1 } qw(library_only library_first online_first online_only);

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.albummix',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_ALBUM_MIX',
});

my $prefs = preferences('plugin.albummix');

# Per-player state, keyed by client id
my %playerState;

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(@_);

	$prefs->init({
		lastfm_api_key    => '',
		max_history       => DEFAULT_MAX_HISTORY,
		prefer_local      => 1,
		discover_new      => 0,
		lookahead         => DEFAULT_LOOKAHEAD,
		artist_cooldown   => DEFAULT_ARTIST_COOLDOWN,
		filter_compilations => 1,
		filter_live       => 1,
		filter_singles    => 1,
		min_tracks        => DEFAULT_MIN_TRACKS,
		variety           => DEFAULT_VARIETY,
		repeat_days       => DEFAULT_REPEAT_DAYS,
		played_albums     => {},   # saved history: album key => time it was last queued
		history_scope     => 'shared',   # 'shared' = one saved history for all players, 'player' = one per player
		include_seed      => 1,          # play the album/track/artist the mix starts from (0: start with the first similar album)
	});

	# Source replaces Prefer Local Library + Discovery Mode (1.9.0). On the
	# first start after upgrading, it is set from those two settings, which
	# are kept (and kept in step, see Settings.pm) so going back to 1.2
	# still works.
	# If 1.2 was used again in between and its settings were changed there,
	# Source is set from them again.
	my $legacy = _legacyPrefsKey();
	if ( !$SOURCES{ $prefs->get('source') // '' }
		|| ( defined $prefs->get('legacy_synced') && $prefs->get('legacy_synced') ne $legacy ) ) {
		my $source = $prefs->get('discover_new') ? 'online_only'
			: $prefs->get('prefer_local')        ? 'library_first'
			:                                      'online_first';
		$prefs->set('source', $source);
		$prefs->set('legacy_synced', $legacy);
		$log->info("Album Mix: Source set to '$source' from the 1.2 settings");
	}

	$prefs->setValidate({ validator => 'intlimit', low => 0, high => 50 },   'min_tracks');
	$prefs->setValidate({ validator => 'intlimit', low => 1, high => 50 },   'variety');
	$prefs->setValidate({ validator => 'intlimit', low => 0, high => 3650 }, 'repeat_days');
	$prefs->setValidate({ validator => 'intlimit', low => 0, high => 50 },   'artist_cooldown');
	$prefs->setValidate({ validator => 'intlimit', low => 1, high => 50 },   'lookahead');

	# Load and register the settings pages: server-wide, and per player
	eval { require Plugins::AlbumMix::Settings };
	if ( !$@ ) {
		Plugins::AlbumMix::Settings->new;
	} else {
		$log->warn("Could not load AlbumMix settings: $@");
	}

	eval { require Plugins::AlbumMix::PlayerSettings };
	if ( !$@ ) {
		Plugins::AlbumMix::PlayerSettings->new;
	} else {
		$log->warn("Could not load AlbumMix player settings: $@");
	}

	# Context menu items: albums, tracks (including Now Playing) and artists
	Slim::Menu::AlbumInfo->registerInfoProvider( albummix_create => (
		after => 'addalbum',
		func  => \&albumInfoHandler,
	));

	Slim::Menu::TrackInfo->registerInfoProvider( albummix_track => (
		after => 'addtrack',
		func  => \&trackInfoHandler,
	));

	Slim::Menu::ArtistInfo->registerInfoProvider( albummix_artist => (
		after => 'addartist',
		func  => \&artistInfoHandler,
	));

	# Subscribe to playlist newsong events for album transition detection
	Slim::Control::Request::subscribe(
		\&onPlaylistChange,
		[['playlist'], ['newsong']],
	);

	# Subscribe to events that clear or replace the queue, so an active
	# mix stops when the user moves on to something else
	Slim::Control::Request::subscribe(
		\&onPlaylistReplaced,
		[['playlist'], ['clear', 'load', 'play', 'loadtracks', 'playtracks', 'loadalbum', 'playalbum']],
	);

	# Register CLI commands
	Slim::Control::Request::addDispatch(
		['albummix', 'start'],
		[1, 0, 1, \&cliStart],
	);

	Slim::Control::Request::addDispatch(
		['albummix', 'stop'],
		[1, 0, 0, \&cliStop],
	);

	# Last.fm answers saved before the last restart
	_loadLastfmCache();

	$log->info("Album Mix plugin initialised");
	return $class;
}

# After all plugins have started: offer Album Mix as a Don't Stop The Music
# provider (chosen per player under Settings > Player > Don't Stop The Music)
sub postinitPlugin {
	return unless Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin');

	eval {
		require Slim::Plugin::DontStopTheMusic::Plugin;
		Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_ALBUM_MIX', \&dontStopTheMusic);
		1;
	} or $log->warn("Album Mix: Could not register with Don't Stop The Music: $@");
}

sub shutdownPlugin {
	eval { Slim::Plugin::DontStopTheMusic::Plugin->unregisterHandler('PLUGIN_ALBUM_MIX') }
		if Slim::Plugin::DontStopTheMusic::Plugin->can('unregisterHandler');
	Slim::Control::Request::unsubscribe(\&onPlaylistChange);
	Slim::Control::Request::unsubscribe(\&onPlaylistReplaced);
	_saveLastfmCache() if _lastfmCacheDirty();
	_lastfmReset();
	%playerState = ();
}

sub getDisplayName { return 'PLUGIN_ALBUM_MIX' }

# ============================================================
# Context menu handlers
# ============================================================

sub albumInfoHandler {
	my ( $client, $url, $album, $remoteMeta, $tags, $filter ) = @_;

	return unless $client;

	my ( $albumName, $artistName, $albumId );

	if ( $album && blessed($album) ) {
		$albumName = $album->title || $album->name;
		$albumId   = $album->id;

		# Get album artist
		if ( $album->can('artistsForRoles') ) {
			my @artists = $album->artistsForRoles('ALBUMARTIST');
			@artists = $album->artistsForRoles('ARTIST') unless @artists;
			$artistName = $artists[0]->name if @artists;
		}

		# Fallback: try the contributor relation directly
		if ( !$artistName && $album->can('contributor') ) {
			my $contrib = $album->contributor;
			$artistName = $contrib->name if $contrib && blessed($contrib);
		}
	}

	# Try remoteMeta for online service albums
	if ( $remoteMeta ) {
		$albumName  ||= $remoteMeta->{album};
		$artistName ||= $remoteMeta->{artist};
	}

	return unless $albumName && $artistName;

	return _menuItems($client, _menuItem($client, 'PLUGIN_ALBUM_MIX_CREATE', 'start', {
		mode        => 'album',
		album_name  => $albumName,
		artist_name => $artistName,
		album_id    => $albumId || 0,
	}));
}

# Track context menu (also what Now Playing shows for the current song):
# "Create Album Mix from This Track", and for the song that is playing
# right now "Continue as Album Mix" (keep the queue, add similar albums
# after the current album).
sub trackInfoHandler {
	my ( $client, $url, $track, $remoteMeta, $tags, $filter ) = @_;

	return unless $client;

	my %params = ( mode => 'track' );

	if ( $track && blessed($track) ) {
		my $info = _trackDetails($client, $track);
		$params{track_title} = $info->{title};
		$params{artist_name} = $info->{artist};
		$params{album_name}  = $info->{album};
		$params{track_id}    = $track->id if $track->can('id') && $track->can('remote') && !$track->remote && $track->id;
		$url ||= $track->url if $track->can('url');
	}

	if ( $remoteMeta ) {
		$params{track_title} ||= $remoteMeta->{title};
		$params{artist_name} ||= $remoteMeta->{artist};
		$params{album_name}  ||= $remoteMeta->{album};
	}

	$params{track_url} = $url if $url;

	return unless $params{track_title} && $params{artist_name};

	my @items = ( _menuItem($client, 'PLUGIN_ALBUM_MIX_CREATE_TRACK', 'start', \%params) );

	# Radio streams never end, so an album added after one would never play
	my $isStream = $track && blessed($track) && $track->can('remote') && $track->remote
		&& !( $track->can('secs') && $track->secs );

	if ( $url && !$isStream && _isPlayingNow($client, $url) ) {
		push @items, _menuItem($client, 'PLUGIN_ALBUM_MIX_CONTINUE', 'start', { mode => 'continue' }, 'parent');
	}

	return _menuItems($client, @items);
}

# Artist context menu: "Create Album Mix from This Artist"
sub artistInfoHandler {
	my ( $client, $url, $artist, $remoteMeta, $tags, $filter ) = @_;

	return unless $client;

	my $artistName;
	if ( $artist && blessed($artist) ) {
		$artistName = $artist->can('name') ? $artist->name : undef;
	} elsif ( defined $artist && !ref $artist ) {
		$artistName = $artist;
	}
	$artistName ||= $remoteMeta->{artist} || $remoteMeta->{name} if $remoteMeta;

	return unless $artistName;

	return _menuItems($client, _menuItem($client, 'PLUGIN_ALBUM_MIX_CREATE_ARTIST', 'start', {
		mode        => 'artist',
		artist_name => $artistName,
	}));
}

# One context menu entry that runs an "albummix ..." command
sub _menuItem {
	my ( $client, $label, $cmd, $params, $nextWindow ) = @_;

	return {
		name => cstring($client, $label),
		type => 'redirect',
		jive => {
			nextWindow => $nextWindow || 'nowPlaying',
			actions    => {
				go => {
					player => 0,
					cmd    => ['albummix', $cmd],
					( $params ? ( params => $params ) : () ),
				},
			},
		},
		favorites => 0,
	};
}

# The entries for a context menu, plus "Stop Album Mix" while a mix is
# active on this player. A single entry is returned on its own (as LMS
# expects from an info provider), several as a list.
sub _menuItems {
	my ( $client, @items ) = @_;

	if ( _mixRunning($client->master->id) ) {
		push @items, _menuItem($client, 'PLUGIN_ALBUM_MIX_STOP', 'stop', undef, 'parent');
	}

	return @items == 1 ? $items[0] : \@items;
}

# Is this the song currently playing on the player?
sub _isPlayingNow {
	my ( $client, $url ) = @_;

	my $playing = eval {
		my $index = Slim::Player::Source::playingSongIndex($client);
		my $track = defined $index ? Slim::Player::Playlist::track($client, $index) : undef;
		$track && blessed($track) && $track->can('url') ? $track->url : undef;
	};

	return $playing && $playing eq $url;
}

# ============================================================
# CLI handlers
# ============================================================

# albummix start mode:<album|track|artist|continue> ...
#   album:    album_name, artist_name, album_id (library albums)
#   track:    track_title, artist_name, album_name, track_id or track_url
#   artist:   artist_name
#   continue: keep the current queue and add similar albums after it
# Without mode, album is assumed (as in 1.2).
sub cliStart {
	my $request = shift;
	my $client  = $request->client;
	return unless $client;

	_startMix($client, {
		mode       => $request->getParam('mode') || 'album',
		album      => $request->getParam('album_name'),
		artist     => $request->getParam('artist_name'),
		albumId    => $request->getParam('album_id') || 0,
		trackTitle => $request->getParam('track_title'),
		trackId    => $request->getParam('track_id') || 0,
		trackUrl   => $request->getParam('track_url'),
	});

	$request->setStatusDone;
}

sub cliStop {
	my $request = shift;
	my $client  = $request->client;
	return unless $client;

	stopAlbumMix($client);
	$request->setStatusDone;
}

# ============================================================
# Album Mix engine
# ============================================================

# Start from an album (kept for callers of the 1.2 interface)
sub startAlbumMix {
	my ( $client, $albumName, $artistName, $albumId ) = @_;

	_startMix($client, { mode => 'album', album => $albumName, artist => $artistName, albumId => $albumId });
}

# Start a mix. $seed->{mode} says where from:
#   album    — the album; with Include Seed it plays first, without it the
#              first similar album plays straight away
#   track    — the track; with Include Seed it plays first, without it the
#              first album similar to that track plays straight away
#   artist   — with Include Seed one of the artist's own albums plays first
#              (Last.fm top albums, same filters as other picks), without
#              it an album by a similar artist plays straight away
#   continue — nothing is loaded: the current queue keeps playing and
#              similar albums are added after the album playing now
sub _startMix {
	my ( $client, $seed ) = @_;

	$client = $client->master;
	my $clientId = $client->id;
	my $mode     = $seed->{mode} || 'album';

	my $state = _newState($client, $seed->{artist}, $seed->{album});

	return _continueMix($client, $state) if $mode eq 'continue';

	my $include = _pref($client, 'include_seed') ? 1 : 0;

	# Leaving out the seed needs Last.fm to find what to play instead
	if ( !$include && !$prefs->get('lastfm_api_key') ) {
		$log->warn("Album Mix: No Last.fm API key, so the seed is played after all");
		$include = 1;
	}

	$log->info("Starting Album Mix from $mode: "
		. join(' / ', grep { $_ } $seed->{trackTitle}, $seed->{album}, $seed->{artist})
		. ($include ? '' : ' (seed not played)'));

	_addArtistToHistory($clientId, $seed->{artist}) if $seed->{artist};

	# The seed's album counts as played in this mix either way, so it
	# isn't queued again straight after
	_addToHistory($clientId, $seed->{artist}, $seed->{album}) if $seed->{artist} && $seed->{album};

	_showBriefly($client, cstring($client, 'PLUGIN_ALBUM_MIX_STARTED') . ': '
		. ($seed->{trackTitle} || $seed->{album} || $seed->{artist} || ''));

	if ( $mode eq 'artist' ) {
		return $include
			? _startFromArtistAlbum($client, $state, $seed->{artist})
			: _startWithoutSeed($client, $state, { artistOnly => $seed->{artist} });
	}

	if ( $mode eq 'track' ) {
		return _startWithoutSeed($client, $state, { title => $seed->{trackTitle}, artist => $seed->{artist} })
			unless $include;

		if ( $seed->{trackId} ) {
			$client->execute(['playlistcontrol', 'cmd:load', "track_id:$seed->{trackId}"]);
		} elsif ( $seed->{trackUrl} ) {
			$client->execute(['playlist', 'play', $seed->{trackUrl}]);
		} else {
			$log->warn("Album Mix: Track has neither an id nor a URL, cannot play it");
			return stopAlbumMix($client);
		}
		$state->{seedLoaded} = 1;
		return;
	}

	# Album
	unless ( $include ) {
		return _albumSeedTrack($client, $state, $seed, sub {
			my $title = shift;
			return unless _isCurrent($clientId, $state);
			_startWithoutSeed($client, $state, $title
				? { title => $title, artist => $seed->{artist} }
				: { artistOnly => $seed->{artist} });
		});
	}

	if ( $seed->{albumId} ) {
		$client->execute(['playlistcontrol', 'cmd:load', "album_id:$seed->{albumId}"]);
		$state->{seedLoaded} = 1;
		_recordPlayed($client, $seed->{artist}, $seed->{album});
		return;
	}

	_findAndPlayAlbum($client, $seed->{artist}, $seed->{album}, 'load', sub {
		my $found = shift;
		return unless _isCurrent($clientId, $state);
		if ( $found ) {
			$state->{seedLoaded} = 1;
			_recordPlayed($client, $seed->{artist}, $seed->{album});
			return;
		}
		$log->warn("Album Mix: Could not load the seed album '$seed->{album}' by '$seed->{artist}'");
		stopAlbumMix($client);
	}, { isSeed => 1, isWanted => sub { _isCurrent($clientId, $state) } });
}

# Fresh state for a new mix on this player. Starting a new mix replaces any
# previous session for this player; callbacks still in flight from the old
# session detect this via _isCurrent() and stop.
sub _newState {
	my ( $client, $artist, $album, $dstm ) = @_;

	# A Don't Stop The Music request still waiting for an answer gets one
	if ( my $old = $playerState{ $client->id } ) {
		_dstmFinish($old, [], $client);
	}

	my $state = $playerState{ $client->id } = {
		active              => 1,
		history             => [],
		artist_history      => [],   # recent artists for cooldown enforcement
		skipped             => {},   # albums that failed to queue (not found / already owned) this session
		seedArtist          => $artist,
		seedAlbum           => $album,
		lastSeed            => undef,   # { title, artist } of the track the last lookup started from
		lastAlbumStartIndex => 0,    # playlist index where the last queued album begins
		pendingLookup       => 0,
		pendingSince        => 0,
		startedAt           => time(),
		# Loading the seed itself fires "queue replaced" events; ignore them
		# until the seed starts playing (or this time passes)
		guardUntil          => time() + START_GUARD_SECS,
		seedLoaded          => 0,    # set once the first album (or track) has been sent to the playlist
		firstLoad           => 0,    # 1 while the first album still has to replace the queue (seed not played)
		seenFirstSong       => 0,
		lookupId            => 0,    # increases with every lookup, so a timed-out one can't queue later
		client              => $client,   # the (master) player: its settings apply to the whole sync group
		dstm                => $dstm ? 1 : 0,   # only answers Don't Stop The Music: finds albums, doesn't queue them
	};

	if ( $dstm ) {
		$state->{seedLoaded} = 1;
		$state->{guardUntil} = 0;
		return $state;
	}

	# If nothing of the mix has reached the queue after this long (Last.fm
	# or an online service never answered), stop rather than waiting for ever
	eval {
		Slim::Utils::Timers::setTimer($client, time() + LOOKUP_TIMEOUT_SECS, sub {
			return unless _isCurrent($client->id, $state) && !$state->{seedLoaded};
			$log->warn("Album Mix: Nothing could be queued in time, stopping");
			stopAlbumMix($client);
		});
	};

	return $state;
}

# Seed not played: look up the first similar album straight away and let
# it replace the queue
sub _startWithoutSeed {
	my ( $client, $state, $seed ) = @_;

	$state->{firstLoad} = 1;
	_findNextAlbum($client, $client->id, $seed);
}

# Artist with Include Seed: play one of the artist's own albums first.
# Last.fm's top albums are tried in Variety order with the usual filters
# and saved history (but not the artist cooldown). If none can be played,
# the mix starts from a similar artist instead.
sub _startFromArtistAlbum {
	my ( $client, $state, $artist ) = @_;

	my $clientId = $client->id;
	my $apiKey   = $prefs->get('lastfm_api_key');

	unless ( $apiKey ) {
		$log->warn("Album Mix: No Last.fm API key, cannot find albums by '$artist'");
		_showBriefly($client, cstring($client, 'PLUGIN_ALBUM_MIX_NO_API_KEY'));
		return stopAlbumMix($client);
	}

	_getTopAlbums($client, $clientId, $artist, $apiKey, sub {
		my $albums = shift;
		return unless _isCurrent($clientId, $state);

		my @candidates = grep {
			!_releaseType($client, $_->{name}) && !_playedRecently($client, $artist, $_->{name})
		} @$albums;

		_tryArtistStartAlbum($client, $state, $artist, _varietyOrder($client, \@candidates, sub { 1 }), 0);
	});
}

sub _tryArtistStartAlbum {
	my ( $client, $state, $artist, $albums, $i ) = @_;

	my $clientId = $client->id;
	return unless _isCurrent($clientId, $state);

	if ( $i >= @$albums ) {
		$log->info("Album Mix: No album by '$artist' could be played, starting from a similar artist");
		return _startWithoutSeed($client, $state, { artistOnly => $artist });
	}

	my $album = $albums->[$i]->{name};
	_findAndPlayAlbum($client, $artist, $album, 'load', sub {
		my ( $found, undef, $title ) = @_;
		return unless _isCurrent($clientId, $state);
		return _tryArtistStartAlbum($client, $state, $artist, $albums, $i + 1) unless $found;

		$log->info("Album Mix: Starting with '$album' by '$artist'");
		$state->{seedAlbum}  = $album;
		$state->{seedLoaded} = 1;
		_addToHistory($clientId, $artist, $album);
		_recordPlayed($client, $artist, $album);
		_recordPlayed($client, $artist, $title) if $title && $title ne $album;
	}, {
		isSeed    => 1,
		isWanted  => sub { _isCurrent($clientId, $state) },
		minTracks => _minTracks($client),
		checkType => 1,
	});
}

# A track title from the album to use as the seed when the album itself
# isn't played: from the library when it is a library album, otherwise
# from Last.fm album.getInfo. Uses the same second-to-second-last rule as
# other seed tracks. Calls $callback->($title) or $callback->(undef).
sub _albumSeedTrack {
	my ( $client, $state, $seed, $callback ) = @_;

	if ( $seed->{albumId} ) {
		my $titles = eval {
			my $sth = Slim::Schema->dbh->prepare_cached(
				"SELECT title FROM tracks WHERE album = ? ORDER BY disc, tracknum, title");
			$sth->execute($seed->{albumId});
			my $t = [ map { $_->[0] } @{ $sth->fetchall_arrayref } ];
			$sth->finish;
			$t;
		} || [];

		if ( @$titles ) {
			return $callback->( $titles->[ _seedIndex(0, $#$titles) ] );
		}
	}

	_lastfm('album.getInfo', { artist => $seed->{artist} // '', album => $seed->{album} // '', autocorrect => 1 }, sub {
		my $result = shift;

		my $tracks = $result && ref $result->{album} eq 'HASH' && ref $result->{album}->{tracks} eq 'HASH'
			? $result->{album}->{tracks}->{track} : [];
		$tracks = [$tracks] if ref $tracks eq 'HASH';
		my @titles = grep { defined && length } map { ref $_ eq 'HASH' ? $_->{name} : undef } @{ $tracks || [] };

		$log->debug("Album Mix: album.getInfo gave " . scalar(@titles) . " tracks for '$seed->{album}'");
		$callback->( @titles ? $titles[ _seedIndex(0, $#titles) ] : undef );
	});
}

# "Continue as Album Mix": keep the current queue; when it is about to run
# out, similar albums are added, following on from the last album in it
sub _continueMix {
	my ( $client, $state ) = @_;

	my $index = eval { Slim::Player::Source::playingSongIndex($client) } // 0;
	my $count = Slim::Player::Playlist::count($client);

	unless ( $count ) {
		$log->info("Album Mix: Nothing is playing, nothing to continue");
		return stopAlbumMix($client);
	}

	# The mix follows on from the last album in the queue (the one playing
	# now, or one already queued after it): find where that album starts
	my $albumAt = sub {
		my $t = Slim::Player::Playlist::track($client, shift);
		return $t ? lc( _trackDetails($client, $t)->{album} || '' ) : '';
	};
	my $last  = $count - 1;
	my $name  = $albumAt->($last);
	my $start = $last;
	$start-- while $name && $start > 0 && $albumAt->($start - 1) eq $name;

	my $current = _trackDetails($client, Slim::Player::Playlist::track($client, $start));

	$state->{lastAlbumStartIndex} = $start;
	$state->{seedArtist}    = $current->{artist};
	$state->{seedAlbum}     = $current->{album};
	$state->{seedLoaded}    = 1;
	$state->{seenFirstSong} = 1;
	$state->{guardUntil}    = 0;   # nothing is loaded, so nothing to guard

	if ( $current->{artist} ) {
		_addArtistToHistory($client->id, $current->{artist});
		if ( $current->{album} ) {
			_addToHistory($client->id, $current->{artist}, $current->{album});
			_recordPlayed($client, $current->{artist}, $current->{album});
		}
	}

	$log->info("Album Mix: Continuing from '" . ($current->{album} // '?') . "' by '" . ($current->{artist} // '?') . "' (album starts at queue position $start)");
	_showBriefly($client, cstring($client, 'PLUGIN_ALBUM_MIX_STARTED') . ': ' . ($current->{album} || $current->{title} || ''));

	# Already close to the end of the queue: look up the next album now
	my $remaining = $count - $index - 1;
	_findNextAlbum($client, $client->id) if $remaining <= (_pref($client, 'lookahead') || DEFAULT_LOOKAHEAD);
}

sub _showBriefly {
	my ( $client, $text ) = @_;

	$client->showBriefly({
		jive => {
			type  => 'mixed',
			style => 'add',
			text  => [ $text ],
		},
	});
}

sub stopAlbumMix {
	my $client = shift;
	$client = $client->master;
	my $clientId = $client->id;

	my $state = $playerState{$clientId};

	if ( $state && $state->{active} ) {
		$state->{active} = 0;
		_dstmFinish($state, [], $client);

		# (Don't Stop The Music picks are not a mix the user started)
		return if $state->{dstm};

		$log->info("Album Mix stopped for player $clientId");
		_showBriefly($client, cstring($client, 'PLUGIN_ALBUM_MIX_STOPPED'));
	}
}

# Don't Stop The Music holds off while the user's own mix runs, unless that
# mix has run out of albums (nothing similar found, no API key): then it is
# the safety net again
sub _mixHoldsOffDSTM {
	my $clientId = shift;
	return _mixRunning($clientId) && !$playerState{$clientId}->{gaveUp} ? 1 : 0;
}

# True while the user's own Album Mix runs on this player (not when Album
# Mix only answers Don't Stop The Music)
sub _mixRunning {
	my $clientId = shift;
	my $state = $playerState{$clientId};
	return $state && $state->{active} && !$state->{dstm} ? 1 : 0;
}

# True if $state is still this player's active mix session. Async
# callbacks check this so that answers arriving after the mix was stopped,
# or after a new mix was started, are ignored.
sub _isCurrent {
	my ( $clientId, $state ) = @_;

	my $current = $playerState{$clientId};
	return $current && $state && $current == $state && $current->{active};
}

# ============================================================
# Don't Stop The Music provider
#
# When a queue is about to end, Don't Stop The Music asks the provider
# chosen for that player. Album Mix finds a similar album (with that
# player's Album Mix settings: Source, filters, Variety, Artist Cooldown,
# Saved History) and hands it back; Don't Stop The Music adds it.
# Played albums and the artist cooldown are remembered from one request
# to the next.
# ============================================================

# Don't Stop The Music asks for more: $callback->($client, \@urls)
sub dontStopTheMusic {
	my ( $client, $callback ) = @_;

	$client = $client->master;
	my $clientId = $client->id;

	# Always answer exactly once, or Don't Stop The Music stays busy
	my $answered = 0;
	my $answer = sub {
		my $urls = shift || [];
		return if $answered++;
		eval { $callback->($client, $urls); 1 }
			or $log->error("Album Mix: Answering Don't Stop The Music failed: $@");
	};

	# The user's own mix looks after this queue (see disableDSTM)
	return _answerQuietly($client, $answer) if _mixHoldsOffDSTM($clientId);

	# Anything going wrong before the request is under way must still be answered
	my $ok = eval { _dstmStart($client, $answer); 1 };
	unless ( $ok ) {
		$log->error("Album Mix: Don't Stop The Music request failed: $@");
		$answer->([]);

		# A lookup it may have started can't count any more
		my $state = $playerState{$clientId};
		$state->{lookupId}++ if $state && $state->{dstm};
	}
}

sub _dstmStart {
	my ( $client, $answer ) = @_;
	my $clientId = $client->id;

	unless ( $prefs->get('lastfm_api_key') ) {
		$log->warn("Album Mix: No Last.fm API key configured, can't help Don't Stop The Music");
		return $answer->([]);
	}

	my $seed = _dstmSeed($client);
	unless ( $seed ) {
		$log->info("Album Mix: Nothing in the queue to start from");
		return $answer->([]);
	}

	# Keep the session (played albums, artist cooldown) from earlier picks
	my $state = $playerState{$clientId};
	$state = _newState($client, $seed->{artist}, $seed->{album}, 1)
		unless $state && $state->{active} && $state->{dstm};

	_dstmFinish($state, []);   # an earlier request still waiting
	$state->{dstmAnswer} = $answer;
	$state->{seedArtist} = $seed->{artist};
	$state->{seedAlbum}  = $seed->{album};

	# What was just played isn't picked again straight away (usually the
	# album Album Mix picked last time, which is in the history already)
	if ( $seed->{album} && !grep { $_ eq _historyKey($seed->{artist}, $seed->{album}) } @{ $state->{history} } ) {
		_addToHistory($clientId, $seed->{artist}, $seed->{album});
	}
	my $artistKey = _nameKey($seed->{artist});
	_addArtistToHistory($clientId, $seed->{artist})
		unless @{ $state->{artist_history} } && $state->{artist_history}->[-1] eq $artistKey;

	# Albums that couldn't be found are tried again on the next request (a
	# service may have been down), as a new mix would
	$state->{skipped} = {};

	$log->info("Album Mix: Don't Stop The Music asks for more; starting from '$seed->{title}' by '$seed->{artist}'");

	# If nothing has been found in time, answer anyway (Don't Stop The Music
	# then plays something else), and don't let the late result count
	Slim::Utils::Timers::setTimer(undef, time() + LOOKUP_TIMEOUT_SECS, sub {
		return unless $state->{dstmAnswer} && $state->{dstmAnswer} == $answer;
		$log->warn("Album Mix: No album found in time for Don't Stop The Music");
		$state->{lookupId}++;
		$state->{pendingLookup} = 0;
		_dstmFinish($state, []);
	});

	_findNextAlbum($client, $clientId, { title => $seed->{title}, artist => $seed->{artist} });
}

# Hand the album found (or nothing) to a waiting Don't Stop The Music request.
# With $client, the request was only cut short (the user started or stopped
# a mix): see _answerQuietly.
sub _dstmFinish {
	my ( $state, $urls, $client ) = @_;
	my $answer = $state && delete $state->{dstmAnswer};
	return unless $answer;
	return _answerQuietly($client, $answer) if $client;
	$answer->($urls || []);
}

# Answer Don't Stop The Music with nothing, without it falling back to
# Random Play: when it gets an empty answer it adds 'randomplay://' to the
# queue, which is removed again here. (Don't Stop The Music must always be
# answered, or it stays busy on that player.)
sub _answerQuietly {
	my ( $client, $answer ) = @_;

	my $before = Slim::Player::Playlist::count($client);
	$answer->([]);

	for ( my $i = Slim::Player::Playlist::count($client) - 1; $i >= $before; $i-- ) {
		my $url = _trackUrl( Slim::Player::Playlist::track($client, $i) ) // '';
		next unless $url =~ /^randomplay:/;
		$log->debug("Album Mix: Removing Don't Stop The Music's fallback $url");
		$client->execute(['playlist', 'delete', $i]);
	}
}

# Don't Stop The Music must not add music while the user's own Album Mix
# runs on this player (Album Mix adds the next album itself). LMS asks
# plugins marked canConflictWithDSTM in install.xml.
sub disableDSTM {
	my ( $class, $client ) = @_;
	return 0 unless $client;
	return _mixHoldsOffDSTM($client->master->id);
}

# The track to start from: if the queue ends with an album, a track from it
# (as for Album Mix); otherwise, e.g. a playlist of different artists, one
# of its last few tracks at random, so the pick follows the recent mood
# rather than always the very last song. Returns { title, artist, album }.
sub _dstmSeed {
	my $client = shift;

	my $count = Slim::Player::Playlist::count($client);
	return unless $count;

	my %info;
	my $details = sub {
		my $i = shift;
		$info{$i} ||= _trackDetails($client, Slim::Player::Playlist::track($client, $i));
	};

	my $last  = $count - 1;
	my $album = lc( $details->($last)->{album} || '' );
	my $start = $last;
	$start-- while $album && $start > 0 && lc( $details->($start - 1)->{album} || '' ) eq $album;

	if ( $album && $last - $start + 1 >= DSTM_ALBUM_MIN_TRACKS ) {
		my $t = $details->( _seedIndex($start, $last) );
		return { title => $t->{title}, artist => $t->{artist}, album => $t->{album} }
			if $t->{title} && $t->{artist};
	}

	my $from = $count - DSTM_SEED_TRACKS;
	$from = 0 if $from < 0;
	my @candidates = grep { $_->{title} && $_->{artist} } map { $details->($_) } $from .. $last;
	return unless @candidates;

	my $t = $candidates[ int(rand(@candidates)) ];
	return { title => $t->{title}, artist => $t->{artist}, album => $t->{album} };
}

# ============================================================
# Playlist event handler
# ============================================================

sub onPlaylistChange {
	my $request = shift;
	my $client  = $request->client || return;

	$client = $client->master;
	my $clientId = $client->id;

	my $state = $playerState{$clientId};
	return unless $state && $state->{active};

	# Don't Stop The Music decides itself when to ask for more
	return if $state->{dstm};

	# The first song of the mix has started: the seed album has finished
	# loading, so end the start-up guard shortly after. (A song change
	# before the seed was even sent — e.g. the previous queue moving on
	# while an online seed is still being searched — doesn't count.)
	if ( $state->{seedLoaded} && !$state->{seenFirstSong} ) {
		$state->{seenFirstSong} = 1;
		my $until = time() + 2;
		$until = $state->{startedAt} + 5 if $state->{startedAt} + 5 > $until;
		$state->{guardUntil} = $until if $until < $state->{guardUntil};
	}

	# Nothing of the mix is in the queue yet (its first album is still being
	# looked up): songs changing in the old queue are not the mix's business
	return unless $state->{seedLoaded};

	if ( $state->{pendingLookup} ) {
		# A lookup is already running. If it has been pending for too long
		# (e.g. an online service never answered), assume it is stuck and
		# allow a new one rather than letting the mix stall for good.
		return if time() - ($state->{pendingSince} || 0) < LOOKUP_TIMEOUT_SECS;

		$log->warn("Album Mix: Previous lookup timed out, starting a new one");
		$state->{pendingLookup} = 0;
	}

	# An album found online was just queued, but the service hasn't added
	# its tracks yet: the queue still looks short, so wait for it rather
	# than queuing a second album
	if ( my $wait = $state->{awaitingAlbum} ) {
		if ( _albumArrived($client, $wait) ) {
			delete $state->{awaitingAlbum};
		} elsif ( time() - $wait->{since} < ALBUM_ARRIVAL_SECS ) {
			$log->debug("Album Mix: Waiting for the queued album to appear in the queue");
			return;
		} else {
			$log->warn("Album Mix: The queued album didn't appear in the queue, carrying on");
			delete $state->{awaitingAlbum};
		}
	}

	my $songIndex   = Slim::Player::Source::streamingSongIndex($client);
	my $playlistLen = Slim::Player::Playlist::count($client);
	my $lookahead   = _pref($client, 'lookahead') || DEFAULT_LOOKAHEAD;
	my $remaining   = $playlistLen - $songIndex - 1;

	# Halfway through the last queued album is time to look for the next
	# one, so it is ready well before the queue runs out (once per album)
	my ( $start, $end ) = _lastAlbumRange($client, $state, $playlistLen);
	my $halfway = $songIndex >= $start && $songIndex <= $end
		&& ($songIndex - $start + 1) * 2 >= ($end - $start + 1)
		&& ( !defined $state->{lookedUpForStart} || $state->{lookedUpForStart} != $start );

	$log->debug("Album Mix: song $songIndex of $playlistLen, $remaining remaining, last album at [$start..$end]");

	if ( $halfway || $remaining <= $lookahead ) {
		$log->info("Album Mix: " . ($halfway ? "halfway through the album" : "$remaining tracks left")
			. ", finding next similar album");
		$state->{lookedUpForStart} = $start;
		_findNextAlbum($client, $clientId);
	}
}

# The queue was cleared or replaced (e.g. the user started playing another
# album). Stop the mix so it doesn't keep appending albums to music the
# user chose. Events caused by loading the mix's own seed album are
# ignored while the start-up guard is active.
sub onPlaylistReplaced {
	my $request = shift;
	my $client  = $request->client || return;

	$client = $client->master;
	my $state = $playerState{$client->id};
	return unless $state && $state->{active};
	return if $state->{dstm};

	if ( time() < $state->{guardUntil} ) {
		$log->debug("Album Mix: Ignoring '" . $request->getRequestString . "' while the seed album loads");
		return;
	}

	$log->info("Album Mix: Queue was cleared or replaced, stopping the mix");
	stopAlbumMix($client);
}

# ============================================================
# Similar album discovery via Last.fm
#
# Primary:  track.getSimilar on a random track (second to
#           second-to-last) of the last queued album — finds
#           sonically similar tracks, then resolves each one's
#           album until one can actually be queued.
# Fallback: artist.getSimilar → artist.getTopAlbums when track
#           similarity returns nothing that can be queued.
#
# A candidate album is skipped when it was already played this
# session, its artist is on cooldown, it was already tried and
# couldn't be found, or (Discovery Mode) it is in the local
# library. Albums are only added to the history once they have
# actually been queued.
# ============================================================

# $seed (optional) gives the starting point instead of a track from the
# queue: { title, artist } for a seed track, or { artistOnly } to go
# straight to similar artists. Used when the mix starts without playing
# its seed.
sub _findNextAlbum {
	my ( $client, $clientId, $seed ) = @_;

	my $state = $playerState{$clientId};
	return unless $state && $state->{active};

	$state->{pendingLookup} = 1;
	$state->{pendingSince}  = time();
	$state->{lookupId}++;

	my $apiKey = $prefs->get('lastfm_api_key');
	unless ( $apiKey ) {
		$log->warn("Album Mix: No Last.fm API key configured");
		_showBriefly($client, cstring($client, 'PLUGIN_ALBUM_MIX_NO_API_KEY'));
		$state->{pendingLookup} = 0;
		$state->{gaveUp} = 1;
		return;
	}

	if ( $seed && $seed->{artistOnly} ) {
		$state->{lastSeed} = undef;
		return _findNextAlbumByArtist($client, $clientId, $seed->{artistOnly}, $apiKey, $state->{lookupId});
	}

	# --- The seed track: given, or a track from the last queued album ---
	my ( $seedTrack, $seedArtist ) = $seed ? ( $seed->{title}, $seed->{artist} ) : _getSeedTrack($client, $clientId);

	if ( $seedTrack && $seedArtist ) {
		$log->info("Album Mix: Seed track '$seedTrack' by '$seedArtist'");
		$state->{lastSeed} = { title => $seedTrack, artist => $seedArtist };

		my $lookupId = $state->{lookupId};
		_getSimilarTracks($client, $clientId, $seedArtist, $seedTrack, $apiKey, sub {
			my $similarTracks = shift;

			return unless _isCurrent($clientId, $state);

			if ( $similarTracks && @$similarTracks ) {
				# Try to pick an album from these similar tracks
				_pickAlbumFromSimilarTracks($client, $clientId, $similarTracks, $apiKey, $lookupId);
			} else {
				$log->info("Album Mix: No similar tracks found, falling back to artist similarity");
				_findNextAlbumByArtist($client, $clientId, $state->{seedArtist}, $apiKey, $lookupId);
			}
		});
	} else {
		# Can't determine current track — fall back to artist similarity
		$log->info("Album Mix: Could not extract seed track, falling back to artist similarity");
		_findNextAlbumByArtist($client, $clientId, $state->{seedArtist}, $apiKey, $state->{lookupId});
	}
}

# Pick a random track from the last queued album (between its second and
# second-to-last track) to use as the seed for similarity lookups.
sub _getSeedTrack {
	my ( $client, $clientId ) = @_;

	my $playlistLen = Slim::Player::Playlist::count($client);
	return unless $playlistLen;

	my $state = $playerState{$clientId};
	my ( $albumStart, $albumEnd ) = _lastAlbumRange($client, $state, $playlistLen);
	my $albumTrackCount = $albumEnd - $albumStart + 1;

	my $targetIndex = _seedIndex($albumStart, $albumEnd);

	$log->debug("Album Mix: Seed track — album range [$albumStart..$albumEnd], picked index $targetIndex");

	my $track = Slim::Player::Playlist::track($client, $targetIndex);
	return unless $track;

	my $info = _trackDetails($client, $track);
	return ( $info->{title}, $info->{artist} );
}

# Which track of an album (positions $first..$last) to use as the seed: a
# random one between the second and the second-to-last track, as the first
# and last are often intros, outros or hidden tracks. With 2 or 3 tracks
# it is the second, with 1 the only one.
sub _seedIndex {
	my ( $first, $last ) = @_;

	my $count = $last - $first + 1;
	return $first + 1 + int(rand($count - 2)) if $count >= 4;
	return $first + 1 if $count >= 2;
	return $first;
}

# Work out where the last queued album sits in the playlist.
#
# The start is recorded when the album is queued. The end can't be
# recorded at that point because online albums are added asynchronously,
# so it is found here instead: starting at the recorded start, the album
# runs for as long as consecutive tracks carry the same album name. Any
# tracks the user added after it are therefore not used as seeds.
sub _lastAlbumRange {
	my ( $client, $state, $playlistLen ) = @_;

	my $last  = $playlistLen - 1;
	my $start = ($state && defined $state->{lastAlbumStartIndex})
		? $state->{lastAlbumStartIndex} : 0;

	my $albumAt = sub {
		my $t = Slim::Player::Playlist::track($client, shift);
		return $t ? lc( _trackDetails($client, $t)->{album} || '' ) : '';
	};

	if ( $start > $last ) {
		# The recorded start no longer exists (tracks were removed). Use the
		# block of same-album tracks at the end of the playlist instead.
		my $name = $albumAt->($last);
		return ( $last, $last ) unless $name;
		$start = $last;
		$start-- while $start > 0 && $albumAt->($start - 1) eq $name;
		return ( $start, $last );
	}

	my $name = $albumAt->($start);

	# Without an album name we can't tell where the album ends, so assume
	# it runs to the end of the playlist
	return ( $start, $last ) unless $name;

	my $end = $start;
	$end++ while $end < $last && $albumAt->($end + 1) eq $name;

	return ( $start, $end );
}

# Title, artist and album name for a playlist track. Uses the library
# metadata first, then asks the track's service plugin (e.g. TIDAL) for
# anything missing.
sub _trackDetails {
	my ( $client, $track ) = @_;

	my %info = ( title => undef, artist => undef, album => undef );
	return \%info unless blessed($track);

	$info{title} = $track->title;

	if ( $track->can('artistName') ) {
		$info{artist} = $track->artistName;
	}
	if ( !$info{artist} && $track->can('artist') ) {
		my $a = $track->artist;
		$info{artist} = $a->name if $a && blessed($a);
	}

	if ( $track->can('album') ) {
		my $album = $track->album;
		if ( blessed($album) && $album->can('title') ) {
			$info{album} = $album->title;
		} elsif ( defined $album && !ref $album ) {
			$info{album} = $album;
		}
	}
	if ( !$info{album} && $track->can('albumname') ) {
		$info{album} = $track->albumname;
	}

	# Try remote metadata if local metadata is missing
	if ( (!$info{title} || !$info{artist} || !$info{album}) && $track->can('url') ) {
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($track->url);
		if ( $handler && $handler->can('getMetadataFor') ) {
			my $meta = $handler->getMetadataFor($client, $track->url);
			if ( $meta ) {
				$info{title}  ||= $meta->{title};
				$info{artist} ||= $meta->{artist};
				$info{album}  ||= $meta->{album};
			}
		}
	}

	return \%info;
}

# ============================================================
# Primary: track.getSimilar based discovery
# ============================================================

sub _getSimilarTracks {
	my ( $client, $clientId, $artist, $track, $apiKey, $callback ) = @_;

	$log->debug("Album Mix: Fetching similar tracks for '$track' by '$artist'");

	_lastfm('track.getSimilar', {
		artist      => $artist,
		track       => $track,
		limit       => MAX_SIMILAR_TRACKS,
		autocorrect => 1,
	}, sub {
		my $result = shift;

		my @tracks;
		my $similar = $result && ref $result->{similartracks} eq 'HASH' ? $result->{similartracks}->{track} : [];
		$similar = [$similar] if ref $similar eq 'HASH';

		for my $t ( @{ $similar || [] } ) {
			next unless ref $t eq 'HASH' && $t->{name} && $t->{artist} && $t->{artist}->{name};

			push @tracks, {
				title  => $t->{name},
				artist => $t->{artist}->{name},
				match  => $t->{match} || 0,
				mbid   => $t->{mbid}  || '',
			};
		}

		$log->info("Album Mix: Found " . scalar(@tracks) . " similar tracks");
		$callback->(\@tracks);
	});
}

# Walk the similar tracks and queue the first album that passes the
# checks and can actually be found. track.getInfo is used to find which
# album each candidate track belongs to.
#
# The order isn't strictly closest-first: the closest few (see Variety)
# are shuffled, with closer matches more likely to come first, so the
# same seed doesn't always lead to the same album.
sub _pickAlbumFromSimilarTracks {
	my ( $client, $clientId, $similarTracks, $apiKey, $lookupId ) = @_;

	my $ordered = _varietyOrder($client, $similarTracks, sub { $_[0]->{match} });

	_tryNextSimilarTrack($client, $clientId, $ordered, 0, $apiKey, $lookupId);
}

# True if $lookupId (when given) is a lookup that timed out and has been
# replaced by a newer one: its search should stop rather than keep asking
# Last.fm for albums it may no longer queue
sub _staleLookup {
	my ( $state, $lookupId ) = @_;
	return 0 unless defined $lookupId && $lookupId != $state->{lookupId};
	$log->debug("Album Mix: Dropping a timed-out lookup");
	return 1;
}

sub _tryNextSimilarTrack {
	my ( $client, $clientId, $tracks, $index, $apiKey, $lookupId ) = @_;

	my $state = $playerState{$clientId};
	return unless $state && $state->{active};
	return if _staleLookup($state, $lookupId);

	if ( $index >= scalar @$tracks ) {
		# Exhausted all similar tracks — fall back to artist similarity
		$log->info("Album Mix: No suitable album from similar tracks, falling back to artist similarity");
		_findNextAlbumByArtist($client, $clientId, $state->{seedArtist}, $apiKey, $lookupId);
		return;
	}

	my $track = $tracks->[$index];
	my $next  = sub { _tryNextSimilarTrack($client, $clientId, $tracks, $index + 1, $apiKey, $lookupId) };

	$log->debug("Album Mix: Checking similar track '$track->{title}' by '$track->{artist}' (match: $track->{match})");

	# Skip the Last.fm lookup entirely if the artist is on cooldown
	if ( _isArtistOnCooldown($clientId, $track->{artist}) ) {
		$log->debug("Album Mix: '$track->{artist}' on cooldown, skipping");
		$next->();
		return;
	}

	_getTrackAlbum($client, $clientId, $track->{artist}, $track->{title}, $apiKey, sub {
		my $albumName = shift;

		return unless _isCurrent($clientId, $state);
		return if _staleLookup($state, $lookupId);

		unless ( $albumName ) {
			# No album info for this track — try the next similar track
			$next->();
			return;
		}

		if ( my $reason = _skipReason($clientId, $track->{artist}, $albumName) ) {
			$log->debug("Album Mix: Skipping '$albumName' by '$track->{artist}' ($reason)");
			$next->();
			return;
		}

		_queueCandidate($client, $clientId, $track->{artist}, $albumName, {
			kind       => 'track',
			track      => $track->{title},
			trackArtist => $track->{artist},
			match      => $track->{match},
			seed       => $state->{lastSeed},
		}, $next);
	});

	# Ask Last.fm about the next few candidates already, so their answers
	# are ready (cached) by the time they are needed
	_prefetchTrackInfo($clientId, $tracks, $index + 1);
}

# No album could be found. If nothing of the mix has played yet (seed not
# played), stop: there is nothing to continue from.
sub _nothingFound {
	my ( $client, $state ) = @_;

	_showBriefly($client, cstring($client, 'PLUGIN_ALBUM_MIX_NO_SIMILAR'));
	$state->{gaveUp} = 1;
	_dstmFinish($state, []);
	stopAlbumMix($client) if $state->{firstLoad};
}

# Why an album was picked, for the log:
#   track:  its track 'X' by Y is similar to 'Seed' by Z (match 0.83)
#   artist: Y is an artist similar to Z (match 0.61)
sub _whyText {
	my $why = shift || {};

	my $match = defined $why->{match} ? sprintf(' (Last.fm match %.2f)', $why->{match}) : '';

	if ( ($why->{kind} // '') eq 'track' ) {
		my $seed = $why->{seed};
		return "its track '$why->{track}' by $why->{trackArtist} is similar to "
			. ($seed ? "'$seed->{title}' by $seed->{artist}" : 'the last album') . $match;
	}
	if ( ($why->{kind} // '') eq 'artist' ) {
		return "artist similar to $why->{seedArtist}$match";
	}
	return 'picked by Album Mix';
}

# The short pop-up shown when an album is queued:
#   Queued Album — Artist, like "Seed track"
#   Queued Album — Artist, similar artist to Seed artist
sub _whyPopup {
	my ( $client, $album, $artist, $why ) = @_;

	# \x{2014} is an em dash, written as a character code because this file
	# has no "use utf8" and album names are character strings
	my $what = "$album \x{2014} $artist";
	$why ||= {};

	if ( ($why->{kind} // '') eq 'track' && $why->{seed} ) {
		return sprintf(cstring($client, 'PLUGIN_ALBUM_MIX_QUEUED_LIKE_TRACK'), $what, $why->{seed}->{title});
	}
	if ( ($why->{kind} // '') eq 'artist' && $why->{seedArtist} && lc($why->{seedArtist}) ne lc($artist) ) {
		return sprintf(cstring($client, 'PLUGIN_ALBUM_MIX_QUEUED_LIKE_ARTIST'), $what, $why->{seedArtist});
	}
	return sprintf(cstring($client, 'PLUGIN_ALBUM_MIX_QUEUED'), $what);
}

# Start track.getInfo requests for the next PREFETCH_TRACKS candidates
# (skipping artists on cooldown, which won't be looked at anyway). Answers
# go into the Last.fm cache; requests already cached or on their way are
# not repeated.
sub _prefetchTrackInfo {
	my ( $clientId, $tracks, $from ) = @_;

	my $todo = PREFETCH_TRACKS;
	for my $i ( $from .. $#$tracks ) {
		last unless $todo > 0;
		my $t = $tracks->[$i];
		next if _isArtistOnCooldown($clientId, $t->{artist});
		_lastfm('track.getInfo', _trackInfoParams($t->{artist}, $t->{title}), sub {}, { prefetch => 1 });
		$todo--;
	}
}

# Why a candidate album should not be queued, or undef if it's fine.
sub _skipReason {
	my ( $clientId, $artist, $album ) = @_;

	my $state = $playerState{$clientId} || return 'no active mix';
	my $key   = _historyKey($artist, $album);

	return 'already played this session'  if grep { $_ eq $key } @{$state->{history}};
	return "already tried: $state->{skipped}->{$key}" if $state->{skipped}->{$key};
	return 'artist on cooldown'           if _isArtistOnCooldown($clientId, $artist);

	if ( my $type = _releaseType($state->{client}, $album) ) {
		return "looks like a $type release";
	}

	if ( my $days = _playedRecently($state->{client}, $artist, $album) ) {
		return "played $days day" . ($days == 1 ? '' : 's') . " ago";
	}

	return;
}

# If the album title marks it as a release type that player's settings
# filter out, return that type ('compilation', 'live' or 'single/EP'),
# else undef. Only used for albums the mix picks, never for the album it
# starts from.
sub _releaseType {
	my ( $client, $title ) = @_;
	$title = lc( $title // '' );

	return 'compilation' if _pref($client, 'filter_compilations') && $title =~ $RELEASE_TYPE_PATTERNS{compilation};
	return 'live'        if _pref($client, 'filter_live')         && $title =~ $RELEASE_TYPE_PATTERNS{live};
	return 'single/EP'   if _pref($client, 'filter_singles')      && $title =~ $RELEASE_TYPE_PATTERNS{single};

	return;
}

# Minimum number of tracks for an album the mix picks, or 0 for no limit.
# Part of the singles/EP filter, so it is off when that filter is off.
sub _minTracks {
	my $client = shift;
	return 0 unless _pref($client, 'filter_singles');
	my $min = _pref($client, 'min_tracks');
	return defined $min ? $min : DEFAULT_MIN_TRACKS;
}

# Try to queue one candidate album. Only when it was actually found and
# added is it recorded in the history, the artist cooldown and as the
# new seed. If it can't be queued (not found anywhere, or already owned
# in Discovery Mode) it is remembered as skipped for this session and
# $onFail is called so the caller can move on to the next candidate.
sub _queueCandidate {
	my ( $client, $clientId, $artist, $album, $why, $onFail ) = @_;

	my $state = $playerState{$clientId};
	return unless $state && $state->{active};

	my $lookupId = $state->{lookupId};

	# Checked by the online searches just before they add anything, so a
	# search that answers after the mix was stopped or restarted, or after
	# this lookup timed out and a newer one began, doesn't queue an album
	my $isWanted = sub {
		_isCurrent($clientId, $state) && $lookupId == $state->{lookupId};
	};

	my $via = _whyText($why);

	# The first album of a mix that doesn't play its seed replaces the queue;
	# for Don't Stop The Music the album is only found, and handed over
	my $cmd = $state->{dstm} ? 'collect' : $state->{firstLoad} ? 'load' : 'add';
	my @found;

	$log->info("Album Mix: Trying '$album' by '$artist' ($via)");

	_findAndPlayAlbum($client, $artist, $album, $cmd, sub {
		my ( $found, $reason, $matchedTitle ) = @_;

		return unless _isCurrent($clientId, $state);

		# This lookup timed out and a newer one has started; let that one
		# decide what is queued next
		if ( $lookupId != $state->{lookupId} ) {
			$log->info("Album Mix: Ignoring late result for '$album' by '$artist' from a timed-out lookup");
			return;
		}

		unless ( $found ) {
			$reason ||= 'not found';
			$log->info("Album Mix: Could not queue '$album' by '$artist' ($reason), trying next candidate");
			$state->{skipped}->{ _historyKey($artist, $album) } = $reason;
			$onFail->();
			return;
		}

		$log->info("Album Mix: Queued '$album' by '$artist' ($via)");

		if ( $state->{firstLoad} ) {
			$state->{firstLoad}  = 0;
			$state->{seedLoaded} = 1;
		}

		$state->{seedArtist} = $artist;
		$state->{seedAlbum}  = $album;

		_addToHistory($clientId, $artist, $album);
		_addArtistToHistory($clientId, $artist);
		_recordPlayed($client, $artist, $album);

		# If the album found under that name has a different title (e.g.
		# Last.fm said "Abbey Road", TIDAL had "Abbey Road (Remastered)"),
		# remember that title too
		if ( $matchedTitle && _historyKey($artist, $matchedTitle) ne _historyKey($artist, $album) ) {
			_addToHistory($clientId, $artist, $matchedTitle);
			_recordPlayed($client, $artist, $matchedTitle);
		}

		$state->{pendingLookup} = 0;
		$state->{gaveUp}        = 0;

		_showBriefly($client, _whyPopup($client, $album, $artist, $why));
		_dstmFinish($state, \@found);
	}, {
		skipOwned => _pref($client, 'source') eq 'online_only' ? 1 : 0,
		isWanted  => $isWanted,
		minTracks => _minTracks($client),
		checkType => 1,
		collect   => \@found,
	});
}

# Resolve a track's album via Last.fm track.getInfo
sub _getTrackAlbum {
	my ( $client, $clientId, $artist, $track, $apiKey, $callback ) = @_;

	_lastfm('track.getInfo', _trackInfoParams($artist, $track), sub {
		my $result = shift;

		my $albumName;
		if ( $result && ref $result->{track} eq 'HASH' && ref $result->{track}->{album} eq 'HASH' ) {
			$albumName = $result->{track}->{album}->{title};
		}

		if ( $albumName ) {
			$log->debug("Album Mix: track.getInfo says '$track' is on album '$albumName'");
		} else {
			$log->debug("Album Mix: track.getInfo returned no album for '$track'");
		}

		$callback->($albumName);
	});
}

# The track.getInfo question for a track (also used to fetch ahead, so it
# must be exactly the same to be answered from the cache)
sub _trackInfoParams {
	my ( $artist, $track ) = @_;
	return { artist => $artist, track => $track, autocorrect => 1 };
}

# ============================================================
# Last.fm requests: one helper with a cache and retries
# ============================================================

# How long an answer is reused, per Last.fm method (seconds)
my %LASTFM_CACHE_TTL = (
	'track.getSimilar'    => 86400,
	'track.getInfo'       => 7 * 86400,
	'artist.getSimilar'   => 86400,
	'artist.getTopAlbums' => 86400,
	'album.getInfo'       => 7 * 86400,
);

# Last.fm error codes that mean "try again later": 8 operation failed,
# 11 service offline, 16 temporarily unavailable, 29 rate limit exceeded
my %LASTFM_RETRY_ERRORS = map { $_ => 1 } ( 8, 11, 16, 29 );

# Only the parts of each answer the plugin uses are kept (a full
# track.getSimilar answer is about 200 KB in memory, the trimmed one a
# fraction of that). The shape stays the same, always with lists.
sub _lfList {
	my ( $h, $outer, $inner ) = @_;
	my $l = ref $h eq 'HASH' && ref $h->{$outer} eq 'HASH' ? $h->{$outer}->{$inner} : undef;
	$l = [$l] if ref $l eq 'HASH';
	return [ grep { ref $_ eq 'HASH' } @{ ref $l eq 'ARRAY' ? $l : [] } ];
}

my %LASTFM_TRIM = (
	'track.getSimilar' => sub {
		return { similartracks => { track => [ map { {
			name   => $_->{name},
			match  => $_->{match},
			mbid   => $_->{mbid},
			artist => ref $_->{artist} eq 'HASH' ? { name => $_->{artist}->{name} } : undef,
		} } @{ _lfList($_[0], 'similartracks', 'track') } ] } };
	},
	'track.getInfo' => sub {
		my $t = $_[0]->{track};
		my $album = ref $t eq 'HASH' && ref $t->{album} eq 'HASH' ? $t->{album}->{title} : undef;
		return { track => ( defined $album ? { album => { title => $album } } : {} ) };
	},
	'artist.getSimilar' => sub {
		return { similarartists => { artist => [ map { {
			name => $_->{name}, match => $_->{match}, mbid => $_->{mbid},
		} } @{ _lfList($_[0], 'similarartists', 'artist') } ] } };
	},
	'artist.getTopAlbums' => sub {
		return { topalbums => { album => [ map { {
			name => $_->{name}, mbid => $_->{mbid}, playcount => $_->{playcount},
		} } @{ _lfList($_[0], 'topalbums', 'album') } ] } };
	},
	'album.getInfo' => sub {
		my $tracks = ref $_[0]->{album} eq 'HASH' && ref $_[0]->{album}->{tracks} eq 'HASH'
			? _lfList($_[0]->{album}, 'tracks', 'track') : [];
		return { album => { tracks => { track => [ map { { name => $_->{name} } } @$tracks ] } } };
	},
);

my %lastfmCache;      # question => { time, result }
my %lastfmPending;    # question => { method, url, callbacks, prefetch, attempt, started }
my @lastfmQueue;      # questions waiting for a free slot
my $lastfmRunning = 0;
my $lastfmGen     = 0;   # changes at shutdown, so older requests can't free newer slots
my $lastfmDirty   = 0;   # the cache has changed since it was last saved

# Ask Last.fm. $callback->($answer) gets the decoded answer (a hash, which
# may be an error answer such as "track not found"), or undef if Last.fm
# couldn't be reached or no API key is set.
#  - Answers are kept for a while (%LASTFM_CACHE_TTL), also across server
#    restarts, so asking the same question again soon costs nothing.
#  - The same question asked while it is already on its way waits for that
#    answer rather than being sent twice.
#  - At most LASTFM_MAX_PARALLEL requests run at once; the others wait,
#    real lookups before fetching ahead ($opts->{prefetch}).
#  - Temporary failures (network, Last.fm busy or offline) are retried
#    after LASTFM_RETRY_DELAYS seconds, while the question is less than
#    LASTFM_BUDGET_SECS old.
sub _lastfm {
	my ( $method, $params, $callback, $opts ) = @_;

	my $apiKey = $prefs->get('lastfm_api_key');
	return $callback->(undef) unless $apiKey;

	my $prefetch = $opts && $opts->{prefetch} ? 1 : 0;
	my $query = join('&', map { "$_=" . uri_escape_utf8($params->{$_} // '') } sort keys %$params);
	my $key   = "$method?$query";   # the question, without the API key

	if ( my $hit = $lastfmCache{$key} ) {
		if ( time() - $hit->{time} < ($LASTFM_CACHE_TTL{$method} || 3600) ) {
			$log->debug("Album Mix: Last.fm $method answered from the cache");

			# Answer a moment later, as a real request would, rather than
			# inside the caller: a long run of cached answers would otherwise
			# nest ever deeper
			my $result = $hit->{result};
			Slim::Utils::Timers::setTimer(undef, time(), sub { _lastfmCall($method, $callback, $result) });
			return;
		}
		delete $lastfmCache{$key};
	}

	if ( my $pending = $lastfmPending{$key} ) {
		push @{ $pending->{callbacks} }, $callback;

		# A real lookup now needs this answer: it no longer waits behind
		# the real lookups
		$pending->{prefetch} = 0 unless $prefetch;
		return;
	}

	$lastfmPending{$key} = {
		method    => $method,
		url       => LASTFM_API_BASE . "?method=$method&$query&api_key=$apiKey&format=json",
		callbacks => [ $callback ],
		prefetch  => $prefetch,
		attempt   => 0,
	};

	_lastfmQueue($key);
}

# Forget the requests on their way (at shutdown): their answers are no
# longer wanted, and the slots must not stay taken
sub _lastfmReset {
	%lastfmPending = ();
	@lastfmQueue   = ();
	$lastfmRunning = 0;
	$lastfmGen++;
}

# Call one waiting caller. If it fails, the others still get the answer.
sub _lastfmCall {
	my ( $method, $callback, $result ) = @_;
	eval { $callback->($result); 1 }
		or $log->error("Album Mix: Handling the Last.fm $method answer failed: $@");
}

# Put a question in line for a free slot. If too many fetch-ahead requests
# are waiting (the lookups have moved on), the oldest are dropped.
sub _lastfmQueue {
	my $key = shift;

	push @lastfmQueue, $key;

	my @ahead = grep { $lastfmPending{$_} && $lastfmPending{$_}->{prefetch} } @lastfmQueue;
	while ( @ahead > LASTFM_MAX_AHEAD_WAITING ) {
		my $drop = shift @ahead;
		@lastfmQueue = grep { $_ ne $drop } @lastfmQueue;
		$log->debug("Album Mix: Not fetching ahead: $drop");
		_lastfmFinish($drop, undef, 0);
	}

	_lastfmPump();
}

# Start waiting questions while there are free slots: real lookups first
sub _lastfmPump {
	while ( $lastfmRunning < LASTFM_MAX_PARALLEL ) {
		@lastfmQueue = grep { $lastfmPending{$_} } @lastfmQueue;
		last unless @lastfmQueue;

		my ($i) = grep { !$lastfmPending{ $lastfmQueue[$_] }->{prefetch} } 0 .. $#lastfmQueue;
		my $key = splice(@lastfmQueue, $i // 0, 1);

		$lastfmRunning++;
		_lastfmFetch($key);
	}
}

# The answer to a question is in (or it failed, $result undef): keep it if
# $keep, and tell everyone waiting for it
sub _lastfmFinish {
	my ( $key, $result, $keep ) = @_;

	my $pending = delete $lastfmPending{$key} || return;

	if ( $keep ) {
		$lastfmCache{$key} = { time => time(), result => $result };
		_trimLastfmCache();
		_lastfmCacheChanged();
	}

	_lastfmCall($pending->{method}, $_, $result) for @{ $pending->{callbacks} };
}

sub _lastfmFetch {
	my $key     = shift;
	my $pending = $lastfmPending{$key};
	my $method  = $pending->{method};

	$pending->{started} //= time();

	# Exactly once per request: free the slot, then start the next one
	my $gen      = $lastfmGen;
	my $released = 0;
	my $watchdog;
	my $release = sub {
		return if $released++;
		$lastfmRunning-- if $lastfmRunning > 0 && $gen == $lastfmGen;
		if ( $watchdog ) {
			eval { Slim::Utils::Timers::killSpecific($watchdog) };
			undef $watchdog;   # the timer refers back to this request
		}
	};

	# Only this request's question is answered: a late answer after the
	# question was given up and asked again must not answer the new one
	my $mine = sub { $lastfmPending{$key} && $lastfmPending{$key} == $pending };

	my $finish = sub {
		$release->();
		_lastfmFinish($key, @_) if $mine->();
		_lastfmPump();
	};

	my $retry = sub {
		my $why = shift;
		$release->();
		return _lastfmPump() unless $mine->();

		my @delays = LASTFM_RETRY_DELAYS;
		my $delay  = $delays[ $pending->{attempt} ];

		if ( defined $delay && time() - $pending->{started} + $delay < LASTFM_BUDGET_SECS ) {
			$log->info("Album Mix: Last.fm $method failed ($why), trying again in ${delay}s");
			$pending->{attempt}++;
			Slim::Utils::Timers::setTimer(undef, time() + $delay, sub {
				_lastfmQueue($key) if $lastfmPending{$key} && $lastfmPending{$key} == $pending;
			});
			_lastfmPump();
			return;
		}

		$log->warn("Album Mix: Last.fm $method failed ($why), giving up");
		_lastfmFinish($key, undef, 0);
		_lastfmPump();
	};

	# A decoded Last.fm answer, which may be an error answer
	my $answer = sub {
		my $result = shift;

		if ( my $code = $result->{error} ) {
			my $why = "error $code: " . ($result->{message} // '');
			return $retry->($why) if $LASTFM_RETRY_ERRORS{$code};

			# A definite answer such as "track not found" (6): keep it, so it
			# isn't asked again. Others (e.g. a bad API key) are not kept.
			if ( $code == 6 ) {
				$log->info("Album Mix: Last.fm $method: $why");
			} else {
				$log->warn("Album Mix: Last.fm $method: $why");
			}
			return $finish->({ error => $code, message => $result->{message} }, $code == 6);
		}

		my $trim = $LASTFM_TRIM{$method};
		$finish->($trim ? $trim->($result) : $result, 1);
	};

	my $ok = eval {
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http   = shift;
				my $result = eval { decode_json($http->content) };

				return $retry->('unreadable answer') if $@ || ref $result ne 'HASH';
				$answer->($result);
			},
			sub {
				my ( $http, $error, $response ) = @_;
				$error ||= ( eval { $http->error } || 'unknown' );

				# Last.fm sends some errors with an HTTP error status (e.g. 403 for
				# a bad API key). If the body with the reason was read, use it
				# (current LMS versions don't read it; the status is used then)
				my $body   = blessed($response) && $response->can('content') ? $response->content : undef;
				my $result = $body ? eval { decode_json($body) } : undef;
				return $answer->($result) if ref $result eq 'HASH' && $result->{error};

				# Other client errors won't get better by asking again; timeouts,
				# server errors (5xx) and "too many requests" (429) may
				my $status = blessed($response) && $response->can('code') ? $response->code : undef;
				($status) = $error =~ /^\s*(\d{3})\b/ unless $status;
				if ( $status && $status =~ /^4/ && $status != 408 && $status != 429 ) {
					$log->warn("Album Mix: Last.fm $method failed ($error)");
					return $finish->(undef, 0);
				}

				$retry->("network error: $error");
			},
			{ timeout => LASTFM_HTTP_TIMEOUT },
		)->get($pending->{url});
		1;
	};

	# (if the request had already answered, there is nothing left to do)
	return $retry->("request failed: $@") unless $ok || $released;
	return if $released;

	# Should the request never call back, don't let it hold its slot
	$watchdog = Slim::Utils::Timers::setTimer(undef, time() + LASTFM_HTTP_TIMEOUT + 10, sub {
		return if $released || $gen != $lastfmGen;
		$log->warn("Album Mix: Last.fm $method gave no answer at all");
		$retry->('no answer');
	});
}

# Keep the cache to a sensible size: drop the oldest tenth
sub _trimLastfmCache {
	return unless keys %lastfmCache > LASTFM_CACHE_MAX;
	my @oldest = sort { $lastfmCache{$a}->{time} <=> $lastfmCache{$b}->{time} } keys %lastfmCache;
	delete @lastfmCache{ @oldest[ 0 .. int(LASTFM_CACHE_MAX / 10) ] };
}

# ------------------------------------------------------------
# The Last.fm answers are saved in the server's cache folder, so they
# survive a restart: at most every LASTFM_SAVE_DELAY_SECS, and when the
# server shuts down.
# ------------------------------------------------------------

my $noCacheDirLogged;
sub _lastfmCacheFile {
	my $dir = eval { preferences('server')->get('cachedir') };
	unless ( $dir && -d $dir ) {
		$log->info("Album Mix: No cache folder, Last.fm answers are not kept across restarts") unless $noCacheDirLogged++;
		return;
	}
	return File::Spec->catfile($dir, 'albummix-lastfm.json');
}

sub _lastfmCacheDirty { $lastfmDirty }

sub _lastfmCacheChanged {
	return if $lastfmDirty++;
	Slim::Utils::Timers::setTimer(undef, time() + LASTFM_SAVE_DELAY_SECS, sub { _saveLastfmCache() if $lastfmDirty });
}

my $saveFailures = 0;
sub _saveLastfmCache {
	$lastfmDirty = 0;

	my $file = _lastfmCacheFile() || return;
	my $now  = time();

	my %answers = map { $_ => $lastfmCache{$_} } grep {
		my ($method) = /^([^?]+)\?/;
		$method && $now - $lastfmCache{$_}->{time} < ($LASTFM_CACHE_TTL{$method} || 0);
	} keys %lastfmCache;

	my $ok = eval {
		my $json = JSON::XS->new->utf8->canonical->encode({ version => 1, answers => \%answers });
		open(my $fh, '>:raw', "$file.tmp") or die "$!\n";
		print $fh $json or die "$!\n";
		close($fh) or die "$!\n";
		rename("$file.tmp", $file) or die "$!\n";
		1;
	};

	if ( $ok ) {
		$saveFailures = 0;
		$log->debug("Album Mix: Saved " . scalar(keys %answers) . " Last.fm answers to $file");
	} else {
		$log->warn("Album Mix: Could not save the Last.fm answers to $file: $@") unless $saveFailures;
		unlink "$file.tmp";

		# Try again later, a few times; after that only at shutdown
		if ( ++$saveFailures < 3 ) {
			_lastfmCacheChanged();
		} else {
			$lastfmDirty = 1;
		}
	}
}

sub _loadLastfmCache {
	my $file = _lastfmCacheFile() || return;
	return unless -r $file;

	my $data = eval {
		open(my $fh, '<:raw', $file) or die "$!\n";
		local $/;
		my $json = <$fh>;
		close $fh;
		JSON::XS->new->utf8->decode($json);
	};

	unless ( ref $data eq 'HASH' && ($data->{version} || 0) == 1 && ref $data->{answers} eq 'HASH' ) {
		$log->warn("Album Mix: Ignoring the saved Last.fm answers in $file" . ($@ ? ": $@" : ''));
		return;
	}

	my $now = time();
	my $n   = 0;
	while ( my ( $key, $entry ) = each %{ $data->{answers} } ) {
		my ($method) = $key =~ /^([^?]+)\?/;
		next unless $method && $LASTFM_CACHE_TTL{$method};
		next unless ref $entry eq 'HASH' && $entry->{time} && ref $entry->{result} eq 'HASH';
		next if $now - $entry->{time} >= $LASTFM_CACHE_TTL{$method} || $entry->{time} > $now + 60;

		$lastfmCache{$key} = { time => $entry->{time}, result => $entry->{result} };
		$n++;
	}

	_trimLastfmCache();
	$log->info("Album Mix: Loaded $n saved Last.fm answers");
}

# ============================================================
# Fallback: artist.getSimilar → artist.getTopAlbums
# ============================================================

sub _findNextAlbumByArtist {
	my ( $client, $clientId, $seedArtist, $apiKey, $lookupId ) = @_;

	my $state = $playerState{$clientId};
	return unless $state && $state->{active};
	return if _staleLookup($state, $lookupId);

	$log->info("Album Mix: Artist fallback — finding artists similar to '$seedArtist'");

	_getSimilarArtists($client, $clientId, $seedArtist, $apiKey, sub {
		my $similarArtists = shift;

		return unless _isCurrent($clientId, $state);
		return if _staleLookup($state, $lookupId);

		unless ( $similarArtists && @$similarArtists ) {
			$log->warn("Album Mix: No similar artists found for '$seedArtist'");
			$state->{pendingLookup} = 0;
			_nothingFound($client, $state);
			return;
		}

		# Closest few artists in a weighted random order (see Variety)
		$similarArtists = _varietyOrder($client, $similarArtists, sub { $_[0]->{match} });

		# Include the seed artist for different-album-by-same-artist results
		# (only used when Artist Cooldown is 0, as the seed artist has just played)
		unshift @$similarArtists, {
			name  => $seedArtist,
			match => 1.0,
			mbid  => '',
		};

		_tryNextArtist($client, $clientId, $similarArtists, 0, $apiKey, $lookupId);
	});
}

sub _getSimilarArtists {
	my ( $client, $clientId, $artist, $apiKey, $callback ) = @_;

	_lastfm('artist.getSimilar', { artist => $artist, limit => MAX_SIMILAR_ARTISTS }, sub {
		my $result = shift;

		my @artists;
		my $similar = $result && ref $result->{similarartists} eq 'HASH' ? $result->{similarartists}->{artist} : [];
		$similar = [$similar] if ref $similar eq 'HASH';

		for my $a ( @{ $similar || [] } ) {
			next unless ref $a eq 'HASH' && $a->{name};
			push @artists, {
				name  => $a->{name},
				match => $a->{match} || 0,
				mbid  => $a->{mbid}  || '',
			};
		}

		$log->info("Album Mix: Found " . scalar(@artists) . " similar artists to '$artist'");
		$callback->(\@artists);
	});
}

sub _tryNextArtist {
	my ( $client, $clientId, $artists, $index, $apiKey, $lookupId ) = @_;

	my $state = $playerState{$clientId};
	return unless $state && $state->{active};
	return if _staleLookup($state, $lookupId);

	if ( $index >= scalar @$artists ) {
		$log->warn("Album Mix: Exhausted all similar artists — no new album found");
		$state->{pendingLookup} = 0;
		_nothingFound($client, $state);
		return;
	}

	my $artist = $artists->[$index];
	$log->debug("Album Mix: Trying artist '$artist->{name}' (match: $artist->{match})");

	# Artist cooldown — skip entire artist if picked too recently
	if ( _isArtistOnCooldown($clientId, $artist->{name}) ) {
		$log->debug("Album Mix: '$artist->{name}' on cooldown, skipping (artist fallback)");
		_tryNextArtist($client, $clientId, $artists, $index + 1, $apiKey, $lookupId);
		return;
	}

	_getTopAlbums($client, $clientId, $artist->{name}, $apiKey, sub {
		my $albums = shift;

		return unless _isCurrent($clientId, $state);
		return if _staleLookup($state, $lookupId);

		# The artist's top albums minus any that fail the checks, in random
		# order (see Variety) so it isn't always the most popular album
		my @candidates = grep {
			!_skipReason($clientId, $artist->{name}, $_->{name})
		} @$albums;

		my $ordered = _varietyOrder($client, \@candidates, sub { 1 });

		_tryArtistAlbum($client, $clientId, $artists, $index, $ordered, 0, $apiKey, $lookupId);
	});
}

# Try this artist's candidate albums in turn; when none can be queued,
# move on to the next similar artist.
sub _tryArtistAlbum {
	my ( $client, $clientId, $artists, $artistIndex, $candidates, $albumIndex, $apiKey, $lookupId ) = @_;

	my $state = $playerState{$clientId};
	return unless $state && $state->{active};
	return if _staleLookup($state, $lookupId);

	if ( $albumIndex >= scalar @$candidates ) {
		_tryNextArtist($client, $clientId, $artists, $artistIndex + 1, $apiKey, $lookupId);
		return;
	}

	my $artist = $artists->[$artistIndex]->{name};
	my $album  = $candidates->[$albumIndex]->{name};

	_queueCandidate($client, $clientId, $artist, $album, {
		kind       => 'artist',
		seedArtist => $artists->[0]->{name},
		match      => $artists->[$artistIndex]->{match},
	}, sub {
		_tryArtistAlbum($client, $clientId, $artists, $artistIndex, $candidates, $albumIndex + 1, $apiKey, $lookupId);
	});
}

sub _getTopAlbums {
	my ( $client, $clientId, $artist, $apiKey, $callback ) = @_;

	_lastfm('artist.getTopAlbums', { artist => $artist, limit => MAX_TOP_ALBUMS }, sub {
		my $result = shift;

		my @albums;
		my $topAlbums = $result && ref $result->{topalbums} eq 'HASH' ? $result->{topalbums}->{album} : [];
		$topAlbums = [$topAlbums] if ref $topAlbums eq 'HASH';

		for my $a ( @{ $topAlbums || [] } ) {
			next unless ref $a eq 'HASH' && $a->{name};
			next if $a->{name} =~ /^\s*$/;
			next if lc($a->{name}) eq '(null)';

			push @albums, {
				name      => $a->{name},
				mbid      => $a->{mbid}      || '',
				playcount => $a->{playcount} || 0,
			};
		}

		$log->debug("Album Mix: Found " . scalar(@albums) . " top albums for '$artist'");
		$callback->(\@albums);
	});
}

# ============================================================
# Album resolution — find in library or online services
# ============================================================

# Find an album and load it ($cmd 'load') or append it ($cmd 'add').
# $callback->($found, $reason) is always called exactly once; $found is
# true only if the album was actually sent to the playlist.
#
# Where to look depends on the player's Source setting:
#   library_only   — only the local library. The album the mix starts
#                    from may still come from an online service.
#   library_first  — library first, then online services.
#   online_first   — online services first, library as last resort.
#   online_only    — online services first, library as last resort, and
#                    with $opts->{skipOwned} (used for every album the mix
#                    picks, but not for the seed album) an album that is in
#                    the local library is refused, so the mix only queues
#                    music you don't already own (Discovery).
#
# $opts->{isWanted}, if given, is asked just before an online search adds
# its result; if it returns false the album is not added.
# $opts->{minTracks}, if given, rejects albums with fewer tracks (where
# the track count is known).
# $opts->{checkType}: also apply the compilation/live/single filters to the
# title of the album actually found, not just the title that was asked for
# (so asking for "Rumours" can't end up queuing "Rumours (Live)").
#
# $opts->{isSeed}: this is the album the mix starts from (always playable).
#
# On success $callback also gets the title of the album that was queued.
sub _findAndPlayAlbum {
	my ( $client, $artist, $album, $cmd, $callback, $opts ) = @_;

	$callback ||= sub {};
	$opts     ||= {};

	# Record where this album will start in the playlist (for seed track
	# selection), and what the queue looked like before (to tell when an
	# online album has arrived)
	my $clientId = $client->master->id;
	my $preCount = Slim::Player::Playlist::count($client);
	my $preFirst = _trackUrl( Slim::Player::Playlist::track($client, 0) );
	my $preTime  = _playlistUpdated($client);

	# The mix is about to replace the queue itself: ignore the "queue
	# replaced" events that causes (the guard ends once its first song plays)
	if ( $cmd eq 'load' && (my $state = $playerState{$clientId}) ) {
		$state->{guardUntil}    = time() + START_GUARD_SECS;
		$state->{seenFirstSong} = 0;
	}

	my $done = sub {
		my ( $found, $reason, $title, $online ) = @_;

		if ( $found && $cmd ne 'collect' && (my $state = $playerState{$clientId}) ) {
			$state->{lastAlbumStartIndex} = $cmd eq 'load' ? 0 : $preCount;
			$log->debug("Album Mix: Last album starts at playlist index $state->{lastAlbumStartIndex}");

			# Library albums are in the queue straight away; an online
			# service adds its tracks a moment later
			delete $state->{awaitingAlbum};
			_awaitAlbum($client, $state, { cmd => $cmd, preCount => $preCount, preFirst => $preFirst, updated => $preTime }) if $online;
		}

		$callback->($found, $reason, $title);
	};

	my ( $localAlbumId, $localTitle ) = _findLocalAlbum($client, $artist, $album);
	my $ownedId = $localAlbumId;

	# The library copy is a different kind of release (e.g. a live album
	# with a similar name): don't use it
	if ( $localAlbumId && $opts->{checkType} && (my $type = _releaseType($client, $localTitle)) ) {
		$log->info("Album Mix: Library album '$localTitle' looks like a $type release, not using it");
		$localAlbumId = undef;
	}

	# Too short to count as an album: treat the library copy as unusable
	if ( $localAlbumId && $opts->{minTracks} ) {
		my $count = _localTrackCount($localAlbumId);
		if ( defined $count && $count < $opts->{minTracks} ) {
			$log->info("Album Mix: Library copy of '$album' has only $count tracks, not using it");
			$localAlbumId = undef;
		}
	}

	my $playLocal = sub {
		$log->info("Album Mix: Found '$album' in local library (id: $localAlbumId)");

		if ( $cmd eq 'collect' ) {
			my $urls = _localTrackUrls($localAlbumId);
			return $done->(0, 'no playable tracks in the library') unless @$urls;
			push @{ $opts->{collect} }, @$urls;
		} else {
			$client->execute(['playlistcontrol', "cmd:$cmd", "album_id:$localAlbumId"]);
		}

		$done->(1, undef, $localTitle);
	};

	my $source = _pref($client, 'source');
	$source = 'library_first' unless $source && $SOURCES{$source};

	# The album a mix starts from must always be playable, so for it
	# "library only" still falls back to the online services. (Not for the
	# first similar album of a mix that doesn't play its seed.)
	$source = 'library_first' if $source eq 'library_only' && $opts->{isSeed};

	if ( $source eq 'online_only' && $opts->{skipOwned} && $ownedId ) {
		$log->info("Album Mix: Online only — '$album' by '$artist' is already in your library, skipping");
		$done->(0, 'already in library');
		return;
	}

	if ( ($source eq 'library_first' || $source eq 'library_only') && $localAlbumId ) {
		$playLocal->();
		return;
	}

	if ( $source eq 'library_only' ) {
		$log->info("Album Mix: '$album' by '$artist' is not in the library (Source: library only)");
		$done->(0, 'not in library');
		return;
	}

	_findOnlineAlbum($client, $artist, $album, $cmd, sub {
		my ( $found, $reason, $title ) = @_;

		if ( $found ) {
			$done->(1, undef, $title, 1);
		} elsif ( $reason ) {
			# Not wanted any more (see isWanted) — don't fall back to the library
			$done->(0, $reason);
		} elsif ( $localAlbumId ) {
			# Not online — fall back to the library copy
			$playLocal->();
		} else {
			$log->warn("Album Mix: Could not find '$album' by '$artist' in the library or online");
			$done->(0, 'not found in library or online');
		}
	}, $opts);
}

# The URL of a playlist track, or undef
sub _trackUrl {
	my $track = shift;
	return blessed($track) && $track->can('url') ? $track->url : undef;
}

# An album found online was queued: until its tracks show up in the queue,
# onPlaylistChange doesn't start another lookup. If they never do (the
# service failed to add them), the mix carries on after ALBUM_ARRIVAL_SECS.
sub _awaitAlbum {
	my ( $client, $state, $wait ) = @_;

	return if _albumArrived($client, $wait);

	$wait->{since} = time();
	$state->{awaitingAlbum} = $wait;

	$client = $client->master;
	my $clientId = $client->id;
	Slim::Utils::Timers::setTimer(undef, time() + ALBUM_ARRIVAL_SECS, sub {
		return unless _isCurrent($clientId, $state) && $state->{awaitingAlbum} && $state->{awaitingAlbum} == $wait;
		delete $state->{awaitingAlbum};
		return if _albumArrived($client, $wait);

		# The album that was to replace the queue never came, and the queue
		# is empty: there is nothing to continue from
		if ( $wait->{cmd} eq 'load' && !Slim::Player::Playlist::count($client) ) {
			$log->warn("Album Mix: The album never reached the queue, stopping");
			return stopAlbumMix($client);
		}

		$log->warn("Album Mix: The queued album didn't appear in the queue in time, looking for another one");
		_findNextAlbum($client, $clientId) unless $state->{pendingLookup};
	});
}

# True once the tracks of an album queued online are in the queue: for
# 'add', the queue has grown; for 'load', the queue was replaced
sub _albumArrived {
	my ( $client, $wait ) = @_;

	my $count = Slim::Player::Playlist::count($client);
	return $count > $wait->{preCount} if $wait->{cmd} ne 'load';
	return 0 unless $count;

	my $first = _trackUrl( Slim::Player::Playlist::track($client, 0) );
	return 1 if defined $first && ( !defined $wait->{preFirst} || $first ne $wait->{preFirst} );

	# The same album again (its first track has the same URL): the queue
	# has changed since before the album was asked for (a queue that was
	# only cleared has no tracks, see above)
	my $updated = _playlistUpdated($client);
	return defined $updated && defined $wait->{updated} && $updated != $wait->{updated} ? 1 : 0;
}

# When the queue last changed, if this LMS version says so
sub _playlistUpdated {
	my $client = shift;
	return $client->can('currentPlaylistUpdateTime') ? eval { $client->currentPlaylistUpdateTime } : undef;
}

# Look an album up in the local library. Returns ( album id, title ), or
# an empty list.
#
# First tries an exact and a case-insensitive match. Failing that, it
# looks through the albums of artists whose name contains the wanted
# artist's name (also using LMS's accent-free search name, so "Bjork"
# finds "Björk") and accepts a title that is the same once normalised:
# "Rumours (Remastered)" finds "Rumours" and "Abbey Road" finds
# "Abbey Road (Super Deluxe Edition)". Unlike online results, a title
# that merely contains the other ("Led Zeppelin" / "Led Zeppelin II",
# "Rumours" / "Rumours Live") is not accepted, as that would be a
# different album.
sub _findLocalAlbum {
	my ( $client, $artist, $album ) = @_;

	my $dbh = Slim::Schema->dbh;

	my $select = "SELECT albums.id, albums.title, contributors.name FROM albums "
		. "JOIN contributors ON contributors.id = albums.contributor ";

	for my $where (
		"WHERE albums.title = ? AND contributors.name = ? ",
		"WHERE LOWER(albums.title) = LOWER(?) AND LOWER(contributors.name) = LOWER(?) ",
	) {
		my $sth = $dbh->prepare_cached($select . $where . "LIMIT 1");
		$sth->execute($album, $artist);
		my ( $albumId, $title ) = $sth->fetchrow_array;
		$sth->finish;
		return ( $albumId, $title ) if $albumId;
	}

	# Loose match: candidate albums by the artist, then compare titles.
	# namesearch is LMS's upper-case, accent-free copy of the name; if this
	# LMS version doesn't have it, the plain name is used. Very short names
	# (or "The The") are matched exactly rather than with "contains", which
	# would match most of the library.
	(my $artistCore = lc($artist)) =~ s/^\s*the\s+//;
	my $searchCore = uc( _normaliseName($artist) );
	my $contains   = length($artistCore) >= 3 && $artistCore ne 'the' && length($searchCore) >= 3;

	my ( $nameWhere, @nameBind ) = $contains
		? ( "LOWER(contributors.name) LIKE ?", '%' . $artistCore . '%' )
		: ( "LOWER(contributors.name) = ?", lc($artist) );
	my ( $searchWhere, @searchBind ) = $contains
		? ( "contributors.namesearch LIKE ?", '%' . $searchCore . '%' )
		: ( "contributors.namesearch = ?", $searchCore );

	my $rows = eval {
		my $sth = $dbh->prepare_cached($select . "WHERE $nameWhere OR $searchWhere LIMIT 500");
		$sth->execute(@nameBind, @searchBind);
		my $r = $sth->fetchall_arrayref;
		$sth->finish;
		$r;
	};
	unless ( $rows ) {
		my $sth = $dbh->prepare_cached($select . "WHERE $nameWhere LIMIT 500");
		$sth->execute(@nameBind);
		$rows = $sth->fetchall_arrayref;
		$sth->finish;
	}

	for my $row ( @$rows ) {
		my ( $albumId, $title, $name ) = @$row;
		next unless _nameMatchScore($artist, $name);
		return ( $albumId, $title ) if _nameMatchScore($album, $title) == 2;
	}

	return;
}

# The track URLs of a library album, in album order
sub _localTrackUrls {
	my $albumId = shift;

	# Only audio tracks (not e.g. cue sheet entries); older schemas without
	# the audio column get all of them
	for my $where ( "album = ? AND audio = 1", "album = ?" ) {
		my $urls = eval {
			my $sth = Slim::Schema->dbh->prepare_cached("SELECT url FROM tracks WHERE $where ORDER BY disc, tracknum, id");
			$sth->execute($albumId);
			my $u = [ grep { defined && length } map { $_->[0] } @{ $sth->fetchall_arrayref } ];
			$sth->finish;
			$u;
		};
		return $urls if $urls;
	}

	return [];
}

# Add an album found online to the queue ('load' replaces it), or for
# Don't Stop The Music ('collect') only note its URL
sub _sendAlbum {
	my ( $client, $cmd, $url, $opts ) = @_;

	if ( $cmd eq 'collect' ) {
		push @{ $opts->{collect} }, $url;
		return;
	}

	$client->execute([ 'playlist', $cmd eq 'load' ? 'play' : 'add', $url ]);
}

# Number of tracks in a library album, or undef if it can't be counted.
sub _localTrackCount {
	my $albumId = shift;

	# Audio tracks only, as handed over (see _localTrackUrls)
	for my $where ( "album = ? AND audio = 1", "album = ?" ) {
		my $count = eval {
			my $sth = Slim::Schema->dbh->prepare_cached("SELECT COUNT(*) FROM tracks WHERE $where");
			$sth->execute($albumId);
			my ($n) = $sth->fetchrow_array;
			$sth->finish;
			$n;
		};
		return $count if defined $count;
	}

	return;
}

# Search the enabled online services in turn.
# $callback->(1) once one of them has added the album, $callback->(0) if
# none had it (or no supported service is enabled), or
# $callback->(0, 'no longer wanted') if $opts->{isWanted} said no.
# $opts is passed on to the service searches (isWanted, minTracks).
sub _findOnlineAlbum {
	my ( $client, $artist, $album, $cmd, $callback, $opts ) = @_;

	$opts ||= {};

	my @services = _getAvailableServices();

	unless ( @services ) {
		$log->info("Album Mix: No supported online service enabled");
		$callback->(0);
		return;
	}

	$log->info("Album Mix: Searching online services for '$album' by '$artist'");
	_tryOnlineService($client, $artist, $album, $cmd, \@services, 0, $callback, $opts);
}

sub _getAvailableServices {
	my @services;

	# Only include services that have a search handler implemented
	push @services, 'tidal'
		if Slim::Utils::PluginManager->isEnabled('Plugins::TIDAL::Plugin');

	push @services, 'spotty'
		if Slim::Utils::PluginManager->isEnabled('Plugins::Spotty::Plugin');

	# Qobuz and Deezer: detected but no search handler yet
	# push @services, 'qobuz'
	#	if Slim::Utils::PluginManager->isEnabled('Plugins::Qobuz::Plugin');
	# push @services, 'deezer'
	#	if Slim::Utils::PluginManager->isEnabled('Plugins::Deezer::Plugin');

	return @services;
}

sub _tryOnlineService {
	my ( $client, $artist, $album, $cmd, $services, $index, $callback, $opts ) = @_;

	$opts ||= {};

	if ( $index >= scalar @$services ) {
		$log->info("Album Mix: No online service had '$album' by '$artist'");
		$callback->(0);
		return;
	}

	my $service = $services->[$index];
	$log->debug("Album Mix: Trying $service");

	my $handler = {
		spotty => \&_searchSpotty,
		tidal  => \&_searchTidal,
	}->{$service};

	unless ( $handler ) {
		_tryOnlineService($client, $artist, $album, $cmd, $services, $index + 1, $callback, $opts);
		return;
	}

	# A service that doesn't answer in time is skipped. Its answer, if it
	# still comes, is not used: it may no longer add anything (isWanted).
	my ( $answered, $timedOut ) = ( 0, 0 );
	my $wanted = $opts->{isWanted};
	my %serviceOpts = (
		%$opts,
		isWanted => sub { !$timedOut && ( !$wanted || $wanted->() ) },
	);

	Slim::Utils::Timers::setTimer(undef, time() + ONLINE_SEARCH_TIMEOUT_SECS, sub {
		return if $answered++;
		$timedOut = 1;
		return $callback->(0, 'no longer wanted') if $wanted && !$wanted->();
		$log->warn("Album Mix: $service didn't answer within " . ONLINE_SEARCH_TIMEOUT_SECS . "s, trying the next service");
		_tryOnlineService($client, $artist, $album, $cmd, $services, $index + 1, $callback, $opts);
	});

	$handler->($client, $artist, $album, $cmd, sub {
		my ( $found, $reason, $title ) = @_;
		return if $answered++;

		if ( $found ) {
			$callback->(1, undef, $title);
		} elsif ( $reason ) {
			$callback->(0, $reason);
		} else {
			_tryOnlineService($client, $artist, $album, $cmd, $services, $index + 1, $callback, $opts);
		}
	}, \%serviceOpts);
}

sub _searchSpotty {
	my ( $client, $artist, $album, $cmd, $done, $opts ) = @_;

	$opts ||= {};
	my $isWanted  = $opts->{isWanted};
	my $minTracks = $opts->{minTracks} || 0;

	# Make sure the caller hears back exactly once, even if an error is
	# caught below after the search has already answered
	my $answered = 0;
	my $callback = sub { $done->(@_) unless $answered++ };

	eval {
		if ( Plugins::Spotty::Plugin->can('getAPIHandler') ) {
			my $api = Plugins::Spotty::Plugin->getAPIHandler($client);
			if ( $api && $api->can('search') ) {
				$api->search(sub {
					my $results = shift;

					my @items;
					if ( ref $results eq 'HASH' && $results->{albums} && ref $results->{albums} eq 'HASH' && $results->{albums}->{items} ) {
						@items = grep { $_->{uri} } @{$results->{albums}->{items}};
					}

					# Too short to count as an album (singles/EP filter)
					@items = grep {
						!$minTracks || !defined $_->{total_tracks} || $_->{total_tracks} >= $minTracks
					} @items;

					# Not a filtered release type (compilation/live/single)
					@items = grep { !_releaseType($client, $_->{name}) } @items if $opts->{checkType};

					# Only accept a result whose artist and album title match
					my $match = _bestAlbumMatch($artist, $album, \@items,
						sub { $_[0]->{name} },
						sub { $_[0]->{artists} && $_[0]->{artists}->[0] ? $_[0]->{artists}->[0]->{name} : '' },
					);

					if ( $match && $isWanted && !$isWanted->() ) {
						$log->info("Album Mix: Spotify result for '$album' arrived too late, not adding it");
						$callback->(0, 'no longer wanted');
						return;
					}

					if ( $match ) {
						$log->info("Album Mix: Found on Spotify: $match->{name}");
						_sendAlbum($client, $cmd, $match->{uri}, $opts);
						$callback->(1, undef, $match->{name});
						return;
					}

					$log->info("Album Mix: No matching album found on Spotify");
					$callback->(0);
				}, {
					search => 'album:' . _searchTitle($album) . " artist:$artist",
					type   => 'albums',
					limit  => 10,
				});
				return;
			}
		}
		$callback->(0);
	};

	if ( $@ ) {
		$log->debug("Album Mix: Spotty search error: $@");
		$callback->(0);
	}
}

sub _searchTidal {
	my ( $client, $artist, $album, $cmd, $done, $opts ) = @_;

	$opts ||= {};
	my $isWanted  = $opts->{isWanted};
	my $minTracks = $opts->{minTracks} || 0;

	# Make sure the caller hears back exactly once, even if an error is
	# caught below after the search has already answered
	my $answered = 0;
	my $callback = sub { $done->(@_) unless $answered++ };

	eval {
		if ( Plugins::TIDAL::Plugin->can('getAPIHandler') ) {
			my $api = Plugins::TIDAL::Plugin->getAPIHandler($client);
			if ( $api && $api->can('search') ) {
				$log->info("Album Mix: Searching TIDAL for '$album' by '$artist'");
				$api->search(sub {
					my $results = shift;

					# The TIDAL API returns the items array directly when
					# a type is specified (e.g. type => 'albums')
					my @items;
					if ( ref $results eq 'ARRAY' ) {
						@items = @$results;
					} elsif ( ref $results eq 'HASH' ) {
						# Fallback for alternative response formats
						if ( $results->{items} ) {
							@items = @{$results->{items}};
						} elsif ( $results->{albums} ) {
							my $albums = $results->{albums};
							@items = ref $albums eq 'ARRAY'
								? @$albums
								: (ref $albums eq 'HASH' && $albums->{items}
									? @{$albums->{items}} : ());
						}
					}
					@items = grep { ref $_ eq 'HASH' && $_->{id} } @items;

					# Too short to count as an album (singles/EP filter)
					@items = grep {
						!$minTracks || !defined $_->{numberOfTracks} || $_->{numberOfTracks} >= $minTracks
					} @items;

					$log->info("Album Mix: TIDAL returned " . scalar(@items) . " album results");

					# Not a filtered release type (compilation/live/single)
					@items = grep { !_releaseType($client, $_->{title}) } @items if $opts->{checkType};

					# Only accept a result whose artist and album title match,
					# so a different album by the same artist isn't queued
					my $match = _bestAlbumMatch($artist, $album, \@items,
						sub { $_[0]->{title} },
						sub {
							my $a = $_[0]->{artist} || ($_[0]->{artists} && $_[0]->{artists}->[0]) || {};
							return $a->{name} || '';
						},
					);

					if ( $match && $isWanted && !$isWanted->() ) {
						$log->info("Album Mix: TIDAL result for '$album' arrived too late, not adding it");
						$callback->(0, 'no longer wanted');
						return;
					}

					if ( $match ) {
						my $itemArtist = $match->{artist} || ($match->{artists} && $match->{artists}->[0]) || {};
						$log->info("Album Mix: Found on TIDAL: $match->{title} by " . ($itemArtist->{name} || '?') . " (id: $match->{id})");
						_sendAlbum($client, $cmd, "tidal://album:$match->{id}", $opts);
						$callback->(1, undef, $match->{title});
						return;
					}

					$log->info("Album Mix: No matching album found on TIDAL");
					$callback->(0);
				}, {
					search => "$artist " . _searchTitle($album),
					type   => 'albums',
					limit  => 10,
				});
				return;
			} else {
				$log->warn("Album Mix: TIDAL API handler has no search method");
			}
		} else {
			$log->warn("Album Mix: TIDAL plugin has no getAPIHandler method");
		}
		$callback->(0);
	};

	if ( $@ ) {
		$log->warn("Album Mix: TIDAL search error: $@");
		$callback->(0);
	}
}

# ============================================================
# Name matching (album titles and artist names)
# ============================================================

# Reduce a name to a comparable form: lower case, accents removed, no
# bracketed notes such as "(Deluxe Edition)" or "[2011 Remaster]", no
# " - Remastered" or trailing "Deluxe Edition" style suffixes, "&" and
# "+" read as "and", "Vol." as "volume", "Pt." as "part", no leading
# "The", no punctuation.
sub _normaliseName {
	my $name = lc( shift // '' );

	# Only accents on Latin letters are removed; marks in other scripts
	# (e.g. Japanese dakuten) change the meaning and are kept
	if ( $canFoldAccents ) {
		$name = Unicode::Normalize::NFD($name);
		$name =~ s/(\p{Latin})\p{Mn}+/$1/g;
		$name = Unicode::Normalize::NFC($name);
	}

	my $orig = $name;

	# Trailing edition notes without brackets or a dash, e.g. "Rumours
	# Remastered", "Abbey Road Super Deluxe Edition", "Ten Legacy Edition".
	# Words like "Special" only count when followed by "Edition"/"Version",
	# so a title such as "Something Special" is left alone.
	my $edition = qr/(?:(?:super\s+)?deluxe|remaster(?:ed)?|expanded)(?:\s+(?:edition|version))?
		|(?:special|collector'?s|legacy|anniversary|bonus\s+tracks?)\s+(?:edition|version)/x;

	$name =~ s/\s*[\(\[][^\)\]]*[\)\]]//g;
	$name =~ s/\s+-\s+.*\b(?:remaster(?:ed)?|deluxe|edition|expanded|anniversary|version|mono|stereo|bonus|reissue)\b.*$//;
	$name =~ s/\s+(?:\d{4}\s+)?(?:$edition)\s*$//;
	$name =~ s/[&+]/ and /g;
	$name =~ s/\bvol\.?\s*(?=\d|[ivx]+\b)/volume /g;
	$name =~ s/\bpt\.?\s*(?=\d|[ivx]+\b)/part /g;
	$name =~ s/^\s*the\s+//;
	$name =~ s/[^\p{L}\p{N}]+/ /g;
	$name =~ s/^\s+|\s+$//g;

	# A name that was nothing but a bracketed note, e.g. "(Untitled)"
	if ( $name eq '' ) {
		($name = $orig) =~ s/[^\p{L}\p{N}]+/ /g;
		$name =~ s/^\s+|\s+$//g;
	}

	return $name;
}

# Album title for an online search: bracketed notes such as
# "(2011 Remaster)" are dropped, as they often stop the service finding
# the album at all. Result titles are still checked with _nameMatchScore.
sub _searchTitle {
	my $title = shift // '';
	( my $clean = $title ) =~ s/\s*[\(\[][^\)\]]*[\)\]]//g;
	$clean =~ s/^\s+|\s+$//g;
	return length $clean ? $clean : $title;
}

# How well two names match: 2 = same after normalising, 1 = one contains
# the other as whole words (e.g. "Abbey Road" in "Abbey Road Anniversary
# Edition"), 0 = no match.
sub _nameMatchScore {
	my ( $a, $b ) = map { _normaliseName($_) } @_;

	return 0 unless length $a && length $b;
	return 2 if $a eq $b;

	my ( $short, $long ) = length $a <= length $b ? ( $a, $b ) : ( $b, $a );
	return 1 if index(" $long ", " $short ") >= 0;

	return 0;
}

# Pick the search result that best matches the wanted artist and album.
# Results whose artist doesn't match are ignored (a result with no artist
# is given the benefit of the doubt); of the rest, an identical title
# beats one that only matches after normalising (e.g. a deluxe edition),
# which beats a partial match. Returns undef if nothing matches.
sub _bestAlbumMatch {
	my ( $artist, $album, $items, $getTitle, $getArtist ) = @_;

	my ( $best, $bestScore ) = ( undef, 0 );
	my $wanted = lc($album);

	for my $item ( @$items ) {
		my $itemTitle  = $getTitle->($item)  || '';
		my $itemArtist = $getArtist->($item) || '';

		if ( $itemArtist && !_nameMatchScore($artist, $itemArtist) ) {
			$log->debug("Album Mix: Result '$itemTitle' by '$itemArtist' — artist mismatch, skipping");
			next;
		}

		my $score = _nameMatchScore($album, $itemTitle);
		unless ( $score ) {
			$log->debug("Album Mix: Result '$itemTitle' by '$itemArtist' — title mismatch, skipping");
			next;
		}

		$score = 3 if lc($itemTitle) eq $wanted;

		( $best, $bestScore ) = ( $item, $score ) if $score > $bestScore;
		last if $bestScore == 3;
	}

	return $best;
}

# ============================================================
# History management
# ============================================================

# Albums are compared by normalised artist and title, so "Rumours" and
# "Rumours (Super Deluxe)" count as the same album.
sub _historyKey {
	my ( $artist, $album ) = @_;
	return _nameKey($artist) . '|||' . _nameKey($album);
}

# Normalised name, or the plain lower-case name for names that are all
# punctuation (e.g. the band "!!!"), so they don't all share one key.
sub _nameKey {
	my $name = shift // '';
	return _normaliseName($name) || lc($name);
}

# ------------------------------------------------------------
# Saved history: remembered across mixes and restarts, so an album
# isn't queued again within "Don't Repeat For" days. With History
# Scope 'shared' there is one history for all players; with 'player'
# each player (sync group: its main player) has its own.
# ------------------------------------------------------------

# The prefs object that holds the saved history for this player
sub _historyStore {
	my $client = shift;

	if ( $client && ($prefs->get('history_scope') // 'shared') eq 'player' ) {
		$client = $client->master if $client->can('master');
		return $prefs->client($client);
	}

	return $prefs;
}

sub _recordPlayed {
	my ( $client, $artist, $album ) = @_;

	my $store  = _historyStore($client);
	my %played = %{ $store->get('played_albums') || {} };
	$played{ _historyKey($artist, $album) } = time();

	# Forget entries older than the repeat window, and keep the list to a
	# sensible size by dropping the oldest
	if ( my $days = $prefs->get('repeat_days') ) {
		my $cutoff = time() - $days * 86400;
		delete $played{$_} for grep { $played{$_} < $cutoff } keys %played;
	}
	if ( keys %played > MAX_SAVED_HISTORY ) {
		my @oldest = sort { $played{$a} <=> $played{$b} } keys %played;
		delete @played{ @oldest[ 0 .. keys(%played) - MAX_SAVED_HISTORY - 1 ] };
	}

	$store->set('played_albums', \%played);
}

# Days since the album was last queued if that is within the repeat
# window (at least 1), otherwise 0.
sub _playedRecently {
	my ( $client, $artist, $album ) = @_;

	my $days = $prefs->get('repeat_days') || 0;
	return 0 unless $days > 0;

	my $played = _historyStore($client)->get('played_albums') || {};
	my $when   = $played->{ _historyKey($artist, $album) } || return 0;

	my $age = time() - $when;
	return 0 if $age >= $days * 86400;

	my $ago = int($age / 86400);
	return $ago < 1 ? 1 : $ago;
}

# ------------------------------------------------------------
# Variety
# ------------------------------------------------------------

# Return the list in a new order: the first N items (N = the Variety
# setting) are shuffled, with items that have a higher weight more likely
# to come first; the rest follow in their original order. With Variety 1
# the order is unchanged.
#
# Weighted shuffle: each item gets the key rand() ** (1 / weight) and the
# items are sorted by key, highest first — an item with twice the weight
# is twice as likely to be ahead of another.
sub _varietyOrder {
	my ( $client, $items, $weightOf ) = @_;

	my $n = _pref($client, 'variety');
	$n = DEFAULT_VARIETY unless defined $n && $n =~ /^\d+$/ && $n > 0;

	my @list = @$items;
	return \@list if $n <= 1 || @list <= 1;

	$n = @list if $n > @list;
	my @pool = @list[ 0 .. $n - 1 ];
	my @rest = @list[ $n .. $#list ];

	my %key;
	for my $i ( 0 .. $#pool ) {
		my $w = $weightOf->($pool[$i]) || 0;
		$w = 0.01 if $w < 0.01;
		$key{$i} = rand() ** (1 / $w);
	}

	my @shuffled = map { $pool[$_] } sort { $key{$b} <=> $key{$a} } keys %key;

	return [ @shuffled, @rest ];
}

sub _addToHistory {
	my ( $clientId, $artist, $album ) = @_;

	my $state = $playerState{$clientId} || return;
	my $key = _historyKey($artist, $album);
	my $maxHistory = $prefs->get('max_history') || DEFAULT_MAX_HISTORY;

	push @{$state->{history}}, $key;

	while ( scalar @{$state->{history}} > $maxHistory ) {
		shift @{$state->{history}};
	}
}

# ============================================================
# Artist cooldown management
# ============================================================

sub _addArtistToHistory {
	my ( $clientId, $artist ) = @_;

	my $state = $playerState{$clientId} || return;
	my $cooldown = _pref($state->{client}, 'artist_cooldown') || DEFAULT_ARTIST_COOLDOWN;

	push @{$state->{artist_history}}, _nameKey($artist);

	# Keep list trimmed to cooldown size (we only need the last N)
	while ( scalar @{$state->{artist_history}} > $cooldown ) {
		shift @{$state->{artist_history}};
	}
}

sub _isArtistOnCooldown {
	my ( $clientId, $artist ) = @_;

	my $state = $playerState{$clientId} || return 0;
	my $cooldown = _pref($state->{client}, 'artist_cooldown') || 0;

	return 0 unless $cooldown > 0;

	my $key = _nameKey($artist);
	return grep { $_ eq $key } @{$state->{artist_history}};
}

# ============================================================
# Per-player settings
# ============================================================

# The value of a setting for a player. Synced players use the settings of
# the main player in the group. A player uses the server defaults unless
# "Use own settings for this player" is ticked on its settings page; then
# its own values apply. A setting the player has no value for yet (e.g. one
# added in a later version) falls back to the server default; an unticked
# checkbox is stored as 0 by the player settings page, so it stays off.
# Server-wide-only settings, and calls without a player, always give the
# server value.
sub _pref {
	my ( $client, $name ) = @_;

	my $type = $PLAYER_PREFS{$name};

	if ( $client && $type ) {
		$client = $client->master if $client->can('master');
		my $cp = _clientPrefs($client);

		if ( $cp->get('own_settings') ) {
			my $value = $cp->get($name);
			if ( defined $value && $value ne '' ) {
				return $type eq 'bool' ? ( $value ? 1 : 0 ) : $value;
			}
		}
	}

	return $prefs->get($name);
}

# Version of the per-player settings layout (see _clientPrefs)
use constant CLIENT_PREFS_VERSION => 2;

# A player's prefs, brought up to date once per player. 1.9.0/1.9.1 read
# an empty checkbox as "off"; from 1.9.2 an empty value means "not set,
# use the server default" (so settings added later start from the
# default). Players that already had their own settings keep their
# unticked Skip boxes off: those are stored as 0.
my %clientPrefsChecked;
sub _clientPrefs {
	my $client = shift;

	my $cp = $prefs->client($client);
	return $cp if $clientPrefsChecked{ $client->id }++;

	if ( ($cp->get('prefs_version') || 0) < CLIENT_PREFS_VERSION ) {
		if ( $cp->get('own_settings') ) {
			for my $name ( qw(filter_compilations filter_live filter_singles) ) {
				$cp->set($name, 0) unless defined $cp->get($name) && $cp->get($name) ne '';
			}
		}
		$cp->set('prefs_version', CLIENT_PREFS_VERSION);
	}

	return $cp;
}

# Names of the per-player settings that are checkboxes
sub playerBoolPrefNames { return grep { $PLAYER_PREFS{$_} eq 'bool' } sort keys %PLAYER_PREFS }

# Names of the settings that can be set per player (for the settings pages)
sub playerPrefNames { return sort keys %PLAYER_PREFS }

# ------------------------------------------------------------
# 1.2 compatibility: Prefer Local Library / Discovery Mode
# ------------------------------------------------------------

# The 1.2 settings as one string, to notice when 1.2 changed them
sub _legacyPrefsKey {
	return ( $prefs->get('discover_new') ? 1 : 0 ) . ',' . ( $prefs->get('prefer_local') ? 1 : 0 );
}

# Set the 1.2 settings from Source, so going back to 1.2 behaves as close
# as 1.2 allows. 1.2 has no "Library only": it becomes Prefer Local Library,
# which in 1.2 also falls back to online services.
sub _syncLegacyPrefs {
	my $source = $prefs->get('source') // '';
	$prefs->set('discover_new', $source eq 'online_only' ? 1 : 0);
	$prefs->set('prefer_local', ($source eq 'library_first' || $source eq 'library_only') ? 1 : 0);
	$prefs->set('legacy_synced', _legacyPrefsKey());
}

1;
