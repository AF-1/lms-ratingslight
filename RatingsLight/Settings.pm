package Plugins::RatingsLight::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.ratingslight');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RATINGSLIGHT');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/RatingsLight/html/settings.html');
}

sub prefs {
	return ($prefs, 'rating_keyword_prefix', 'rating_keyword_suffix', 'autoscan', 'onlyratingnotmatchcommenttag');
}


1;