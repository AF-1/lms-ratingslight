package Plugins::RatingsLight::Settings::Menus;

use strict;
use base qw(Plugins::RatingsLight::Settings::BaseSettings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;

my $prefs = preferences('plugin.ratingslight');
my $log   = logger('plugin.ratingslight');

my $plugin;

sub new {
	my $class = shift;
	$plugin   = shift;

	$class->SUPER::new($plugin);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RATINGSLIGHT_SETTINGS_MENUS');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/RatingsLight/settings/menus.html');
}

sub currentPage {
	return name();
}

sub pages {
	my %page = (
		'name' => Slim::Utils::Strings::string('PLUGIN_RATINGSLIGHT_SETTINGS_MENUS'),
		'page' => page(),
	);
	my @pages = (\%page);
	return \@pages;
}

sub prefs {
	return ($prefs, qw(ratingcontextmenudisplaymode ratingcontextmenusethalfstars showratedtracksmenus autorebuildvirtualibraryafterrating moreratedtracksbyartistweblimit moreratedtracksbyartistcontextmenulimit));
}

sub handler {
	my ($class, $client, $paramRef) = @_;

	if ($paramRef->{'saveSettings'}) {
	}	
	my $result = $class->SUPER::handler($client, $paramRef);
	return $result;
}
		
1;
