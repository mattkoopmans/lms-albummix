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

# Prefs saved from the settings form. The saved history (played_albums)
# is deliberately not listed, so saving the form never touches it.
sub prefs {
	return ($prefs, qw(
		lastfm_api_key max_history prefer_local discover_new lookahead artist_cooldown
		filter_compilations filter_live filter_singles min_tracks variety repeat_days
	));
}

sub handler {
	my ( $class, $client, $params ) = @_;

	# "Clear saved history" is a one-off action, not a setting
	if ( $params->{saveSettings} && $params->{clear_history} ) {
		$prefs->set('played_albums', {});
	}

	my $played = $prefs->get('played_albums') || {};
	$params->{played_count} = scalar keys %$played;

	return $class->SUPER::handler($client, $params);
}

1;
