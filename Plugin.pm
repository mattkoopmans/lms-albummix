package Plugins::AlbumMix::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use Scalar::Util qw(blessed);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use Slim::Networking::SimpleAsyncHTTP;

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use constant LASTFM_API_BASE      => 'https://ws.audioscrobbler.com/2.0/';
use constant DEFAULT_MAX_HISTORY  => 50;
use constant DEFAULT_LOOKAHEAD    => 2;
use constant MAX_SIMILAR_TRACKS   => 50;   # candidates from track.getSimilar
use constant MAX_SIMILAR_ARTISTS  => 20;   # fallback: artist.getSimilar
use constant MAX_TOP_ALBUMS       => 10;   # fallback: artist.getTopAlbums

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
		lastfm_api_key => '',
		max_history    => DEFAULT_MAX_HISTORY,
		prefer_local   => 1,
		lookahead      => DEFAULT_LOOKAHEAD,
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

	# Initialise player state
	$playerState{$clientId} = {
		active              => 1,
		history             => [],
		seedArtist          => $artistName,
		seedAlbum           => $albumName,
		lastAlbumStartIndex => 0,    # playlist index where the last queued album begins
		pendingLookup       => 0,
	};

	# Record seed in history
	_addToHistory($clientId, $artistName, $albumName);

	# Load the seed album
	if ( $albumId ) {
		$client->execute(['playlistcontrol', 'cmd:load', "album_id:$albumId"]);
	} else {
		_findAndPlayAlbum($client, $artistName, $albumName, 'load');
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

# ============================================================
# Playlist event handler
# ============================================================

sub onPlaylistChange {
	my $request = shift;
	my $client  = $request->client || return;

	$client = $client->master;
	my $clientId = $client->id;

	return unless $playerState{$clientId} && $playerState{$clientId}->{active};
	return if $playerState{$clientId}->{pendingLookup};

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

# ============================================================
# Similar album discovery via Last.fm
#
# Primary:  track.getSimilar on the second-to-last song of the
#           current album — finds a sonically similar track,
#           then resolves that track's album.
# Fallback: artist.getSimilar → artist.getTopAlbums when track
#           similarity returns nothing useful.
# ============================================================

sub _findNextAlbum {
	my ( $client, $clientId ) = @_;

	my $state = $playerState{$clientId};
	return unless $state && $state->{active};

	$state->{pendingLookup} = 1;

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

# Pick a random track between the second and penultimate of the last
# queued album to use as the seed for similarity lookups.
sub _getSeedTrack {
	my ( $client, $clientId ) = @_;

	my $playlistLen = Slim::Player::Playlist::count($client);
	return unless $playlistLen;

	# Determine the range of the last queued album in the playlist
	my $state = $playerState{$clientId};
	my $albumStart = ($state && defined $state->{lastAlbumStartIndex})
		? $state->{lastAlbumStartIndex} : 0;
	my $albumEnd = $playlistLen - 1;
	my $albumTrackCount = $albumEnd - $albumStart + 1;

	my $targetIndex;
	if ( $albumTrackCount >= 4 ) {
		# Random track between second (start+1) and penultimate (end-1) inclusive
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

	my ( $title, $artist );

	if ( blessed($track) ) {
		$title = $track->title;

		# Try to get the track's artist
		if ( $track->can('artistName') ) {
			$artist = $track->artistName;
		}
		if ( !$artist && $track->can('artist') ) {
			my $a = $track->artist;
			$artist = $a->name if $a && blessed($a);
		}

		# Try remote metadata if local metadata is missing
		if ( (!$title || !$artist) && $track->can('url') ) {
			my $handler = Slim::Player::ProtocolHandlers->handlerForURL($track->url);
			if ( $handler && $handler->can('getMetadataFor') ) {
				my $meta = $handler->getMetadataFor($client, $track->url);
				if ( $meta ) {
					$title  ||= $meta->{title};
					$artist ||= $meta->{artist};
				}
			}
		}
	}

	return ( $title, $artist );
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

# Walk similar tracks and find an album we haven't played yet.
# For each candidate track, we need to resolve which album it belongs to.
# Strategy: use Last.fm track.getInfo to get the album, or search locally.
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
	$log->debug("Album Mix: Checking similar track '$track->{title}' by '$track->{artist}' (match: $track->{match})");

	# First, try to resolve the album via track.getInfo (which includes album name)
	_getTrackAlbum($client, $clientId, $track->{artist}, $track->{title}, $apiKey, sub {
		my $albumName = shift;

		my $state = $playerState{$clientId};
		return unless $state && $state->{active};

		if ( $albumName ) {
			my $key = _historyKey($track->{artist}, $albumName);
			if ( grep { $_ eq $key } @{$state->{history}} ) {
				# Already played this album — try next track
				$log->debug("Album Mix: '$albumName' by '$track->{artist}' already in history, skipping");
				_tryNextSimilarTrack($client, $clientId, $tracks, $index + 1, $apiKey);
				return;
			}

			$log->info("Album Mix: Selected '$albumName' by '$track->{artist}' (via similar track '$track->{title}')");

			$state->{seedArtist} = $track->{artist};
			$state->{seedAlbum}  = $albumName;

			_addToHistory($clientId, $track->{artist}, $albumName);

			_findAndPlayAlbum($client, $track->{artist}, $albumName, 'add', sub {
				$state->{pendingLookup} = 0;

				$client->showBriefly({
					jive => {
						type  => 'mixed',
						style => 'add',
						text  => [ sprintf(
							cstring($client, 'PLUGIN_ALBUM_MIX_QUEUED'),
							"$albumName — $track->{artist}"
						) ],
					},
				});
			});
		} else {
			# No album info for this track — try the next similar track
			_tryNextSimilarTrack($client, $clientId, $tracks, $index + 1, $apiKey);
		}
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

		unless ( $similarArtists && @$similarArtists ) {
			$log->warn("Album Mix: No similar artists found for '$seedArtist'");
			$state->{pendingLookup} = 0;
			return;
		}

		# Include the seed artist for different-album-by-same-artist results
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

	_getTopAlbums($client, $clientId, $artist->{name}, $apiKey, sub {
		my $albums = shift;

		my $state = $playerState{$clientId};
		return unless $state && $state->{active};

		my @candidates;
		for my $album ( @$albums ) {
			my $key = _historyKey($artist->{name}, $album->{name});
			unless ( grep { $_ eq $key } @{$state->{history}} ) {
				push @candidates, {
					artist => $artist->{name},
					album  => $album->{name},
					mbid   => $album->{mbid} || '',
				};
			}
		}

		if ( @candidates ) {
			my $pick = $candidates[0];
			$log->info("Album Mix: Selected '$pick->{album}' by '$pick->{artist}' (artist fallback)");

			$state->{seedArtist} = $pick->{artist};
			$state->{seedAlbum}  = $pick->{album};

			_addToHistory($clientId, $pick->{artist}, $pick->{album});

			_findAndPlayAlbum($client, $pick->{artist}, $pick->{album}, 'add', sub {
				$state->{pendingLookup} = 0;

				$client->showBriefly({
					jive => {
						type  => 'mixed',
						style => 'add',
						text  => [ sprintf(
							cstring($client, 'PLUGIN_ALBUM_MIX_QUEUED'),
							"$pick->{album} — $pick->{artist}"
						) ],
					},
				});
			});
		} else {
			_tryNextArtist($client, $clientId, $artists, $index + 1, $apiKey);
		}
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

sub _findAndPlayAlbum {
	my ( $client, $artist, $album, $cmd, $callback ) = @_;

	$callback ||= sub {};

	# Record where this album will start in the playlist (for seed track selection)
	my $clientId = $client->master->id;
	my $preCount = Slim::Player::Playlist::count($client);

	my $wrappedCallback = sub {
		# After the album is added, record its start index
		my $postCount = Slim::Player::Playlist::count($client);
		if ( my $state = $playerState{$clientId} ) {
			if ( $cmd eq 'load' ) {
				$state->{lastAlbumStartIndex} = 0;
			} else {
				$state->{lastAlbumStartIndex} = $preCount;
			}
			$log->debug("Album Mix: Last album starts at playlist index $state->{lastAlbumStartIndex} (playlist now $postCount tracks)");
		}
		$callback->();
	};

	if ( $prefs->get('prefer_local') ) {
		_findLocalAlbum($client, $artist, $album, sub {
			my $localAlbumId = shift;

			if ( $localAlbumId ) {
				$log->info("Album Mix: Found '$album' in local library (id: $localAlbumId)");
				$client->execute(['playlistcontrol', "cmd:$cmd", "album_id:$localAlbumId"]);
				$wrappedCallback->();
			} else {
				_findOnlineAlbum($client, $artist, $album, $cmd, $wrappedCallback);
			}
		});
	} else {
		_findOnlineAlbum($client, $artist, $album, $cmd, $wrappedCallback);
	}
}

sub _findLocalAlbum {
	my ( $client, $artist, $album, $callback ) = @_;

	my $dbh = Slim::Schema->dbh;

	# Exact match
	my $sth = $dbh->prepare_cached(
		"SELECT albums.id FROM albums "
		. "JOIN contributors ON contributors.id = albums.contributor "
		. "WHERE albums.title = ? AND contributors.name = ? "
		. "LIMIT 1"
	);
	$sth->execute($album, $artist);
	my ($albumId) = $sth->fetchrow_array;
	$sth->finish;

	if ( $albumId ) {
		$callback->($albumId);
		return;
	}

	# Case-insensitive match
	$sth = $dbh->prepare_cached(
		"SELECT albums.id FROM albums "
		. "JOIN contributors ON contributors.id = albums.contributor "
		. "WHERE LOWER(albums.title) = LOWER(?) AND LOWER(contributors.name) = LOWER(?) "
		. "LIMIT 1"
	);
	$sth->execute($album, $artist);
	($albumId) = $sth->fetchrow_array;
	$sth->finish;

	if ( $albumId ) {
		$callback->($albumId);
		return;
	}

	# LIKE match for partial titles (e.g. "Album" matches "Album (Deluxe)")
	$sth = $dbh->prepare_cached(
		"SELECT albums.id FROM albums "
		. "JOIN contributors ON contributors.id = albums.contributor "
		. "WHERE LOWER(albums.title) LIKE ? AND LOWER(contributors.name) LIKE ? "
		. "LIMIT 1"
	);
	$sth->execute( '%' . lc($album) . '%', '%' . lc($artist) . '%' );
	($albumId) = $sth->fetchrow_array;
	$sth->finish;

	$callback->($albumId);
}

sub _findOnlineAlbum {
	my ( $client, $artist, $album, $cmd, $callback ) = @_;

	$callback ||= sub {};

	$log->info("Album Mix: Searching online services for '$album' by '$artist'");

	my @services = _getAvailableServices();

	if ( @services ) {
		_tryOnlineService($client, $artist, $album, $cmd, \@services, 0, $callback);
	} else {
		# No online services — try local as last resort
		_findLocalAlbum($client, $artist, $album, sub {
			my $albumId = shift;
			if ( $albumId ) {
				$client->execute(['playlistcontrol', "cmd:$cmd", "album_id:$albumId"]);
			} else {
				$log->warn("Album Mix: Could not find '$album' by '$artist' anywhere");
			}
			$callback->();
		});
	}
}

sub _getAvailableServices {
	my @services;

	push @services, 'spotty'
		if Slim::Utils::PluginManager->isEnabled('Plugins::Spotty::Plugin');

	push @services, 'tidal'
		if Slim::Utils::PluginManager->isEnabled('Plugins::TIDAL::Plugin');

	push @services, 'qobuz'
		if Slim::Utils::PluginManager->isEnabled('Plugins::Qobuz::Plugin');

	push @services, 'deezer'
		if Slim::Utils::PluginManager->isEnabled('Plugins::Deezer::Plugin');

	return @services;
}

sub _tryOnlineService {
	my ( $client, $artist, $album, $cmd, $services, $index, $callback ) = @_;

	$callback ||= sub {};

	if ( $index >= scalar @$services ) {
		$log->info("Album Mix: No online service had '$album' by '$artist'");
		$callback->();
		return;
	}

	my $service = $services->[$index];
	$log->debug("Album Mix: Trying $service");

	my $handler = {
		spotty => \&_searchSpotty,
		tidal  => \&_searchTidal,
	}->{$service};

	if ( $handler ) {
		$handler->($client, $artist, $album, $cmd, sub {
			my $found = shift;
			if ( $found ) {
				$callback->();
			} else {
				_tryOnlineService($client, $artist, $album, $cmd, $services, $index + 1, $callback);
			}
		});
	} else {
		_tryOnlineService($client, $artist, $album, $cmd, $services, $index + 1, $callback);
	}
}

sub _searchSpotty {
	my ( $client, $artist, $album, $cmd, $callback ) = @_;

	eval {
		if ( Plugins::Spotty::Plugin->can('getAPIHandler') ) {
			my $api = Plugins::Spotty::Plugin->getAPIHandler($client);
			if ( $api && $api->can('search') ) {
				$api->search(sub {
					my $results = shift;

					if ( $results && $results->{albums} && $results->{albums}->{items} ) {
						for my $item ( @{$results->{albums}->{items}} ) {
							if ( $item->{uri} ) {
								$log->info("Album Mix: Found on Spotify: $item->{name}");
								$client->execute([
									'playlist',
									$cmd eq 'load' ? 'play' : 'add',
									$item->{uri},
								]);
								$callback->(1);
								return;
							}
						}
					}

					$callback->(0);
				}, {
					search => "album:$album artist:$artist",
					type   => 'albums',
					limit  => 5,
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
				$api->search(sub {
					my $results = shift;

					my @items;
					if ( $results && $results->{albums} ) {
						@items = ref $results->{albums} eq 'ARRAY'
							? @{$results->{albums}}
							: ($results->{albums}->{items}
								? @{$results->{albums}->{items}} : ());
					}

					for my $item ( @items ) {
						if ( my $id = $item->{id} ) {
							$log->info("Album Mix: Found on TIDAL: " . ($item->{title} || $id));
							$client->execute([
								'playlist',
								$cmd eq 'load' ? 'play' : 'add',
								"tidal://$id.flac",
							]);
							$callback->(1);
							return;
						}
					}

					$callback->(0);
				}, {
					search => "$artist $album",
					type   => 'albums',
					limit  => 5,
				});
				return;
			}
		}
		$callback->(0);
	};

	if ( $@ ) {
		$log->debug("Album Mix: TIDAL search error: $@");
		$callback->(0);
	}
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

1;
