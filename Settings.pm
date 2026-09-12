package Plugins::AlbumMix::Settings;

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.albummix');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_ALBUM_MIX_SETTINGS');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/AlbumMix/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(lastfm_api_key max_history prefer_local discover_new lookahead artist_cooldown));
}

1;
