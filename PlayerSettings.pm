package Plugins::AlbumMix::PlayerSettings;

# Per-player settings page (Settings > Player > Album Mix). A player uses
# the server-wide settings (Settings.pm) unless "Use own settings for this
# player" is ticked; Plugin.pm's _pref() decides which value applies.
# Synced players follow the main player of the group.

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.albummix');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_ALBUM_MIX');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/AlbumMix/settings/player.html');
}

sub needsClient { 1 }

sub prefs {
	my ( $class, $client ) = @_;
	return ($prefs->client($client), 'own_settings', Plugins::AlbumMix::Plugin::playerPrefNames());
}

sub handler {
	my ( $class, $client, $params ) = @_;

	return $class->SUPER::handler($client, $params) unless $client;

	my $cp = Plugins::AlbumMix::Plugin::_clientPrefs($client);

	# The saved history in use is the main player's when synced
	my $hp = $prefs->client( $client->can('master') ? $client->master : $client );

	# Clearing this player's own saved history (used when History Scope is
	# "separate per player")
	if ( $params->{saveSettings} && $params->{clear_history} ) {
		$hp->set('played_albums', {});
	}

	# First visit: start the player's own values from the current server
	# defaults, so ticking "Use own settings" starts from something sensible.
	# Values that already exist are never overwritten, so a player's own
	# settings survive being switched back to the defaults for a while.
	for my $name ( Plugins::AlbumMix::Plugin::playerPrefNames() ) {
		$cp->set($name, $prefs->get($name)) unless defined $cp->get($name);
	}

	my $played = $hp->get('played_albums') || {};
	$params->{played_count}  = scalar keys %$played;
	$params->{history_scope} = $prefs->get('history_scope') // 'shared';
	$params->{is_synced_slave} = ($client->can('isSynced') && $client->isSynced
		&& $client->can('master') && $client->master != $client) ? 1 : 0;

	my $result = $class->SUPER::handler($client, $params);

	# An unticked checkbox isn't sent by the browser; store it as 0 so it
	# reads as "off" rather than "not set" (which would mean the default)
	if ( $params->{saveSettings} ) {
		for my $name ( Plugins::AlbumMix::Plugin::playerBoolPrefNames() ) {
			$cp->set($name, 0) unless $params->{"pref_$name"};
		}
	}

	return $result;
}

1;
