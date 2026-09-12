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
use constant DEFAULT_MAX_HISTORY      => 50;
use constant DEFAULT_LOOKAHEAD        => 2;
use constant DEFAULT_ARTIST_COOLDOWN  => 5;    # skip artist for N album picks after playing
use constant MAX_SIMILAR_TRACKS       => 50;   # candidates from track.getSimilar
use constant MAX_SIMILAR_ARTISTS      => 20;   # fallback: artist.getSimilar
use constant MAX_TOP_ALBUMS           => 10;   # fallback: artist.getTopAlbums

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
		artist_history      => [],   # recent artists for cooldown enforcement
		seedArtist          => $artistName,
		seedAlbum           => $albumName,
		lastAlbumStartIndex => 0,    # playlist index where the last queued album begins
		pendingLookup       => 0,
	};

	# Record seed in history
	_addToHistory($clientId, $artistName, $albumName);
	_addArtistToHistory($clientId, $artistName);

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
#           current album â finds a sonically similar track,
#           then resolves that track's album.
# Fallback: artist.getSimilar â artist.getTopAlbums when track
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
		# Can't determine current track â fall back to artist similarity
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
		# Too few tracks for a proper range â use the second track
		$targetIndex = $albumStart + 1;
	} else {
		# Single-track album â use that track
		$targetIndex = $albumStart;
	}

	$log->debug("Album Mix: Seed track â album r²FÆ'VÕ7F'BââFÆ'VÔVæEÒÂ6¶VBæFWGF&vWDæFW"°  ×GG&6²Ò6ÆÓ£¥ÆW#£¥ÆÆ7C£§G&6²F6ÆVçBÂGF&vWDæFW° &WGW&âVæÆW72GG&6³°  ×GFFÆRÂF'F7B°  b&ÆW76VBGG&6²° GFFÆRÒGG&6²ÓçFFÆS°  2G'FòvWBFRG&6²w2'F7@ bGG&6²Óæ6âv'F7DæÖRr° F'F7BÒGG&6²Óæ'F7DæÖS° Ð bF'F7BbbGG&6²Óæ6âv'F7Br° ×FÒGG&6²Óæ'F7C° F'F7BÒFÓææÖRbFbb&ÆW76VBF° Ð  2G'&VÖ÷FRÖWFFFbÆö6ÂÖWFFF2Ö76æp bGFFÆRÇÂF'F7BbbGG&6²Óæ6âwW&Âr° ×FæFÆW"Ò6ÆÓ£¥ÆW#£¥&÷Fö6öÄæFÆW'2ÓææFÆW$f÷%U$ÂGG&6²ÓçW&Â° bFæFÆW"bbFæFÆW"Óæ6âvvWDÖWFFFf÷"r° ×FÖWFÒFæFÆW"ÓævWDÖWFFFf÷"F6ÆVçBÂGG&6²ÓçW&Â° bFÖWF° GFFÆRÇÃÒFÖWFÓç·FFÆWÓ° F'F7BÇÃÒFÖWFÓç¶'F7GÓ° Ð Ð Ð Ð  &WGW&âGFFÆRÂF'F7B°§Ð ¢2ÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ¢2&Ö'¢G&6²ævWE6ÖÆ"&6VBF66÷fW'¢2ÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ §7V"övWE6ÖÆ%G&6·2° ×F6ÆVçBÂF6ÆVçDBÂF'F7BÂGG&6²ÂF¶WÂF6ÆÆ&6²Òó°  ×GW&ÂÒÄ5DdÕôô$4RâsöÖWFöC×G&6²ævWE6ÖÆ"p ârf'F7CÒrâW&öW66U÷WFcF'F7B ârgG&6³ÒrâW&öW66U÷WFcGG&6² ârfÆÖCÒrâÔõ4ÔÄ%õE$4µ0 ârfWFö6÷'&V7CÓp ârfö¶WÒrâF¶W ârff÷&ÖCÖ§6öâs°  FÆörÓæFV'Vr$Æ'VÒÖ¢fWF6ær6ÖÆ"G&6·2f÷"rGG&6²r'rF'F7Br"°  6ÆÓ£¤æWGv÷&¶æs£¥6×ÆT7æ4EEÓææWr 7V"° ×FGGÒ6gC° ×G&W7VÇBÒWfÂ²FV6öFUö§6öâFGGÓæ6öçFVçBÓ°  bDÇÂG&W7VÇB° FÆörÓçv&â$Æ'VÒÖ¢¥4ôâ'6RW'&÷#¢D"° F6ÆÆ&6²ÓâµÒ° &WGW&ã° Ð bG&W7VÇBÓç¶W'&÷'Ò° FÆörÓçv&â$Æ'VÒÖ¢Æ7BæfÒW'&÷#¢G&W7VÇBÓç¶ÖW76vWÒ"° F6ÆÆ&6²ÓâµÒ° &WGW&ã° Ð  ×G&6·3° ×G6ÖÆ"ÒG&W7VÇBÓç·6ÖÆ'G&6·7ÒÓç·G&6·ÒÇÂµÓ° G6ÖÆ"Ò²G6ÖÆ%Òb&VbG6ÖÆ"Wt4s°  f÷"×GBG6ÖÆ"° æWBVæÆW72GBÓç¶æÖWÒbbGBÓç¶'F7GÒbbGBÓç¶'F7GÒÓç¶æÖWÓ°  W6G&6·2Â° FFÆRÓâGBÓç¶æÖWÒÀ 'F7BÓâGBÓç¶'F7GÒÓç¶æÖWÒÀ ÖF6ÓâGBÓç¶ÖF6ÒÇÂÀ Ö&BÓâGBÓç¶Ö&GÒÇÂrrÀ Ó° Ð  FÆörÓææfò$Æ'VÒÖ¢f÷VæB"â66Æ"G&6·2â"6ÖÆ"G&6·2"° F6ÆÆ&6²ÓâÄG&6·2° ÒÀ 7V"° ×FGGÒ6gC° FÆörÓçv&â$Æ'VÒÖ¢EEW'&÷#¢"âFGGÓæW'&÷"ÇÂwVæ¶æ÷vâr° F6ÆÆ&6²ÓâµÒ° ÒÀ ²FÖV÷WBÓâRÒÀ ÓævWBGW&Â°§Ð ¢2vÆ²6ÖÆ"G&6·2æBfæBâÆ'VÒvRfVâwBÆVBWBà¢2f÷"V66æFFFRG&6²ÂvRæVVBFò&W6öÇfRv6Æ'VÒB&VÆöæw2Fòà¢27G&FVw¢W6RÆ7BæfÒG&6²ævWDæfòFòvWBFRÆ'VÒÂ÷"6V&6Æö6ÆÇà§7V"÷6´Æ'VÔg&öÕ6ÖÆ%G&6·2° ×F6ÆVçBÂF6ÆVçDBÂG6ÖÆ%G&6·2ÂF¶WÒó°  ÷G'æWE6ÖÆ%G&6²F6ÆVçBÂF6ÆVçDBÂG6ÖÆ%G&6·2ÂÂF¶W°§Ð §7V"÷G'æWE6ÖÆ%G&6²° ×F6ÆVçBÂF6ÆVçDBÂGG&6·2ÂFæFWÂF¶WÒó°  ×G7FFRÒGÆW%7FFW²F6ÆVçDGÓ° &WGW&âVæÆW72G7FFRbbG7FFRÓç¶7FfWÓ°  bFæFWãÒ66Æ"GG&6·2° 2WW7FVBÆÂ6ÖÆ"G&6·2(	BfÆÂ&6²Fò'F7B6ÖÆ&G FÆörÓææfò$Æ'VÒÖ¢æò7VF&ÆRÆ'VÒg&öÒ6ÖÆ"G&6·2ÂfÆÆær&6²Fò'F7B6ÖÆ&G"° öfæDæWDÆ'VÔ''F7BF6ÆVçBÂF6ÆVçDBÂG7FFRÓç·6VVD'F7GÒÂF¶W° &WGW&ã° Ð  ×GG&6²ÒGG&6·2Óå²FæFWÓ° FÆörÓæFV'Vr$Æ'VÒÖ¢6V6¶ær6ÖÆ"G&6²rGG&6²Óç·FFÆWÒr'rGG&6²Óç¶'F7GÒrÖF6¢GG&6²Óç¶ÖF6Ò"°  2f'7BÂG'Fò&W6öÇfRFRÆ'VÒfG&6²ævWDæfòv6æ6ÇVFW2Æ'VÒæÖR övWEG&6´Æ'VÒF6ÆVçBÂF6ÆVçDBÂGG&6²Óç¶'F7GÒÂGG&6²Óç·FFÆWÒÂF¶WÂ7V"° ×FÆ'VÔæÖRÒ6gC°  ×G7FFRÒGÆW%7FFW²F6ÆVçDGÓ° &WGW&âVæÆW72G7FFRbbG7FFRÓç¶7FfWÓ°  bFÆ'VÔæÖR° ×F¶WÒö7F÷'¶WGG&6²Óç¶'F7GÒÂFÆ'VÔæÖR° bw&W²EòWF¶WÒ²G7FFRÓç¶7F÷'×Ò° 2Ç&VGÆVBF2Æ'VÒ(	BG'æWBG&6° FÆörÓæFV'Vr$Æ'VÒÖ¢rFÆ'VÔæÖRr'rGG&6²Óç¶'F7GÒrÇ&VGâ7F÷'Â6¶ær"° ÷G'æWE6ÖÆ%G&6²F6ÆVçBÂF6ÆVçDBÂGG&6·2ÂFæFW²ÂF¶W° &WGW&ã° Ð  2'F7B6ööÆF÷vâ(	B6¶bF2'F7Bv26¶VBFöò&V6VçFÇ bö4'F7Döä6ööÆF÷vâF6ÆVçDBÂGG&6²Óç¶'F7GÒ° FÆörÓæFV'Vr$Æ'VÒÖ¢rGG&6²Óç¶'F7GÒröâ6ööÆF÷vâÂ6¶ærrFÆ'VÔæÖRr"° ÷G'æWE6ÖÆ%G&6²F6ÆVçBÂF6ÆVçDBÂGG&6·2ÂFæFW²ÂF¶W° &WGW&ã° Ð  FÆörÓææfò$Æ'VÒÖ¢6VÆV7FVBrFÆ'VÔæÖRr'rGG&6²Óç¶'F7GÒrf6ÖÆ"G&6²rGG&6²Óç·FFÆWÒr"°  G7FFRÓç·6VVD'F7GÒÒGG&6²Óç¶'F7GÓ° G7FFRÓç·6VVDÆ'V×ÒÒFÆ'VÔæÖS°  öFEFô7F÷'F6ÆVçDBÂGG&6²Óç¶'F7GÒÂFÆ'VÔæÖR° öFD'F7EFô7F÷'F6ÆVçDBÂGG&6²Óç¶'F7GÒ°  öfæDæEÆÆ'VÒF6ÆVçBÂGG&6²Óç¶'F7GÒÂFÆ'VÔæÖRÂvFBrÂ7V"° G7FFRÓç·VæFætÆöö·WÒÒ°  F6ÆVçBÓç6÷t'&VfÇ° ¦fRÓâ° GRÓâvÖVBrÀ 7GÆRÓâvFBrÀ FWBÓâ²7&çFb 77G&ærF6ÆVçBÂuÅTtåôÄ%TÕôÔõTUTTBrÀ "FÆ'VÔæÖR(	BGG&6²Óç¶'F7GÒ  ÒÀ ÒÀ Ò° Ò° ÒVÇ6R° 2æòÆ'VÒæfòf÷"F2G&6²(	BG'FRæWB6ÖÆ"G&6° ÷G'æWE6ÖÆ%G&6²F6ÆVçBÂF6ÆVçDBÂGG&6·2ÂFæFW²ÂF¶W° Ð Ò°§Ð ¢2&W6öÇfRG&6²w2Æ'VÒfÆ7BæfÒG&6²ævWDæfð§7V"övWEG&6´Æ'VÒ° ×F6ÆVçBÂF6ÆVçDBÂF'F7BÂGG&6²ÂF¶WÂF6ÆÆ&6²Òó°  ×GW&ÂÒÄ5DdÕôô$4RâsöÖWFöC×G&6²ævWDæfòp ârf'F7CÒrâW&öW66U÷WFcF'F7B ârgG&6³ÒrâW&öW66U÷WFcGG&6² ârfWFö6÷'&V7CÓp ârfö¶WÒrâF¶W ârff÷&ÖCÖ§6öâs°  6ÆÓ£¤æWGv÷&¶æs£¥6×ÆT7æ4EEÓææWr 7V"° ×FGGÒ6gC° ×G&W7VÇBÒWfÂ²FV6öFUö§6öâFGGÓæ6öçFVçBÓ°  bDÇÂG&W7VÇBÇÂG&W7VÇBÓç¶W'&÷'Ò° F6ÆÆ&6²ÓâVæFVb° &WGW&ã° Ð  ×FÆ'VÔæÖRÒVæFVc° bG&W7VÇBÓç·G&6·ÒbbG&W7VÇBÓç·G&6·ÒÓç¶Æ'V×Ò° FÆ'VÔæÖRÒG&W7VÇBÓç·G&6·ÒÓç¶Æ'V×ÒÓç·FFÆWÓ° Ð  bFÆ'VÔæÖR° FÆörÓæFV'Vr$Æ'VÒÖ¢G&6²ævWDæfò62rGG&6²r2öâÆ'VÒrFÆ'VÔæÖRr"° ÒVÇ6R° FÆörÓæFV'Vr$Æ'VÒÖ¢G&6²ævWDæfò&WGW&æVBæòÆ'VÒf÷"rGG&6²r"° Ð  F6ÆÆ&6²ÓâFÆ'VÔæÖR° ÒÀ 7V"° F6ÆÆ&6²ÓâVæFVb° ÒÀ ²FÖV÷WBÓâRÒÀ ÓævWBGW&Â°§Ð ¢2ÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ¢2fÆÆ&6³¢'F7BævWE6ÖÆ"(i"'F7BævWEF÷Æ'V×0¢2ÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ §7V"öfæDæWDÆ'VÔ''F7B° ×F6ÆVçBÂF6ÆVçDBÂG6VVD'F7BÂF¶WÒó°  ×G7FFRÒGÆW%7FFW²F6ÆVçDGÓ° &WGW&âVæÆW72G7FFRbbG7FFRÓç¶7FfWÓ°  FÆörÓææfò$Æ'VÒÖ¢'F7BfÆÆ&6²(	BfæFær'F7G26ÖÆ"FòrG6VVD'F7Br"°  övWE6ÖÆ$'F7G2F6ÆVçBÂF6ÆVçDBÂG6VVD'F7BÂF¶WÂ7V"° ×G6ÖÆ$'F7G2Ò6gC°  VæÆW72G6ÖÆ$'F7G2bbG6ÖÆ$'F7G2° FÆörÓçv&â$Æ'VÒÖ¢æò6ÖÆ"'F7G2f÷VæBf÷"rG6VVD'F7Br"° G7FFRÓç·VæFætÆöö·WÒÒ° &WGW&ã° Ð  2æ6ÇVFRFR6VVB'F7Bf÷"FffW&VçBÖÆ'VÒÖ'×6ÖRÖ'F7B&W7VÇG0 Vç6gBG6ÖÆ$'F7G2Â° æÖRÓâG6VVD'F7BÀ ÖF6ÓâãÀ Ö&BÓârrÀ Ó°  ÷G'æWD'F7BF6ÆVçBÂF6ÆVçDBÂG6ÖÆ$'F7G2ÂÂF¶W° Ò°§Ð §7V"övWE6ÖÆ$'F7G2° ×F6ÆVçBÂF6ÆVçDBÂF'F7BÂF¶WÂF6ÆÆ&6²Òó°  ×GW&ÂÒÄ5DdÕôô$4RâsöÖWFöCÖ'F7BævWE6ÖÆ"p ârf'F7CÒrâW&öW66U÷WFcF'F7B ârfÆÖCÒrâÔõ4ÔÄ%ô%D5E0 ârfö¶WÒrâF¶W ârff÷&ÖCÖ§6öâs°  6ÆÓ£¤æWGv÷&¶æs£¥6×ÆT7æ4EEÓææWr 7V"° ×FGGÒ6gC° ×G&W7VÇBÒWfÂ²FV6öFUö§6öâFGGÓæ6öçFVçBÓ°  bDÇÂG&W7VÇB° FÆörÓçv&â$Æ'VÒÖ¢¥4ôâ'6RW'&÷#¢D"° F6ÆÆ&6²ÓâµÒ° &WGW&ã° Ð bG&W7VÇBÓç¶W'&÷'Ò° FÆörÓçv&â$Æ'VÒÖ¢Æ7BæfÒW'&÷#¢G&W7VÇBÓç¶ÖW76vWÒ"° F6ÆÆ&6²ÓâµÒ° &WGW&ã° Ð  ×'F7G3° ×G6ÖÆ"ÒG&W7VÇBÓç·6ÖÆ&'F7G7ÒÓç¶'F7GÒÇÂµÓ° G6ÖÆ"Ò²G6ÖÆ%Òb&VbG6ÖÆ"Wt4s°  f÷"×FG6ÖÆ"° W6'F7G2Â° æÖRÓâFÓç¶æÖWÒÀ ÖF6ÓâFÓç¶ÖF6ÒÇÂÀ Ö&BÓâFÓç¶Ö&GÒÇÂrrÀ Ó° Ð  FÆörÓææfò$Æ'VÒÖ¢f÷VæB"â66Æ"'F7G2â"6ÖÆ"'F7G2FòrF'F7Br"° F6ÆÆ&6²ÓâÄ'F7G2° ÒÀ 7V"° ×FGGÒ6gC° FÆörÓçv&â$Æ'VÒÖ¢EEW'&÷#¢"âFGGÓæW'&÷"ÇÂwVæ¶æ÷vâr° F6ÆÆ&6²ÓâµÒ° ÒÀ ²FÖV÷WBÓâRÒÀ ÓævWBGW&Â°§Ð §7V"÷G'æWD'F7B° ×F6ÆVçBÂF6ÆVçDBÂF'F7G2ÂFæFWÂF¶WÒó°  ×G7FFRÒGÆW%7FFW²F6ÆVçDGÓ° &WGW&âVæÆW72G7FFRbbG7FFRÓç¶7FfWÓ°  bFæFWãÒ66Æ"F'F7G2° FÆörÓçv&â$Æ'VÒÖ¢WW7FVBÆÂ6ÖÆ"'F7G2(	BæòæWrÆ'VÒf÷VæB"° G7FFRÓç·VæFætÆöö·WÒÒ°  F6ÆVçBÓç6÷t'&VfÇ° ¦fRÓâ° GRÓâvÖVBrÀ 7GÆRÓâvFBrÀ FWBÓâ²77G&ærF6ÆVçBÂuÅTtåôÄ%TÕôÔôäõõ4ÔÄ"rÒÀ ÒÀ Ò° &WGW&ã° Ð  ×F'F7BÒF'F7G2Óå²FæFWÓ° FÆörÓæFV'Vr$Æ'VÒÖ¢G'ær'F7BrF'F7BÓç¶æÖWÒrÖF6¢F'F7BÓç¶ÖF6Ò"°  2'F7B6ööÆF÷vâ(	B6¶VçF&R'F7Bb6¶VBFöò&V6VçFÇ bö4'F7Döä6ööÆF÷vâF6ÆVçDBÂF'F7BÓç¶æÖWÒ° FÆörÓæFV'Vr$Æ'VÒÖ¢rF'F7BÓç¶æÖWÒröâ6ööÆF÷vâÂ6¶ær'F7BfÆÆ&6²"° ÷G'æWD'F7BF6ÆVçBÂF6ÆVçDBÂF'F7G2ÂFæFW²ÂF¶W° &WGW&ã° Ð  övWEF÷Æ'V×2F6ÆVçBÂF6ÆVçDBÂF'F7BÓç¶æÖWÒÂF¶WÂ7V"° ×FÆ'V×2Ò6gC°  ×G7FFRÒGÆW%7FFW²F6ÆVçDGÓ° &WGW&âVæÆW72G7FFRbbG7FFRÓç¶7FfWÓ°  ×6æFFFW3° f÷"×FÆ'VÒFÆ'V×2° ×F¶WÒö7F÷'¶WF'F7BÓç¶æÖWÒÂFÆ'VÒÓç¶æÖWÒ° VæÆW72w&W²EòWF¶WÒ²G7FFRÓç¶7F÷'×Ò° W66æFFFW2Â° 'F7BÓâF'F7BÓç¶æÖWÒÀ Æ'VÒÓâFÆ'VÒÓç¶æÖWÒÀ Ö&BÓâFÆ'VÒÓç¶Ö&GÒÇÂrrÀ Ó° Ð Ð  b6æFFFW2° ×G6²ÒF6æFFFW5³Ó° FÆörÓææfò$Æ'VÒÖ¢6VÆV7FVBrG6²Óç¶Æ'V×Òr'rG6²Óç¶'F7GÒr'F7BfÆÆ&6²"°  G7FFRÓç·6VVD'F7GÒÒG6²Óç¶'F7GÓ° G7FFRÓç·6VVDÆ'V×ÒÒG6²Óç¶Æ'V×Ó°  öFEFô7F÷'F6ÆVçDBÂG6²Óç¶'F7GÒÂG6²Óç¶Æ'V×Ò° öFD'F7EFô7F÷'F6ÆVçDBÂG6²Óç¶'F7GÒ°  öfæDæEÆÆ'VÒF6ÆVçBÂG6²Óç¶'F7GÒÂG6²Óç¶Æ'V×ÒÂvFBrÂ7V"° G7FFRÓç·VæFætÆöö·WÒÒ°  F6ÆVçBÓç6÷t'&VfÇ° ¦fRÓâ° GRÓâvÖVBrÀ 7GÆRÓâvFBrÀ FWBÓâ²7&çFb 77G&ærF6ÆVçBÂuÅTtåôÄ%TÕôÔõTUTTBrÀ "G6²Óç¶Æ'V×Ò(	BG6²Óç¶'F7GÒ  ÒÀ ÒÀ Ò° Ò° ÒVÇ6R° ÷G'æWD'F7BF6ÆVçBÂF6ÆVçDBÂF'F7G2ÂFæFW²ÂF¶W° Ð Ò°§Ð §7V"övWEF÷Æ'V×2° ×F6ÆVçBÂF6ÆVçDBÂF'F7BÂF¶WÂF6ÆÆ&6²Òó°  ×GW&ÂÒÄ5DdÕôô$4RâsöÖWFöCÖ'F7BævWEF÷Æ'V×2p ârf'F7CÒrâW&öW66U÷WFcF'F7B ârfÆÖCÒrâÔõDõôÄ%TÕ0 ârfö¶WÒrâF¶W ârff÷&ÖCÖ§6öâs°  6ÆÓ£¤æWGv÷&¶æs£¥6×ÆT7æ4EEÓææWr 7V"° ×FGGÒ6gC° ×G&W7VÇBÒWfÂ²FV6öFUö§6öâFGGÓæ6öçFVçBÓ°  bDÇÂG&W7VÇB° FÆörÓçv&â$Æ'VÒÖ¢¥4ôâ'6RW'&÷"f÷"F÷Æ'V×3¢D"° F6ÆÆ&6²ÓâµÒ° &WGW&ã° Ð bG&W7VÇBÓç¶W'&÷'Ò° FÆörÓçv&â$Æ'VÒÖ¢Æ7BæfÒW'&÷#¢G&W7VÇBÓç¶ÖW76vWÒ"° F6ÆÆ&6²ÓâµÒ° &WGW&ã° Ð  ×Æ'V×3° ×GF÷Æ'V×2ÒG&W7VÇBÓç·F÷Æ'V×7ÒÓç¶Æ'V×ÒÇÂµÓ° GF÷Æ'V×2Ò²GF÷Æ'V×5Òb&VbGF÷Æ'V×2Wt4s°  f÷"×FGF÷Æ'V×2° æWBVæÆW72FÓç¶æÖWÓ° æWBbFÓç¶æÖWÒ×âõåÇ2¢Bó° æWBbÆ2FÓç¶æÖWÒWrçVÆÂs°  W6Æ'V×2Â° æÖRÓâFÓç¶æÖWÒÀ Ö&BÓâFÓç¶Ö&GÒÇÂrrÀ Æ6÷VçBÓâFÓç·Æ6÷VçGÒÇÂÀ Ó° Ð  FÆörÓæFV'Vr$Æ'VÒÖ¢f÷VæB"â66Æ"Æ'V×2â"F÷Æ'V×2f÷"rF'F7Br"° F6ÆÆ&6²ÓâÄÆ'V×2° ÒÀ 7V"° ×FGGÒ6gC° FÆörÓçv&â$Æ'VÒÖ¢EEW'&÷"fWF6ærF÷Æ'V×3¢"âFGGÓæW'&÷"ÇÂwVæ¶æ÷vâr° F6ÆÆ&6²ÓâµÒ° ÒÀ ²FÖV÷WBÓâRÒÀ ÓævWBGW&Â°§Ð ¢2ÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ¢2Æ'VÒ&W6öÇWFöâ(	BfæBâÆ'&'÷"öæÆæR6W'f6W0¢2ÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ §7V"öfæDæEÆÆ'VÒ° ×F6ÆVçBÂF'F7BÂFÆ'VÒÂF6ÖBÂF6ÆÆ&6²Òó°  F6ÆÆ&6²ÇÃÒ7V"·Ó°  2&V6÷&BvW&RF2Æ'VÒvÆÂ7F'BâFRÆÆ7Bf÷"6VVBG&6²6VÆV7Föâ ×F6ÆVçDBÒF6ÆVçBÓæÖ7FW"ÓæC° ×G&T6÷VçBÒ6ÆÓ£¥ÆW#£¥ÆÆ7C£¦6÷VçBF6ÆVçB°  ×Gw&VD6ÆÆ&6²Ò7V"° 2gFW"FRÆ'VÒ2FFVBÂ&V6÷&BG27F'BæFW ×G÷7D6÷VçBÒ6ÆÓ£¥ÆW#£¥ÆÆ7C£¦6÷VçBF6ÆVçB° b×G7FFRÒGÆW%7FFW²F6ÆVçDGÒ° bF6ÖBWvÆöBr° G7FFRÓç¶Æ7DÆ'VÕ7F'DæFWÒÒ° ÒVÇ6R° G7FFRÓç¶Æ7DÆ'VÕ7F'DæFWÒÒG&T6÷VçC° Ð FÆörÓæFV'Vr$Æ'VÒÖ¢Æ7BÆ'VÒ7F'G2BÆÆ7BæFWG7FFRÓç¶Æ7DÆ'VÕ7F'DæFWÒÆÆ7Bæ÷rG÷7D6÷VçBG&6·2"° Ð F6ÆÆ&6²Óâ° Ó°  bG&Vg2ÓævWBvF66÷fW%öæWrr° 2F66÷fW'ÖöFS¢&VfW"Æ'V×2äõBâFRÆö6ÂÆ'&' 2G'öæÆæRf'7C²fÆÂ&6²FòÆö6ÂöæÇböæÆæRfÇ0 öfæDöæÆæTÆ'VÒF6ÆVçBÂF'F7BÂFÆ'VÒÂF6ÖBÂGw&VD6ÆÆ&6²Â7V"° 2öæÆæRfÆVB(	BfÆÂ&6²FòÆö6À öfæDÆö6ÄÆ'VÒF6ÆVçBÂF'F7BÂFÆ'VÒÂ7V"° ×FÆö6ÄÆ'VÔBÒ6gC°  bFÆö6ÄÆ'VÔB° FÆörÓææfò$Æ'VÒÖ¢F66÷fW'fÆÆ&6²(	Bf÷VæBrFÆ'VÒrÆö6ÆÇC¢FÆö6ÄÆ'VÔB"° F6ÆVçBÓæWV7WFR²wÆÆ7F6öçG&öÂrÂ&6ÖC¢F6ÖB"Â&Æ'VÕöC¢FÆö6ÄÆ'VÔB%Ò° Gw&VD6ÆÆ&6²Óâ° ÒVÇ6R° FÆörÓçv&â$Æ'VÒÖ¢6÷VÆBæ÷BfæBrFÆ'VÒr'rF'F7BrçvW&R"° Gw&VD6ÆÆ&6²Óâ° Ð Ò° Ò° ÒVÇ6bG&Vg2ÓævWBw&VfW%öÆö6Âr° öfæDÆö6ÄÆ'VÒF6ÆVçBÂF'F7BÂFÆ'VÒÂ7V"° ×FÆö6ÄÆ'VÔBÒ6gC°  bFÆö6ÄÆ'VÔB° FÆörÓææfò$Æ'VÒÖ¢f÷VæBrFÆ'VÒrâÆö6ÂÆ'&'C¢FÆö6ÄÆ'VÔB"° F6ÆVçBÓæWV7WFR²wÆÆ7F6öçG&öÂrÂ&6ÖC¢F6ÖB"Â&Æ'VÕöC¢FÆö6ÄÆ'VÔB%Ò° Gw&VD6ÆÆ&6²Óâ° ÒVÇ6R° öfæDöæÆæTÆ'VÒF6ÆVçBÂF'F7BÂFÆ'VÒÂF6ÖBÂGw&VD6ÆÆ&6²° Ð Ò° ÒVÇ6R° öfæDöæÆæTÆ'VÒF6ÆVçBÂF'F7BÂFÆ'VÒÂF6ÖBÂGw&VD6ÆÆ&6²° Ð§Ð §7V"öfæDÆö6ÄÆ'VÒ° ×F6ÆVçBÂF'F7BÂFÆ'VÒÂF6ÆÆ&6²Òó°  ×FF&Ò6ÆÓ£¥66VÖÓæF&°  2W7BÖF6 ×G7FÒFF&Óç&W&Uö66VB %4TÄT5BÆ'V×2æBe$ôÒÆ'V×2  â$¤ôâ6öçG&'WF÷'2ôâ6öçG&'WF÷'2æBÒÆ'V×2æ6öçG&'WF÷"  â%tU$RÆ'V×2çFFÆRÒòäB6öçG&'WF÷'2ææÖRÒò  â$ÄÔB  ° G7FÓæWV7WFRFÆ'VÒÂF'F7B° ×FÆ'VÔBÒG7FÓæfWF6&÷uö'&° G7FÓæfæ6°  bFÆ'VÔB° F6ÆÆ&6²ÓâFÆ'VÔB° &WGW&ã° Ð  266RÖç6Vç6FfRÖF6 G7FÒFF&Óç&W&Uö66VB %4TÄT5BÆ'V×2æBe$ôÒÆ'V×2  â$¤ôâ6öçG&'WF÷'2ôâ6öçG&'WF÷'2æBÒÆ'V×2æ6öçG&'WF÷"  â%tU$RÄõtU"Æ'V×2çFFÆRÒÄõtU"òäBÄõtU"6öçG&'WF÷'2ææÖRÒÄõtU"ò  â$ÄÔB  ° G7FÓæWV7WFRFÆ'VÒÂF'F7B° FÆ'VÔBÒG7FÓæfWF6&÷uö'&° G7FÓæfæ6°  bFÆ'VÔB° F6ÆÆ&6²ÓâFÆ'VÔB° &WGW&ã° Ð  2Ä´RÖF6f÷"'FÂFFÆW2Rærâ$Æ'VÒ"ÖF6W2$Æ'VÒFVÇWR" G7FÒFF&Óç&W&Uö66VB %4TÄT5BÆ'V×2æBe$ôÒÆ'V×2  â$¤ôâ6öçG&'WF÷'2ôâ6öçG&'WF÷'2æBÒÆ'V×2æ6öçG&'WF÷"  â%tU$RÄõtU"Æ'V×2çFFÆRÄ´RòäBÄõtU"6öçG&'WF÷'2ææÖRÄ´Rò  â$ÄÔB  ° G7FÓæWV7WFRrRrâÆ2FÆ'VÒârRrÂrRrâÆ2F'F7BârRr° FÆ'VÔBÒG7FÓæfWF6&÷uö'&° G7FÓæfæ6°  F6ÆÆ&6²ÓâFÆ'VÔB°§Ð §7V"öfæDöæÆæTÆ'VÒ° ×F6ÆVçBÂF'F7BÂFÆ'VÒÂF6ÖBÂF6ÆÆ&6²ÂFW'&÷$6ÆÆ&6²Òó°  F6ÆÆ&6²ÇÃÒ7V"·Ó°  FÆörÓææfò$Æ'VÒÖ¢6V&6æröæÆæR6W'f6W2f÷"rFÆ'VÒr'rF'F7Br"°  ×6W'f6W2ÒövWDfÆ&ÆU6W'f6W2°  b6W'f6W2° ÷G'öæÆæU6W'f6RF6ÆVçBÂF'F7BÂFÆ'VÒÂF6ÖBÂÄ6W'f6W2ÂÂF6ÆÆ&6²ÂFW'&÷$6ÆÆ&6²° ÒVÇ6R° bFW'&÷$6ÆÆ&6²° 2F66÷fW'ÖöFS¢ÆWB6ÆÆW"æFÆRFRfÆÆ&6° FW'&÷$6ÆÆ&6²Óâ° ÒVÇ6R° 2æòöæÆæR6W'f6W2(	BG'Æö6Â2Æ7B&W6÷'@ öfæDÆö6ÄÆ'VÒF6ÆVçBÂF'F7BÂFÆ'VÒÂ7V"° ×FÆ'VÔBÒ6gC° bFÆ'VÔB° F6ÆVçBÓæWV7WFR²wÆÆ7F6öçG&öÂrÂ&6ÖC¢F6ÖB"Â&Æ'VÕöC¢FÆ'VÔB%Ò° ÒVÇ6R° FÆörÓçv&â$Æ'VÒÖ¢6÷VÆBæ÷BfæBrFÆ'VÒr'rF'F7BrçvW&R"° Ð F6ÆÆ&6²Óâ° Ò° Ð Ð§Ð §7V"övWDfÆ&ÆU6W'f6W2° ×6W'f6W3°  W66W'f6W2Âw7÷GGp b6ÆÓ£¥WFÇ3£¥ÇVväÖævW"Óæ4Væ&ÆVBuÇVvç3£¥7÷GG£¥ÇVvâr°  W66W'f6W2ÂwFFÂp b6ÆÓ£¥WFÇ3£¥ÇVväÖævW"Óæ4Væ&ÆVBuÇVvç3£¥DDÃ£¥ÇVvâr°  W66W'f6W2Âwö'W¢p b6ÆÓ£¥WFÇ3£¥ÇVväÖævW"Óæ4Væ&ÆVBuÇVvç3£¥ö'W££¥ÇVvâr°  W66W'f6W2ÂvFVW¦W"p b6ÆÓ£¥WFÇ3£¥ÇVväÖævW"Óæ4Væ&ÆVBuÇVvç3£¤FVW¦W#£¥ÇVvâr°  &WGW&â6W'f6W3°§Ð §7V"÷G'öæÆæU6W'f6R° ×F6ÆVçBÂF'F7BÂFÆ'VÒÂF6ÖBÂG6W'f6W2ÂFæFWÂF6ÆÆ&6²ÂFW'&÷$6ÆÆ&6²Òó°  F6ÆÆ&6²ÇÃÒ7V"·Ó°  bFæFWãÒ66Æ"G6W'f6W2° FÆörÓææfò$Æ'VÒÖ¢æòöæÆæR6W'f6RBrFÆ'VÒr'rF'F7Br"° bFW'&÷$6ÆÆ&6²° FW'&÷$6ÆÆ&6²Óâ° ÒVÇ6R° F6ÆÆ&6²Óâ° Ð &WGW&ã° Ð  ×G6W'f6RÒG6W'f6W2Óå²FæFWÓ° FÆörÓæFV'Vr$Æ'VÒÖ¢G'ærG6W'f6R"°  ×FæFÆW"Ò° 7÷GGÓâÂe÷6V&67÷GGÀ FFÂÓâÂe÷6V&6FFÂÀ ÒÓç²G6W'f6WÓ°  bFæFÆW"° FæFÆW"ÓâF6ÆVçBÂF'F7BÂFÆ'VÒÂF6ÖBÂ7V"° ×Ff÷VæBÒ6gC° bFf÷VæB° F6ÆÆ&6²Óâ° ÒVÇ6R° ÷G'öæÆæU6W'f6RF6ÆVçBÂF'F7BÂFÆ'VÒÂF6ÖBÂG6W'f6W2ÂFæFW²ÂF6ÆÆ&6²ÂFW'&÷$6ÆÆ&6²° Ð Ò° ÒVÇ6R° ÷G'öæÆæU6W'f6RF6ÆVçBÂF'F7BÂFÆ'VÒÂF6ÖBÂG6W'f6W2ÂFæFW²ÂF6ÆÆ&6²ÂFW'&÷$6ÆÆ&6²° Ð§Ð §7V"÷6V&67÷GG° ×F6ÆVçBÂF'F7BÂFÆ'VÒÂF6ÖBÂF6ÆÆ&6²Òó°  WfÂ° bÇVvç3£¥7÷GG£¥ÇVvâÓæ6âvvWDæFÆW"r° ×FÒÇVvç3£¥7÷GG£¥ÇVvâÓævWDæFÆW"F6ÆVçB° bFbbFÓæ6âw6V&6r° FÓç6V&67V"° ×G&W7VÇG2Ò6gC°  b&VbG&W7VÇG2Wt4rbbG&W7VÇG2Óç¶Æ'V×7Òbb&VbG&W7VÇG2Óç¶Æ'V×7ÒWt4rbbG&W7VÇG2Óç¶Æ'V×7ÒÓç¶FV×7Ò° f÷"×FFVÒ²G&W7VÇG2Óç¶Æ'V×7ÒÓç¶FV×7×Ò° bFFVÒÓç·W&Ò° FÆörÓææfò$Æ'VÒÖ¢f÷VæBöâ7÷Fg¢FFVÒÓç¶æÖWÒ"° F6ÆVçBÓæWV7WFR° wÆÆ7BrÀ F6ÖBWvÆöBròwÆr¢vFBrÀ FFVÒÓç·W&ÒÀ Ò° F6ÆÆ&6²Óâ° &WGW&ã° Ð Ð Ð  F6ÆÆ&6²Óâ° ÒÂ° 6V&6Óâ&Æ'VÓ¢FÆ'VÒ'F7C¢F'F7B"À GRÓâvÆ'V×2rÀ ÆÖBÓâRÀ Ò° &WGW&ã° Ð Ð F6ÆÆ&6²Óâ° Ó°  bD° FÆörÓæFV'Vr$Æ'VÒÖ¢7÷GG6V&6W'&÷#¢D"° F6ÆÆ&6²Óâ° Ð§Ð §7V"÷6V&6FFÂ° ×F6ÆVçBÂF'F7BÂFÆ'VÒÂF6ÖBÂF6ÆÆ&6²Òó°  WfÂ° bÇVvç3£¥DDÃ£¥ÇVvâÓæ6âvvWDæFÆW"r° ×FÒÇVvç3£¥DDÃ£¥ÇVvâÓævWDæFÆW"F6ÆVçB° bFbbFÓæ6âw6V&6r° FÓç6V&67V"° ×G&W7VÇG2Ò6gC°  ×FV×3° b&VbG&W7VÇG2Wt4rbbG&W7VÇG2Óç¶Æ'V×7Ò° FV×2Ò&VbG&W7VÇG2Óç¶Æ'V×7ÒWt%$p ò²G&W7VÇG2Óç¶Æ'V×7×Ð ¢&VbG&W7VÇG2Óç¶Æ'V×7ÒWt4rbbG&W7VÇG2Óç¶Æ'V×7ÒÓç¶FV×7Ð ò²G&W7VÇG2Óç¶Æ'V×7ÒÓç¶FV×7×Ò¢° Ð  f÷"×FFVÒFV×2° b×FBÒFFVÒÓç¶GÒ° FÆörÓææfò$Æ'VÒÖ¢f÷VæBöâDDÃ¢"âFFVÒÓç·FFÆWÒÇÂFB° F6ÆVçBÓæWV7WFR° wÆÆ7BrÀ F6ÖBWvÆöBròwÆr¢vFBrÀ 'FFÃ¢òòFBæfÆ2"À Ò° F6ÆÆ&6²Óâ° &WGW&ã° Ð Ð  F6ÆÆ&6²Óâ° ÒÂ° 6V&6Óâ"F'F7BFÆ'VÒ"À GRÓâvÆ'V×2rÀ ÆÖBÓâRÀ Ò° &WGW&ã° Ð Ð F6ÆÆ&6²Óâ° Ó°  bD° FÆörÓæFV'Vr$Æ'VÒÖ¢DDÂ6V&6W'&÷#¢D"° F6ÆÆ&6²Óâ° Ð§Ð ¢2ÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ¢27F÷'ÖævVÖVç@¢2ÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ §7V"ö7F÷'¶W° ×F'F7BÂFÆ'VÒÒó° &WGW&âÆ2"F'F7GÇÇÂFÆ'VÒ"°§Ð §7V"öFEFô7F÷'° ×F6ÆVçDBÂF'F7BÂFÆ'VÒÒó°  ×G7FFRÒGÆW%7FFW²F6ÆVçDGÒÇÂ&WGW&ã° ×F¶WÒö7F÷'¶WF'F7BÂFÆ'VÒ° ×FÖ7F÷'ÒG&Vg2ÓævWBvÖö7F÷'rÇÂDTdTÅEôÔô5Dõ%°  W6²G7FFRÓç¶7F÷'×ÒÂF¶W°  vÆR66Æ"²G7FFRÓç¶7F÷'×ÒâFÖ7F÷'° 6gB²G7FFRÓç¶7F÷'×Ó° Ð§Ð ¢2ÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ¢2'F7B6ööÆF÷vâÖævVÖVç@¢2ÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ §7V"öFD'F7EFô7F÷'° ×F6ÆVçDBÂF'F7BÒó°  ×G7FFRÒGÆW%7FFW²F6ÆVçDGÒÇÂ&WGW&ã° ×F6ööÆF÷vâÒG&Vg2ÓævWBv'F7Eö6ööÆF÷vârÇÂDTdTÅEô%D5Eô4ôôÄDõtã°  W6²G7FFRÓç¶'F7Eö7F÷'×ÒÂÆ2F'F7B°  2¶VWÆ7BG&ÖÖVBFò6ööÆF÷vâ6¦RvRöæÇæVVBFRÆ7Bâ vÆR66Æ"²G7FFRÓç¶'F7Eö7F÷'×ÒâF6ööÆF÷vâ° 6gB²G7FFRÓç¶'F7Eö7F÷'×Ó° Ð§Ð §7V"ö4'F7Döä6ööÆF÷vâ° ×F6ÆVçDBÂF'F7BÒó°  ×G7FFRÒGÆW%7FFW²F6ÆVçDGÒÇÂ&WGW&â° ×F6ööÆF÷vâÒG&Vg2ÓævWBv'F7Eö6ööÆF÷vârÇÂ°  &WGW&âVæÆW72F6ööÆF÷vââ°  ×FÆ4'F7BÒÆ2F'F7B° &WGW&âw&W²EòWFÆ4'F7BÒ²G7FFRÓç¶'F7Eö7F÷'×Ó°§Ð £°
