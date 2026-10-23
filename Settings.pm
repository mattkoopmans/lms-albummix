package Plugins::AlbumMix::Settings;

# Server-wide settings page (Settings > Advanced > Album Mix). These are
# also the defaults for every player that doesn't use its own settings
# (see PlayerSettings.pm).

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
		lastfm_api_key max_history source lookahead artist_cooldown
		filter_compilations filter_live filter_singles min_tracks variety
		repeat_days history_scope include_seed
	));
}

sub handler {
	my ( $class, $client, $params ) = @_;

	# "Clear saved history" is a one-off action, not a setting. On this page
	# it clears the shared history (each player's own history is cleared
	# from that player's settings page).
	if ( $params->{saveSettings} && $params->{clear_history} ) {
		$prefs->set('played_albums', {});
	}

	# Must be set before SUPER::handler, which renders the page
	my $played = $prefs->get('played_albums') || {};
	$params->{played_count} = scalar keys %$played;

	my $result = $class->SUPER::handler($client, $params);

	# Keep the 1.2 settings in step with Source, so going back to 1.2
	# behaves (nearly) the same way; see Plugin.pm _syncLegacyPrefs
	Plugins::AlbumMix::Plugin::_syncLegacyPrefs() if $params->{saveSettings};

	return $result;
}

1;
