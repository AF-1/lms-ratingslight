#
# Ratings Light
# (c) 2020 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::RatingsLight::Settings::Export;

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

sub new {
	my ($class, $plugin) = @_;
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
	return ($prefs, qw(playlistexportsinglefile playlistexportunrated onlyratingsnotmatchtags exporttimerange exportratingchange exportextension exportextensionexceptions exportVL_id));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result;
	my $callHandler = 1;
	if ($paramRef->{'saveSettings'}) {
		my @exportbasefilepathmatrix;
		my %lmsbasepathDone;

		for my $n (0..10) {
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

	# add empty field if fewer than 11 path pairs are shown
	if ((scalar @{$exportbasefilepathmatrix} + 1) < 11) {
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
	main::DEBUGLOG && $log->is_debug && $log->debug("hidden libraries: ".Data::Dump::dump(\%hiddenVLs));

	for my $k (keys %{$libraries}) {
		my $count = Slim::Music::VirtualLibraries->getTrackCount($k);
		my $name = Slim::Music::VirtualLibraries->getNameForId($k);
		my $displayName = Slim::Utils::Unicode::utf8decode($name, 'utf8').' ('.Slim::Utils::Misc::delimitThousands($count).($count == 1 ? ' '.string("PLUGIN_RATINGSLIGHT_LANGSTRING_TRACK") : ' '.string("PLUGIN_RATINGSLIGHT_LANGSTRING_TRACKS")).')';
		main::DEBUGLOG && $log->is_debug && $log->debug("VL: ".$displayName);

		unless ($hiddenVLs{$name}) {
			push @items, {
				name => $displayName,
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
	$paramRef->{lastsuccessfulexport} = Slim::Utils::DateTime::longDateF($prefs->get('lastexport')).", ".Slim::Utils::DateTime::timeF($prefs->get('lastexport')) if $prefs->get('lastexport');
}

sub trim {
	my $str = shift;
	$str =~ s{^\s+}{};
	$str =~ s{\s+$}{};
	return $str;
}

1;
