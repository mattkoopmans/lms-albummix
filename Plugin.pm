package Plugins::AlbumMix::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use Scalar::Util qw(blessed);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use Slim::Networking::SimpleAsyncHTTP;

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
	});

	$prefs->setValidate({ validator => 'intlimit', low => 0, high => 50 },   'min_tracks');
	$prefs->setValidate({ validator => 'intlimit', low => 1, high => 50 },   'variety');
	$prefs->setValidate({ validator => 'intlimit', low => 0, high => 3650 }, 'repeat_days');

	# Load and register the settings page
	eval { require Plugins::AlbumMix::Settings };
	if ( !$@ ) {
		Plugins::AlbumMix::Settings->new;
	} else {
		$log->warn("Could not load AlbumMix settings: $@");
	}

	# Register album context menu item
	Slim::Menu::AlbumInfo->registerInfoProvider( albummix_create => (
		after => 'addalbum',
		func  => \&albumInfoHandler,
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

	$log->info("Album Mix plugin initialised");
	return $class;
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe(\&onPlaylistChange);
	Slim::Control::Request::unsubscribe(\&onPlaylistReplaced);
	%playerState = ();
}

sub getDisplayName { return 'PLUGIN_ALBUM_MIX' }

# ============================================================
# Album context menu handler
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

	# Also add a "Stop Album Mix" option if one is active
	my $clientId = $client->master->id;
	if ( $playerState{$clientId} && $playerState{$clientId}->{active} ) {
		return [{
			name => cstring($client, 'PLUGIN_ALBUM_MIX_CREATE'),
			type => 'redirect',
			jive => {
				nextWindow => 'nowPlaying',
				actions    => {
					go => {
						player => 0,
						cmd    => ['albummix', 'start'],
						params => {
							album_name  => $albumName,
							artist_name => $artistName,
							album_id    => $albumId || 0,
						},
					},
				},
			},
			favorites => 0,
		}, {
			name => cstring($client, 'PLUGIN_ALBUM_MIX_STOP'),
			type => 'redirect',
			jive => {
				nextWindow => 'parent',
				actions    => {
					go => {
						player => 0,
						cmd    => ['albummix', 'stop'],
					},
				},
			},
			favorites => 0,
		}];
	}

	return {
		name => cstring($client, 'PLUGIN_ALBUM_MIX_CREATE'),
		type => 'redirect',
		jive => {
			nextWindow => 'nowPlaying',
			actions    => {
				go => {
					player => 0,
					cmd    => ['albummix', 'start'],
					params => {
						album_name  => $albumName,
						artist_name => $artistName,
						album_id    => $albumId || 0,
					},
				},
			},
		},
		favorites => 0,
	};
}

# ============================================================
# CLI handlers
# ============================================================

