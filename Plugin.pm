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
	});

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
		seenFirstSong       => 0,
	};

	# Record seed in history
	_addToHistory($clientId, $artistName, $albumName);
	_addArtistToHistory($clientId, $artistName);

	# Load the seed album
	if ( $albumId ) {
		$client->execute(['playlistcontrol', 'cmd:load', "album_id:$albumId"]);
	} else {
		my $state = $playerState{$clientId};
		_findAndPlayAlbum($client, $artistName, $albumName, 'load', sub {
			my $found = shift;
			return if $found || !_isCurrent($clientId, $state);
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
	# loading, so end the start-up guard shortly after
	unless ( $state->{seenFirstSong} ) {
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

# Walk the similar tracks in order and queue the first album that passes
# the checks and can actually be found. track.getInfo is used to find
# which album each candidate track belongs to.
sub _pickAlbumFromSimilarTracks {
	my ( $client, $clientId, $similarTracks, $apiKey ) = @_;

	_tryNextSimilarTrack($client, $clientId, $similarTracks, 0, $apiKey);
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

	return;
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

	$log->info("Album Mix: Trying '$album' by '$artist' ($via)");

	_findAndPlayAlbum($client, $artist, $album, 'add', sub {
		my ( $found, $reason ) = @_;

		return unless _isCurrent($clientId, $state);

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
	}, { skipOwned => $prefs->get('discover_new') ? 1 : 0 });
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

		# Albums in Last.fm popularity order, minus any that were already
		# played or already tried this session
		my @candidates = grep {
			!_skipReason($clientId, $artist->{name}, $_->{name})
		} @$albums;

		_tryArtistAlbum($client, $clientId, $artists, $index, \@candidates, 0, $apiKey);
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
sub _findAndPlayAlbum {
	my ( $client, $artist, $album, $cmd, $callback, $opts ) = @_;

	$callback ||= sub {};
	$opts     ||= {};

	# Record where this album will start in the playlist (for seed track selection)
	my $clientId = $client->master->id;
	my $preCount = Slim::Player::Playlist::count($client);

	my $done = sub {
		my ( $found, $reason ) = @_;

		if ( $found && (my $state = $playerState{$clientId}) ) {
			$state->{lastAlbumStartIndex} = $cmd eq 'load' ? 0 : $preCount;
			$log->debug("Album Mix: Last album starts at playlist index $state->{lastAlbumStartIndex}");
		}

		$callback->($found, $reason);
	};

	my $localAlbumId = _findLocalAlbum($client, $artist, $album);

	my $playLocal = sub {
		$log->info("Album Mix: Found '$album' in local library (id: $localAlbumId)");
		$client->execute(['playlistcontrol', "cmd:$cmd", "album_id:$localAlbumId"]);
		$done->(1);
	};

	if ( $prefs->get('discover_new') && $opts->{skipOwned} && $localAlbumId ) {
		$log->info("Album Mix: Discovery Mode — '$album' by '$artist' is already in your library, skipping");
		$done->(0, 'already in library');
		return;
	}

	if ( !$prefs->get('discover_new') && $prefs->get('prefer_local') && $localAlbumId ) {
		$playLocal->();
		return;
	}

	_findOnlineAlbum($client, $artist, $album, $cmd, sub {
		my $found = shift;

		if ( $found ) {
			$done->(1);
		} elsif ( $localAlbumId ) {
			# Not online — fall back to the library copy
			$playLocal->();
		} else {
			$log->warn("Album Mix: Could not find '$album' by '$artist' in the library or online");
			$done->(0, 'not found in library or online');
		}
	});
}

# Look an album up in the local library. Returns the album id, or undef.
# Tries an exact match, then case-insensitive, then a partial title match
# (so "Album" also finds "Album (Deluxe)").
sub _findLocalAlbum {
	my ( $client, $artist, $album ) = @_;

	my $dbh = Slim::Schema->dbh;

	my @queries = (
		# Exact match
		[ "WHERE albums.title = ? AND contributors.name = ? ",
			$album, $artist ],
		# Case-insensitive match
		[ "WHERE LOWER(albums.title) = LOWER(?) AND LOWER(contributors.name) = LOWER(?) ",
			$album, $artist ],
		# LIKE match for partial titles (e.g. "Album" matches "Album (Deluxe)")
		[ "WHERE LOWER(albums.title) LIKE ? AND LOWER(contributors.name) LIKE ? ",
			'%' . lc($album) . '%', '%' . lc($artist) . '%' ],
	);

	for my $q ( @queries ) {
		my ( $where, @bind ) = @$q;

		my $sth = $dbh->prepare_cached(
			"SELECT albums.id FROM albums "
			. "JOIN contributors ON contributors.id = albums.contributor "
			. $where
			. "LIMIT 1"
		);
		$sth->execute(@bind);
		my ($albumId) = $sth->fetchrow_array;
		$sth->finish;

		return $albumId if $albumId;
	}

	return;
}

# Search the enabled online services in turn.
# $callback->(1) once one of them has added the album, $callback->(0) if
# none had it (or no supported service is enabled).
sub _findOnlineAlbum {
	my ( $client, $artist, $album, $cmd, $callback ) = @_;

	my @services = _getAvailableServices();

	unless ( @services ) {
		$log->info("Album Mix: No supported online service enabled");
		$callback->(0);
		return;
	}

	$log->info("Album Mix: Searching online services for '$album' by '$artist'");
	_tryOnlineService($client, $artist, $album, $cmd, \@services, 0, $callback);
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
	my ( $client, $artist, $album, $cmd, $services, $index, $callback ) = @_;

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
		_tryOnlineService($client, $artist, $album, $cmd, $services, $index + 1, $callback);
		return;
	}

	$handler->($client, $artist, $album, $cmd, sub {
		my $found = shift;
		if ( $found ) {
			$callback->(1);
		} else {
			_tryOnlineService($client, $artist, $album, $cmd, $services, $index + 1, $callback);
		}
	});
}

sub _searchSpotty {
	my ( $client, $artist, $album, $cmd, $callback ) = @_;

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

					# Only accept a result whose artist and album title match
					my $match = _bestAlbumMatch($artist, $album, \@items,
						sub { $_[0]->{name} },
						sub { $_[0]->{artists} && $_[0]->{artists}->[0] ? $_[0]->{artists}->[0]->{name} : '' },
					);

					if ( $match ) {
						$log->info("Album Mix: Found on Spotify: $match->{name}");
						$client->execute([
							'playlist',
							$cmd eq 'load' ? 'play' : 'add',
							$match->{uri},
						]);
						$callback->(1);
						return;
					}

					$log->info("Album Mix: No matching album found on Spotify");
					$callback->(0);
				}, {
					search => "album:$album artist:$artist",
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
	my ( $client, $artist, $album, $cmd, $callback ) = @_;

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

					$log->info("Album Mix: TIDAL returned " . scalar(@items) . " album results");

					# Only accept a result whose artist and album title match,
					# so a different album by the same artist isn't queued
					my $match = _bestAlbumMatch($artist, $album, \@items,
						sub { $_[0]->{title} },
						sub {
							my $a = $_[0]->{artist} || ($_[0]->{artists} && $_[0]->{artists}->[0]) || {};
							return $a->{name} || '';
						},
					);

					if ( $match ) {
						my $itemArtist = $match->{artist} || ($match->{artists} && $match->{artists}->[0]) || {};
						$log->info("Album Mix: Found on TIDAL: $match->{title} by " . ($itemArtist->{name} || '?') . " (id: $match->{id})");
						$client->execute([
							'playlist',
							$cmd eq 'load' ? 'play' : 'add',
							"tidal://album:$match->{id}",
						]);
						$callback->(1);
						return;
					}

					$log->info("Album Mix: No matching album found on TIDAL");
					$callback->(0);
				}, {
					search => "$artist $album",
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

# Reduce a name to a comparable form: lower case, no bracketed notes such
# as "(Deluxe Edition)" or "[2011 Remaster]", no " - Remastered" style
# suffixes, "&" read as "and", no leading "The", no punctuation.
sub _normaliseName {
	my $name = lc( shift // '' );
	my $orig = $name;

	$name =~ s/\s*[\(\[][^\)\]]*[\)\]]//g;
	$name =~ s/\s+-\s+.*\b(?:remaster(?:ed)?|deluxe|edition|expanded|anniversary|version|mono|stereo|bonus)\b.*$//;
	$name =~ s/&/ and /g;
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

sub _historyKey {
	my ( $artist, $album ) = @_;
	return lc("$artist|||$album");
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

	push @{$state->{artist_history}}, lc($artist);

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

	my $lcArtist = lc($artist);
	return grep { $_ eq $lcArtist } @{$state->{artist_history}};
}

1;
