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

package Plugins::RatingsLight::Settings::Export;

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
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RATINGSLIGHT_SETTINGS_EXPORT');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/RatingsLight/settings/export.html');
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
	return ($prefs, qw(onlyratingsnotmatchtags exportextension exportextensionexceptions exportVL_id));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $callHandler = 1;
	if ($paramRef->{'saveSettings'}) {
		my @exportbasefilepathmatrix;
		my %lmsbasepathDone;

		for (my $n = 0; $n <= 10; $n++) {
			my $lmsbasepath = trim($paramRef->{"pref_lmsbasepath_$n"} // '');
			my $substitutebasepath = trim($paramRef->{"pref_substitutebasepath_$n"} // '');

			if ((length($lmsbasepath) > 0) && !$lmsbasepathDone{$lmsbasepath} && (length($substitutebasepath) > 0)) {
				push(@exportbasefilepathmatrix, {lmsbasepath => $lmsbasepath, substitutebasepath => $substitutebasepath});
				$lmsbasepathDone{$lmsbasepath} = 1;
			}
		}
		$prefs->set('exportbasefilepathmatrix', \@exportbasefilepathmatrix);
		$paramRef->{exportbasefilepathmatrix} = \@exportbasefilepathmatrix;

		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	}
	if ($paramRef->{'export'}) {
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::RatingsLight::Plugin::exportRatingsToPlaylistFiles();
	} elsif ($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
	}

	# push to settings page
	$paramRef->{exportbasefilepathmatrix} = [];
	my $exportbasefilepathmatrix = $prefs->get('exportbasefilepathmatrix');

	if (scalar @{$exportbasefilepathmatrix} == 0) {
		Plugins::RatingsLight::Plugin::initExportBaseFilePathMatrix();
		$exportbasefilepathmatrix = $prefs->get('exportbasefilepathmatrix');
	}

	foreach my $exportbasefilepath (@{$exportbasefilepathmatrix}) {
		if ($exportbasefilepath->{'lmsbasepath'}) {
			push( @{$paramRef->{exportbasefilepathmatrix}}, $exportbasefilepath);
		}
	}

	# add empty field (max = 11)
	if ((scalar @{$exportbasefilepathmatrix} + 1) < 10) {
		push(@{$paramRef->{exportbasefilepathmatrix}}, {lmsbasepath => '', substitutebasepath => ''});
	}

	$result = $class->SUPER::handler($client, $paramRef);
	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;

	my @items;
	my $libraries = Slim::Music::VirtualLibraries->getLibraries();

	my %hiddenVLs = map {$_ => 1} ("Ratings Light - Rated Tracks", "Ratings Light - Top Rated Tracks");
	$log->debug("hidden libraries: ".Dumper(\%hiddenVLs));

	while (my ($k, $v) = each %{$libraries}) {
		my $count = Slim::Utils::Misc::delimitThousands(Slim::Music::VirtualLibraries->getTrackCount($k));
		my $name = Slim::Music::VirtualLibraries->getNameForId($k);
		$log->debug("VL: ".$name." (".$count.")");

		unless ($hiddenVLs{$name}) {
			push @items, {
				name => Slim::Utils::Unicode::utf8decode($name, 'utf8')." (".$count.($count eq '1' ? " ".string("PLUGIN_RATINGSLIGHT_LANGSTRING_TRACK").")" : " ".string("PLUGIN_RATINGSLIGHT_LANGSTRING_TRACKS").")"),
				sortName => Slim::Utils::Unicode::utf8decode($name, 'utf8'),
				library_id => $k,
			};
		}
	}
	push @items, {
		name => string("PLUGIN_RATINGSLIGHT_LANGSTRING_COMPLETELIB"),
		sortName => " Complete Library",
		library_id => undef,
	};
	@items = sort { $a->{sortName} cmp $b->{sortName} } @items;
	$paramRef->{virtuallibraries} = \@items;
	$paramRef->{curselfiletag} = $prefs->get('filetagtype');
}

sub trim {
	my ($str) = @_;
	$str =~ s{^\s+}{};
	$str =~ s{\s+$}{};
	return $str;
}

1;
