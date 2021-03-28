package Plugins::RatingsLight::Settings::Menus;

use strict;
use warnings;
use utf8;

use base qw(Plugins::RatingsLight::Settings::BaseSettings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;
use Slim::Utils::Strings qw(string cstring);
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
	return ($prefs, qw(ratingcontextmenudisplaymode ratingcontextmenusethalfstars showratedtracksmenus browsemenus_sourceVL_id moreratedtracksbyartistweblimit moreratedtracksbyartistcontextmenulimit));
}

sub handler {
	my ($class, $client, $paramRef) = @_;

	if ($paramRef->{'saveSettings'}) {

	}
	my $result = $class->SUPER::handler($client, $paramRef);
	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;

	my (@items, @hiddenVLs);
	my $libraries = Slim::Music::VirtualLibraries->getLibraries();
	$log->debug("Menu Settings - ALL libraries: ".Dumper($libraries));

	my $currentLibrary = $prefs->get('browsemenus_sourceVL_id');
	$log->debug("current browsemenus_sourceVL_id = ".Dumper($currentLibrary));

	my $localonlyname = Slim::Music::VirtualLibraries->getNameForId("localTracksOnly");
	my $preferlocalname = Slim::Music::VirtualLibraries->getNameForId("preferLocalLibraryOnly");

	if ((defined $localonlyname) && ($localonlyname ne '') && (defined $preferlocalname) && ($preferlocalname ne '')) {
		@hiddenVLs = ("Ratings Light - ", $preferlocalname, $localonlyname);
	} else {
		@hiddenVLs = ("Ratings Light - ");
	}
	$log->debug("hidden libraries: ".Dumper(\@hiddenVLs));

	sub regex {
		my ($VLname, @hiddenVLs) = @_;
		my $match = 0;
		my $re = join '|', map { quotemeta } @hiddenVLs;
		if ($VLname =~ /^($re)/) {
			$match = 1;
		}
		return $match;
	}

	while (my ($k, $v) = each %{$libraries}) {
		my $count = Slim::Utils::Misc::delimitThousands(Slim::Music::VirtualLibraries->getTrackCount($k));
		my $name = Slim::Music::VirtualLibraries->getNameForId($k);

		if (regex ($name, @hiddenVLs) != 1) {
			push @items, {
				name => $name." (".$count.($count == 1 ? " track)" : " tracks)"),
				sortName => $name,
				library_id => $k,
			};
		}
	}
	push @items, {
		name => "Complete Library (Default)",
		sortName => " Complete Library",
		library_id => undef,
	};
	@items = sort { $a->{sortName} cmp $b->{sortName} } @items;
	$log->debug("libraries for settings page: ".Dumper(\@items));
	$paramRef->{virtuallibraries} = \@items;
}

1;
