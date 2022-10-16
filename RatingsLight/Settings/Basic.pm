#
# Ratings Light
#
# (c) 2020-2022 AF-1
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

package Plugins::RatingsLight::Settings::Basic;

use strict;
use warnings;
use utf8;

use base qw(Plugins::RatingsLight::Settings::BaseSettings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;

my $prefs = preferences('plugin.ratingslight');
my $log = logger('plugin.ratingslight');

my $plugin;

sub new {
	my $class = shift;
	$plugin = shift;
	$class->SUPER::new($plugin,1);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RATINGSLIGHT');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/RatingsLight/settings/basic.html');
}

sub currentPage {
	return Slim::Utils::Strings::string('PLUGIN_RATINGSLIGHT_SETTINGS_VARIOUS');
}

sub pages {
	my %page = (
		'name' => Slim::Utils::Strings::string('PLUGIN_RATINGSLIGHT_SETTINGS_VARIOUS'),
		'page' => page(),
	);
	my @pages = (\%page);
	return \@pages;
}

sub prefs {
	return ($prefs, qw(enableIRremotebuttons topratedminrating rlparentfolderpath uselogfile userecentlyaddedplaylist recentlymaxcount postscanscheduledelay));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $callHandler = 1;
	if ($paramRef->{'saveSettings'}) {
		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	}
	if ($paramRef->{'clearallratingsnow'}) {
		if ($callHandler) {
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::RatingsLight::Plugin::clearAllRatings();
	} elsif ($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
	}
	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	my $advMode = $prefs->get('advmode');
	$paramRef->{'advmode'} = 1 if $advMode;
}

1;
