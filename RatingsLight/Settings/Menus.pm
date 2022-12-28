#
# Ratings Light
#
# (c) 2020 AF-1
#
# GPLv3 license
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#

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
	return ($prefs, qw(displayratingchar ratingcontextmenusethalfstars showratedtracksmenus browsemenus_sourceVL_id enableipengtslegacyrating ratedtracksweblimit ratedtrackscontextmenulimit));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	if ($paramRef->{'saveSettings'}) { }
	my $result = $class->SUPER::handler($client, $paramRef);
	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;

	my @items;
	my $libraries = Slim::Music::VirtualLibraries->getLibraries();
	$log->debug("Menu Settings - ALL libraries: ".Dumper($libraries));

	my $currentLibrary = $prefs->get('browsemenus_sourceVL_id');
	$log->debug("current browsemenus_sourceVL_id = ".Dumper($currentLibrary));

	while (my ($k, $v) = each %{$libraries}) {
		my $count = Slim::Utils::Misc::delimitThousands(Slim::Music::VirtualLibraries->getTrackCount($k)) + 0;
		my $name = $libraries->{$k}->{'name'};
		my $VLID = $libraries->{$k}->{'id'};
		$log->debug("VL: ".$name." (".$count.") - VLID:".$VLID);
		unless (starts_with($VLID, "RATINGSLIGHT_") == 0) {
			push @items, {
				name => Slim::Utils::Unicode::utf8decode($name, 'utf8').sprintf(" ($count %s)", $count == 1 ? string('PLUGIN_RATINGSLIGHT_LANGSTRING_TRACK') : string('PLUGIN_RATINGSLIGHT_LANGSTRING_TRACKS')),
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
	$log->debug("libraries for settings page: ".Dumper(\@items));
	$paramRef->{virtuallibraries} = \@items;
}

sub starts_with {
	# complete_string, start_string, position
	return rindex($_[0], $_[1], 0);
	# 0 for yes, -1 for no
}

1;