sub cliStart {
	my $request = shift;
	my $client  = $request->client;
	return unless $client;

	my $albumName  = $request->getParam('album_name');
	my $artistName = $request->getParam('artist_name');
	my $albumId    = $request->getParam('album_id') || 0;

	startAlbumMix($client, $albumName, $artistName, $albumId);
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

sub startAlbumMix {
	my ( $client, $albumName, $artistName, $albumId ) = @_;

	$client = $client->master;
	my $clientId = $client->id;

	$log->info("Starting Album Mix: '$albumName' by '$artistName'");

	# Initialise player state. Starting a new mix replaces any previous
	# session for this player; callbacks still in flight from the old
	# session detect this via _isCurrent() and stop.
	$playerState{$clientId} = {
		active              => 1,
		history             => [],
		artist_history      => [],   # recent artists for cooldown enforcement
		skipped             => {},   # albums that failed to queue (not found / already owned) this session
		seedArtist          => $artistName,
		seedAlbum           => $albumName,
		lastAlbumStartIndex => 0,    # playlist index where the last queued album begins
		pendingLookup       => 0,
		pendingSince        => 0,
		startedAt           => time(),
		# Loading the seed album itself fires "queue replaced" events;
		# ignore them until the seed starts playing (or this time passes)
		guardUntil          => time() + START_GUARD_SECS,
		seedLoaded          => 0,    # set once the seed album has been sent to the playlist
		seenFirstSong       => 0,
		lookupId            => 0,    # increases with every lookup, so a timed-out one can't queue later
	};

	# Record seed in this mix's history (the saved history is updated once
	# the seed has actually loaded)
	_addToHistory($clientId, $artistName, $albumName);
	_addArtistToHistory($clientId, $artistName);

	# Load the seed album
	my $state = $playerState{$clientId};
	if ( $albumId ) {
		$client->execute(['playlistcontrol', 'cmd:load', "album_id:$albumId"]);
		$state->{seedLoaded} = 1;
		_recordPlayed($artistName, $albumName);
	} else {
		_findAndPlayAlbum($client, $artistName, $albumName, 'load', sub {
			my $found = shift;
			return unless _isCurrent($clientId, $state);
			if ( $found ) {
				$state->{seedLoaded} = 1;
				_recordPlayed($artistName, $albumName);
				return;
			}
			$log->warn("Album Mix: Could not load the seed album '$albumName' by '$artistName'");
			stopAlbumMix($client);
		});
	}

	$client->showBriefly({
		jive => {
			type  => 'mixed',
			style => 'add',
			text  => [ cstring($client, 'PLUGIN_ALBUM_MIX_STARTED') . ': ' . $albumName ],
		},
	});
}

sub stopAlbumMix {
	my $client = shift;
	$client = $client->master;
	my $clientId = $client->id;

	if ( $playerState{$clientId} && $playerState{$clientId}->{active} ) {
		$playerState{$clientId}->{active} = 0;
		$log->info("Album Mix stopped for player $clientId");

		$client->showBriefly({
			jive => {
				type  => 'mixed',
				style => 'add',
				text  => [ cstring($client, 'PLUGIN_ALBUM_MIX_STOPPED') ],
			},
		});
	}
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
# Playlist event handler
# ============================================================

sub onPlaylistChange {
	my $request = shift;
	my $client  = $request->client || return;

	$client = $client->master;
	my $clientId = $client->id;

	my $state = $playerState{$clientId};
	return unless $state && $state->{active};

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

	if ( $state->{pendingLookup} ) {
		# A lookup is already running. If it has been pending for too long
		# (e.g. an online service never answered), assume it is stuck and
		# allow a new one rather than letting the mix stall for good.
		return if time() - ($state->{pendingSince} || 0) < LOOKUP_TIMEOUT_SECS;
		$log->warn("Album Mix: Previous lookup timed out, starting a new one");
		$state->{pendingLookup} = 0;
	}

	my $songIndex   = Slim::Player::Source::streamingSongIndex($client);
	my $playlistLen = Slim::Player::Playlist::count($client);
	my $lookahead   = $prefs->get('lookahead') || DEFAULT_LOOKAHEAD;
	my $remaining   = $playlistLen - $songIndex - 1;

	$log->debug("Album Mix: song $songIndex of $playlistLen, $remaining remaining");

	if ( $remaining <= $lookahead ) {
		$log->info("Album Mix: $remaining tracks left, finding next similar album");
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

sub _findNextAlbum {
	my ( $client, $clientId ) = @_;

	my $state = $playerState{$clientId};
	return unless $state && $state->{active};

	$state->{pendingLookup} = 1;
	$state->{pendingSince}  = time();
	$state->{lookupId}++;

	my $apiKey = $prefs->get('lastfm_api_key');
	unless ( $apiKey ) {
		$log->warn("Album Mix: No Last.fm API key configured");
		$state->{pendingLookup} = 0;
		return;
	}

	# --- Extract a seed track from the last queued album ---
	my ( $seedTrack, $seedArtist ) = _getSeedTrack($client, $clientId);

	if ( $seedTrack && $seedArtist ) {
		$log->info("Album Mix: Seed track '$seedTrack' by '$seedArtist'");

		_getSimilarTracks($client, $clientId, $seedArtist, $seedTrack, $apiKey, sub {
			my $similarTracks = shift;

			return unless _isCurrent($clientId, $state);

			if ( $similarTracks && @$similarTracks ) {
				# Try to pick an album from these similar tracks
				_pickAlbumFromSimilarTracks($client, $clientId, $similarTracks, $apiKey);
			} else {
				$log->info("Album Mix: No similar tracks found, falling back to artist similarity");
				_findNextAlbumByArtist($client, $clientId, $state->{seedArtist}, $apiKey);
			}
		});
	} else {
		# Can't determine current track — fall back to artist similarity
		$log->info("Album Mix: Could not extract seed track, falling back to artist similarity");
		_findNextAlbumByArtist($client, $clientId, $state->{seedArtist}, $apiKey);
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

	my $targetIndex;
	if ( $albumTrackCount >= 4 ) {
		# Random track between second (start+1) and second-to-last (end-1) inclusive
		my $lo = $albumStart + 1;
		my $hi = $albumEnd - 1;
		$targetIndex = $lo + int(rand($hi - $lo + 1));
	} elsif ( $albumTrackCount >= 2 ) {
		# Too few tracks for a proper range — use the second track
		$targetIndex = $albumStart + 1;
	} else {
		# Single-track album — use that track
		$targetIndex = $albumStart;
	}

	$log->debug("Album Mix: Seed track — album range [$albumStart..$albumEnd], picked index $targetIndex");

	my $track = Slim::Player::Playlist::track($client, $targetIndex);
	return unless $track;

	my $info = _trackDetails($client, $track);
	return ( $info->{title}, $info->{artist} );
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

	my $url = LASTFM_API_BASE . '?method=track.getSimilar'
		. '&artist=' . uri_escape_utf8($artist)
		. '&track='  . uri_escape_utf8($track)
		. '&limit='  . MAX_SIMILAR_TRACKS
		. '&autocorrect=1'
		. '&api_key=' . $apiKey
		. '&format=json';

	$log->debug("Album Mix: Fetching similar tracks for '$track' by '$artist'");

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http   = shift;
			my $result = eval { decode_json($http->content) };

			if ( $@ || !$result ) {
				$log->warn("Album Mix: JSON parse error: $@");
				$callback->([]);
				return;
			}
			if ( $result->{error} ) {
				$log->warn("Album Mix: Last.fm error: $result->{message}");
				$callback->([]);
				return;
			}

			my @tracks;
			my $similar = $result->{similartracks}->{track} || [];
			$similar = [$similar] if ref $similar eq 'HASH';

			for my $t ( @$similar ) {
				next unless $t->{name} && $t->{artist} && $t->{artist}->{name};

				push @tracks, {
					title  => $t->{name},
					artist => $t->{artist}->{name},
					match  => $t->{match} || 0,
					mbid   => $t->{mbid}  || '',
				};
			}

			$log->info("Album Mix: Found " . scalar(@tracks) . " similar tracks");
			$callback->(\@tracks);
		},
		sub {
			my $http = shift;
			$log->warn("Album Mix: HTTP error: " . ($http->error || 'unknown'));
			$callback->([]);
		},
		{ timeout => 15 },
	)->get($url);
}

# Walk the similar tracks and queue the first album that passes the
# checks and can actually be found. track.getInfo is used to find which
# album each candidate track belongs to.
#
# The order isn't strictly closest-first: the closest few (see Variety)
# are shuffled, with closer matches more likely to come first, so the
# same seed doesn't always lead to the same album.
sub _pickAlbumFromSimilarTracks {
	my ( $client, $clientId, $similarTracks, $apiKey ) = @_;

	my $ordered = _varietyOrder($similarTracks, sub { $_[0]->{match} });

	_tryNextSimilarTrack($client, $clientId, $ordered, 0, $apiKey);
}

sub _tryNextSimilarTrack {
	my ( $client, $clientId, $tracks, $index, $apiKey ) = @_;

	my $state = $playerState{$clientId};
	return unless $state && $state->{active};

	if ( $index >= scalar @$tracks ) {
		# Exhausted all similar tracks — fall back to artist similarity
		$log->info("Album Mix: No suitable album from similar tracks, falling back to artist similarity");
		_findNextAlbumByArtist($client, $clientId, $state->{seedArtist}, $apiKey);
		return;
	}

	my $track = $tracks->[$index];
	my $next  = sub { _tryNextSimilarTrack($client, $clientId, $tracks, $index + 1, $apiKey) };

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

		_queueCandidate($client, $clientId, $track->{artist}, $albumName,
			"via similar track '$track->{title}'", $next);
	});
}

# Why a candidate album should not be queued, or undef if it's fine.
sub _skipReason {
	my ( $clientId, $artist, $album ) = @_;

	my $state = $playerState{$clientId} || return 'no active mix';
	my $key   = _historyKey($artist, $album);

	return 'already played this session'  if grep { $_ eq $key } @{$state->{history}};
	return "already tried: $state->{skipped}->{$key}" if $state->{skipped}->{$key};
	return 'artist on cooldown'           if _isArtistOnCooldown($clientId, $artist);

	if ( my $type = _releaseType($album) ) {
		return "looks like a $type release";
	}

	if ( my $days = _playedRecently($artist, $album) ) {
		return "played $days day" . ($days == 1 ? '' : 's') . " ago";
	}

	return;
}

# If the album title marks it as a release type the settings filter out,
# return that type ('compilation', 'live' or 'single/EP'), else undef.
# Only used for albums the mix picks, never for the album it starts from.
sub _releaseType {
	my $title = lc( shift // '' );

	return 'compilation' if $prefs->get('filter_compilations') && $title =~ $RELEASE_TYPE_PATTERNS{compilation};
	return 'live'        if $prefs->get('filter_live')         && $title =~ $RELEASE_TYPE_PATTERNS{live};
	return 'single/EP'   if $prefs->get('filter_singles')      && $title =~ $RELEASE_TYPE_PATTERNS{single};

	return;
}

# Minimum number of tracks for an album the mix picks, or 0 for no limit.
# Part of the singles/EP filter, so it is off when that filter is off.
sub _minTracks {
	return 0 unless $prefs->get('filter_singles');
	my $min = $prefs->get('min_tracks');
	return defined $min ? $min : DEFAULT_MIN_TRACKS;
}

# Try to queue one candidate album. Only when it was actually found and
# added is it recorded in the history, the artist cooldown and as the
# new seed. If it can't be queued (not found anywhere, or already owned
# in Discovery Mode) it is remembered as skipped for this session and
# $onFail is called so the caller can move on to the next candidate.
sub _queueCandidate {
	my ( $client, $clientId, $artist, $album, $via, $onFail ) = @_;

	my $state = $playerState{$clientId};
	return unless $state && $state->{active};

	my $lookupId = $state->{lookupId};

	# Checked by the online searches just before they add anything, so a
	# search that answers after the mix was stopped or restarted, or after
	# this lookup timed out and a newer one began, doesn't queue an album
	my $isWanted = sub {
		_isCurrent($clientId, $state) && $lookupId == $state->{lookupId};
	};

	$log->info("Album Mix: Trying '$album' by '$artist' ($via)");

	_findAndPlayAlbum($client, $artist, $album, 'add', sub {
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

		$state->{seedArtist} = $artist;
		$state->{seedAlbum}  = $album;

		_addToHistory($clientId, $artist, $album);
		_addArtistToHistory($clientId, $artist);
		_recordPlayed($artist, $album);

		# If the album found under that name has a different title (e.g.
		# Last.fm said "Abbey Road", TIDAL had "Abbey Road (Remastered)"),
		# remember that title too
		if ( $matchedTitle && _historyKey($artist, $matchedTitle) ne _historyKey($artist, $album) ) {
			_addToHistory($clientId, $artist, $matchedTitle);
			_recordPlayed($artist, $matchedTitle);
		}

		$state->{pendingLookup} = 0;

		$client->showBriefly({
			jive => {
				type  => 'mixed',
				style => 'add',
				text  => [ sprintf(
					cstring($client, 'PLUGIN_ALBUM_MIX_QUEUED'),
					"$album — $artist"
				) ],
			},
		});
	}, {
		skipOwned => $prefs->get('discover_new') ? 1 : 0,
		isWanted  => $isWanted,
		minTracks => _minTracks(),
		checkType => 1,
	});
}

# Resolve a track's album via Last.fm track.getInfo
sub _getTrackAlbum {
	my ( $client, $clientId, $artist, $track, $apiKey, $callback ) = @_;

	my $url = LASTFM_API_BASE . '?method=track.getInfo'
		. '&artist=' . uri_escape_utf8($artist)
		. '&track='  . uri_escape_utf8($track)
		. '&autocorrect=1'
		. '&api_key=' . $apiKey
		. '&format=json';

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http   = shift;
			my $result = eval { decode_json($http->content) };

			if ( $@ || !$result || $result->{error} ) {
				$callback->(undef);
				return;
			}

			my $albumName = undef;
			if ( $result->{track} && $result->{track}->{album} ) {
				$albumName = $result->{track}->{album}->{title};
			}

			if ( $albumName ) {
				$log->debug("Album Mix: track.getInfo says '$track' is on album '$albumName'");
			} else {
				$log->debug("Album Mix: track.getInfo returned no album for '$track'");
			}

			$callback->($albumName);
		},
		sub {
			$callback->(undef);
		},
		{ timeout => 15 },
	)->get($url);
}

