package Plugins::RatingsLight::Settings::Import;

use strict;
use warnings;
use utf8;

use base qw(Plugins::RatingsLight::Settings::BaseSettings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;
use Data::Dumper;

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
	return ($prefs, qw(rating_keyword_prefix rating_keyword_suffix autoscan ratethisplaylistid ratethisplaylistrating));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $callHandler = 1;
	if ($paramRef->{'saveSettings'}) {
		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	}
	if($paramRef->{'manimport'}) {
		if($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		}
		$log->debug("rating keyword prefix = ".$paramRef->{'pref_rating_keyword_prefix'});
		$log->debug("rating keyword suffix = ".$paramRef->{'pref_rating_keyword_suffix'});
		if (((!defined ($paramRef->{'pref_rating_keyword_prefix'})) || ($paramRef->{'pref_rating_keyword_prefix'} eq '')) && ((!defined ($paramRef->{'pref_rating_keyword_suffix'})) || ($paramRef->{'pref_rating_keyword_suffix'} eq ''))) {
			$paramRef->{'missingkeywords'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		} else {
			Plugins::RatingsLight::Plugin::importRatingsFromCommentTags();
		}
	}elsif($paramRef->{'rateplaylistnow'}) {
		if($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::RatingsLight::Plugin::importRatingsFromPlaylist();
	}elsif($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
	}

	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	my @allplaylists = ();
	my $queryresult = Slim::Control::Request::executeRequest(undef, ['playlists', '0', '50']);
	my $playlistcount = $queryresult->getResult("count");

	if ($playlistcount > 0) {
		my $playlistarray = $queryresult->getResult("playlists_loop");
		my @sortedarray = sort {$a->{id} <=> $b->{id}} @{$playlistarray};
		$log->debug("sorted playlists = ".Dumper(\@sortedarray));
		$paramRef->{playlistcount} = $playlistcount;
		$paramRef->{allplaylists} = \@sortedarray;
	}
}

1;
