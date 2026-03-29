#
# Ratings Light
# (c) 2020 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::RatingsLight::Settings::Menus;

use strict;
use warnings;
use utf8;

use base qw(Plugins::RatingsLight::Settings::BaseSettings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string cstring);

my $prefs = preferences('plugin.ratingslight');
my $log = logger('plugin.ratingslight');

my $plugin;

sub new {
	my $class = shift;
	$plugin = shift;
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
	return ($prefs, qw(displayratingchar usehalfstarratings showratedtracksmenus browsemenus_artists browsemenus_genres browsemenus_tracks browsemenus_sourceVL_id ratingcontextmenupos displayratinghistory ratedtracksweblimit ratedtrackscontextmenulimit));
}

sub beforeRender {
	my ($class, $paramRef) = @_;

	my @items;
	my $libraries = Slim::Music::VirtualLibraries->getLibraries();
	main::DEBUGLOG && $log->is_debug && $log->debug("Menu Settings - ALL libraries: ".Data::Dump::dump($libraries));

	my $currentLibrary = $prefs->get('browsemenus_sourceVL_id');
	main::DEBUGLOG && $log->is_debug && $log->debug("current browsemenus_sourceVL_id = ".Data::Dump::dump($currentLibrary));

	for my $k (keys %{$libraries}) {
		my $count = Slim::Music::VirtualLibraries->getTrackCount($k);
		my $name = $libraries->{$k}->{'name'};
		my $displayName = Slim::Utils::Unicode::utf8decode($name, 'utf8').' ('.Slim::Utils::Misc::delimitThousands($count).($count == 1 ? ' '.string("PLUGIN_RATINGSLIGHT_LANGSTRING_TRACK") : ' '.string("PLUGIN_RATINGSLIGHT_LANGSTRING_TRACKS")).')';

		my $VLID = $libraries->{$k}->{'id'};
		main::DEBUGLOG && $log->is_debug && $log->debug("VL: ".$displayName." - VLID:".$VLID);
		unless ($VLID =~ /^RATINGSLIGHT_/) {
			push @items, {
				name => $displayName,
				sortName => Slim::Utils::Unicode::utf8decode($name, 'utf8'),
				library_id => $k,
			};
		}
	}
	@items = sort { $a->{sortName} cmp $b->{sortName} } @items;
	unshift @items, {
		name => string("PLUGIN_RATINGSLIGHT_LANGSTRING_COMPLETELIB"),
		sortName => "Complete Library",
		library_id => undef,
	};
	main::DEBUGLOG && $log->is_debug && $log->debug("libraries for settings page: ".Data::Dump::dump(\@items));
	$paramRef->{virtuallibraries} = \@items;
}

1;