# ============================================================
# Fallback: artist.getSimilar → artist.getTopAlbums
# ============================================================

sub _findNextAlbumByArtist {
	my ( $client, $clientId, $seedArtist, $apiKey ) = @_;

	my $state = $playerState{$clientId};
	return unless $state && $state->{active};

	$log->info("Album Mix: Artist fallback — finding artists similar to '$seedArtist'");

	_getSimilarArtists($client, $clientId, $seedArtist, $apiKey, sub {
		my $similarArtists = shift;

		return unless _isCurrent($clientId, $state);

		unless ( $similarArtists && @$similarArtists ) {
			$log->warn("Album Mix: No similar artists found for '$seedArtist'");
			$state->{pendingLookup} = 0;
			return;
		}

		# Closest few artists in a weighted random order (see Variety)
		$similarArtists = _varietyOrder($similarArtists, sub { $_[0]->{match} });

		# Include the seed artist for different-album-by-same-artist results
		# (only used when Artist Cooldown is 0, as the seed artist has just played)
		unshift @$similarArtists, {
			name  => $seedArtist,
			match => 1.0,
			mbid  => '',
		};

		_tryNextArtist($client, $clientId, $similarArtists, 0, $apiKey);
	});
}

sub _getSimilarArtists {
	my ( $client, $clientId, $artist, $apiKey, $callback ) = @_;

	my $url = LASTFM_API_BASE . '?method=artist.getSimilar'
		. '&artist=' . uri_escape_utf8($artist)
		. '&limit='  . MAX_SIMILAR_ARTISTS
		. '&api_key=' . $apiKey
		. '&format=json';

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http   = shift;
			my $result = eval { decode_json($http->content) };

			if ( $@ || !$result ) {
				$log->warn("Album Mix: JSON parse error: $@");
				$callback->([]);
				return;
			}
			if ( $result->{error} ) {
				$log->warn("Album Mix: Last.fm error: $result->{message}");
				$callback->([]);
				return;
			}

			my @artists;
			my $similar = $result->{similarartists}->{artist} || [];
			$similar = [$similar] if ref $similar eq 'HASH';

			for my $a ( @$similar ) {
				push @artists, {
					name  => $a->{name},
					match => $a->{match} || 0,
					mbid  => $a->{mbid}  || '',
				};
			}

			$log->info("Album Mix: Found " . scalar(@artists) . " similar artists to '$artist'");
			$callback->(\@artists);
		},
		sub {
			my $http = shift;
			$log->warn("Album Mix: HTTP error: " . ($http->error || 'unknown'));
			$callback->([]);
		},
		{ timeout => 15 },
	)->get($url);
}

