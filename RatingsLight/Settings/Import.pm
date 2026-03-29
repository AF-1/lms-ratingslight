#
# Ratings Light
# (c) 2020 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::RatingsLight::Settings::Import;

use strict;
use warnings;
use utf8;

use base qw(Plugins::RatingsLight::Settings::BaseSettings);
use Plugins::RatingsLight::Common ':all';

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;

my $prefs = preferences('plugin.ratingslight');
my $log = logger('plugin.ratingslight');

my $plugin;

sub new {
	my $class = shift;
	$plugin = shift;
	$class->SUPER::new($plugin);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RATINGSLIGHT_SETTINGS_IMPORT');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/RatingsLight/settings/import.html');
}

sub currentPage {
	return name();
}

sub pages {
	my %page = (
		'name' => name(),
		'page' => page(),
	);
	my @pages = (\%page);
	return \@pages;
}

sub prefs {
	return ($prefs, qw(rating_keyword_prefix rating_keyword_suffix autoscan ratethisplaylistid ratethisplaylistrating playlistimport_maxtracks filetagtype));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $callHandler = 1;
	if ($paramRef->{'saveSettings'}) {
		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	}
	if ($paramRef->{'manimport'}) {
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		}
		my $filetagtype = $prefs->get('filetagtype');
		if ($filetagtype == 1) {
			main::DEBUGLOG && $log->is_debug && $log->debug('rating keyword PREfix: '.Data::Dump::dump($paramRef->{'pref_rating_keyword_prefix'}).' ## rating keyword SUFfix: '.Data::Dump::dump($paramRef->{'pref_rating_keyword_suffix'}));
			if ((!defined($paramRef->{'pref_rating_keyword_prefix'}) || $paramRef->{'pref_rating_keyword_prefix'} eq '') && (!defined($paramRef->{'pref_rating_keyword_suffix'}) || $paramRef->{'pref_rating_keyword_suffix'} eq '')) {
				$paramRef->{'missingkeywords'} = 1;
				$result = $class->SUPER::handler($client, $paramRef);
			} else {
				importRatingsFromCommentTags();
				Plugins::RatingsLight::Plugin::setTaskTimer();
			}
		} elsif ($filetagtype == 0) {
			importRatingsFromBPMTags();
			Plugins::RatingsLight::Plugin::setTaskTimer();
		}
	} elsif ($paramRef->{'rateplaylistnow'}) {
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::RatingsLight::Plugin::importRatingsFromPlaylist();
	} elsif ($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
	}

	$result = $class->SUPER::handler($client, $paramRef);
	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	my @localPlaylists = ();
	my $queryresult = Slim::Control::Request::executeRequest(undef, ['playlists', '0', '500', 'tags:x']);
	return unless defined $queryresult;
	my $playlistarray = $queryresult->getResult("playlists_loop");
	return unless defined $playlistarray;

	foreach my $thisPlaylist (@{$playlistarray}) {
		push @localPlaylists, $thisPlaylist if $thisPlaylist->{'remote'} == 0;
	}

	if (scalar (@localPlaylists) > 0) {
		my @sortedarray = sort {$a->{id} <=> $b->{id}} @localPlaylists;
		main::DEBUGLOG && $log->is_debug && $log->debug("sorted playlists = ".Data::Dump::dump(\@sortedarray));
		$paramRef->{playlistcount} = scalar (@localPlaylists);
		$paramRef->{allplaylists} = \@sortedarray;
	}
}

1;