sub _tryNextArtist {
	my ( $client, $clientId, $artists, $index, $apiKey ) = @_;

	my $state = $playerState{$clientId};
	return unless $state && $state->{active};

	if ( $index >= scalar @$artists ) {
		$log->warn("Album Mix: Exhausted all similar artists — no new album found");
		$state->{pendingLookup} = 0;

		$client->showBriefly({
			jive => {
				type  => 'mixed',
				style => 'add',
				text  => [ cstring($client, 'PLUGIN_ALBUM_MIX_NO_SIMILAR') ],
			},
		});
		return;
	}

	my $artist = $artists->[$index];
	$log->debug("Album Mix: Trying artist '$artist->{name}' (match: $artist->{match})");

	# Artist cooldown — skip entire artist if picked too recently
	if ( _isArtistOnCooldown($clientId, $artist->{name}) ) {
		$log->debug("Album Mix: '$artist->{name}' on cooldown, skipping (artist fallback)");
		_tryNextArtist($client, $clientId, $artists, $index + 1, $apiKey);
		return;
	}

	_getTopAlbums($client, $clientId, $artist->{name}, $apiKey, sub {
		my $albums = shift;

		return unless _isCurrent($clientId, $state);

		# The artist's top albums minus any that fail the checks, in random
		# order (see Variety) so it isn't always the most popular album
		my @candidates = grep {
			!_skipReason($clientId, $artist->{name}, $_->{name})
		} @$albums;

		my $ordered = _varietyOrder(\@candidates, sub { 1 });

		_tryArtistAlbum($client, $clientId, $artists, $index, $ordered, 0, $apiKey);
	});
}

# Try this artist's candidate albums in turn; when none can be queued,
# move on to the next similar artist.
sub _tryArtistAlbum {
	my ( $client, $clientId, $artists, $artistIndex, $candidates, $albumIndex, $apiKey ) = @_;

	my $state = $playerState{$clientId};
	return unless $state && $state->{active};

	if ( $albumIndex >= scalar @$candidates ) {
		_tryNextArtist($client, $clientId, $artists, $artistIndex + 1, $apiKey);
		return;
	}

	my $artist = $artists->[$artistIndex]->{name};
	my $album  = $candidates->[$albumIndex]->{name};

	_queueCandidate($client, $clientId, $artist, $album, 'artist fallback', sub {
		_tryArtistAlbum($client, $clientId, $artists, $artistIndex, $candidates, $albumIndex + 1, $apiKey);
	});
}

sub _getTopAlbums {
	my ( $client, $clientId, $artist, $apiKey, $callback ) = @_;

	my $url = LASTFM_API_BASE . '?method=artist.getTopAlbums'
		. '&artist=' . uri_escape_utf8($artist)
		. '&limit='  . MAX_TOP_ALBUMS
		. '&api_key=' . $apiKey
		. '&format=json';

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http   = shift;
			my $result = eval { decode_json($http->content) };

			if ( $@ || !$result ) {
				$log->warn("Album Mix: JSON parse error for top albums: $@");
				$callback->([]);
				return;
			}
			if ( $result->{error} ) {
				$log->warn("Album Mix: Last.fm error: $result->{message}");
				$callback->([]);
				return;
			}

			my @albums;
			my $topAlbums = $result->{topalbums}->{album} || [];
			$topAlbums = [$topAlbums] if ref $topAlbums eq 'HASH';

			for my $a ( @$topAlbums ) {
				next unless $a->{name};
				next if $a->{name} =~ /^\s*$/;
				next if lc($a->{name}) eq '(null)';

				push @albums, {
					name      => $a->{name},
					mbid      => $a->{mbid}      || '',
					playcount => $a->{playcount}  || 0,
				};
			}

			$log->debug("Album Mix: Found " . scalar(@albums) . " top albums for '$artist'");
			$callback->(\@albums);
		},
		sub {
			my $http = shift;
			$log->warn("Album Mix: HTTP error fetching top albums: " . ($http->error || 'unknown'));
			$callback->([]);
		},
		{ timeout => 15 },
	)->get($url);
}

# ============================================================
# Album resolution — find in library or online services
# ============================================================

# Find an album and load it ($cmd 'load') or append it ($cmd 'add').
# $callback->($found, $reason) is always called exactly once; $found is
# true only if the album was actually sent to the playlist.
#
# Where to look depends on the settings:
#   Discovery Mode   — online services first, library as last resort.
#                      With $opts->{skipOwned} (used for every album the
#                      mix picks, but not for the seed album) an album that
#                      is in the local library is refused instead, so the
#                      mix only queues music you don't already own.
#   Prefer Local     — library first, then online services.
#   neither          — online services first, library as last resort.
#
# $opts->{isWanted}, if given, is asked just before an online search adds
# its result; if it returns false the album is not added.
# $opts->{minTracks}, if given, rejects albums with fewer tracks (where
# the track count is known).
# $opts->{checkType}: also apply the compilation/live/single filters to the
# title of the album actually found, not just the title that was asked for
# (so asking for "Rumours" can't end up queuing "Rumours (Live)").
#
# On success $callback also gets the title of the album that was queued.
sub _findAndPlayAlbum {
	my ( $client, $artist, $album, $cmd, $callback, $opts ) = @_;

	$callback ||= sub {};
	$opts     ||= {};

	# Record where this album will start in the playlist (for seed track selection)
	my $clientId = $client->master->id;
	my $preCount = Slim::Player::Playlist::count($client);

	my $done = sub {
		my ( $found, $reason, $title ) = @_;

		if ( $found && (my $state = $playerState{$clientId}) ) {
			$state->{lastAlbumStartIndex} = $cmd eq 'load' ? 0 : $preCount;
			$log->debug("Album Mix: Last album starts at playlist index $state->{lastAlbumStartIndex}");
		}

		$callback->($found, $reason, $title);
	};

	my ( $localAlbumId, $localTitle ) = _findLocalAlbum($client, $artist, $album);
	my $ownedId = $localAlbumId;

	# The library copy is a different kind of release (e.g. a live album
	# with a similar name): don't use it
	if ( $localAlbumId && $opts->{checkType} && (my $type = _releaseType($localTitle)) ) {
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
		$client->execute(['playlistcontrol', "cmd:$cmd", "album_id:$localAlbumId"]);
		$done->(1, undef, $localTitle);
	};

	if ( $prefs->get('discover_new') && $opts->{skipOwned} && $ownedId ) {
		$log->info("Album Mix: Discovery Mode — '$album' by '$artist' is already in your library, skipping");
		$done->(0, 'already in library');
		return;
	}

	if ( !$prefs->get('discover_new') && $prefs->get('prefer_local') && $localAlbumId ) {
		$playLocal->();
		return;
	}

	_findOnlineAlbum($client, $artist, $album, $cmd, sub {
		my ( $found, $reason, $title ) = @_;

		if ( $found ) {
			$done->(1, undef, $title);
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

# Number of tracks in a library album, or undef if it can't be counted.
sub _localTrackCount {
	my $albumId = shift;

	my $count = eval {
		my $sth = Slim::Schema->dbh->prepare_cached("SELECT COUNT(*) FROM tracks WHERE album = ?");
		$sth->execute($albumId);
		my ($n) = $sth->fetchrow_array;
		$sth->finish;
		$n;
	};

	return $count;
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

	$handler->($client, $artist, $album, $cmd, sub {
		my ( $found, $reason, $title ) = @_;
		if ( $found ) {
			$callback->(1, undef, $title);
		} elsif ( $reason ) {
			$callback->(0, $reason);
		} else {
			_tryOnlineService($client, $artist, $album, $cmd, $services, $index + 1, $callback, $opts);
		}
	}, $opts);
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
					@items = grep { !_releaseType($_->{name}) } @items if $opts->{checkType};

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
						$client->execute([
							'playlist',
							$cmd eq 'load' ? 'play' : 'add',
							$match->{uri},
						]);
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
					@items = grep { !_releaseType($_->{title}) } @items if $opts->{checkType};

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
						$client->execute([
							'playlist',
							$cmd eq 'load' ? 'play' : 'add',
							"tidal://album:$match->{id}",
						]);
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
# Saved history: remembered across mixes, players and restarts,
# so an album isn't queued again within "Don't Repeat For" days.
# ------------------------------------------------------------

sub _recordPlayed {
	my ( $artist, $album ) = @_;

	my %played = %{ $prefs->get('played_albums') || {} };
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

	$prefs->set('played_albums', \%played);
}

# Days since the album was last queued if that is within the repeat
# window (at least 1), otherwise 0.
sub _playedRecently {
	my ( $artist, $album ) = @_;

	my $days = $prefs->get('repeat_days') || 0;
	return 0 unless $days > 0;

	my $played = $prefs->get('played_albums') || {};
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
	my ( $items, $weightOf ) = @_;

	my $n = $prefs->get('variety');
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
	my $cooldown = $prefs->get('artist_cooldown') || DEFAULT_ARTIST_COOLDOWN;

	push @{$state->{artist_history}}, _nameKey($artist);

	# Keep list trimmed to cooldown size (we only need the last N)
	while ( scalar @{$state->{artist_history}} > $cooldown ) {
		shift @{$state->{artist_history}};
	}
}

sub _isArtistOnCooldown {
	my ( $clientId, $artist ) = @_;

	my $state = $playerState{$clientId} || return 0;
	my $cooldown = $prefs->get('artist_cooldown') || 0;

	return 0 unless $cooldown > 0;

	my $key = _nameKey($artist);
	return grep { $_ eq $key } @{$state->{artist_history}};
}

1;
