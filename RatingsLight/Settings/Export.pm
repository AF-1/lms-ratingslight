package Plugins::RatingsLight::Settings::Export;

use strict;
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
	return ($prefs, qw(onlyratingnotmatchcommenttag exportextension));
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
	if($paramRef->{'export'}) {
		if($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::RatingsLight::Plugin::exportRatingsToPlaylistFiles();
	}elsif($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
	}

	# push to settings page

	$paramRef->{exportbasefilepathmatrix} = [];

	my $exportbasefilepathmatrix = $prefs->get('exportbasefilepathmatrix');
	my $exportbasefilepath;

	foreach $exportbasefilepath (@$exportbasefilepathmatrix) {
		if ($exportbasefilepath->{'lmsbasepath'}) {
			push( @{$paramRef->{exportbasefilepathmatrix}}, $exportbasefilepath);
		}
	}

	# add empty field (max = 11)
	if ((scalar @$exportbasefilepathmatrix + 1) < 10) {
		push(@{$paramRef->{exportbasefilepathmatrix}}, {lmsbasepath => '', substitutebasepath => ''});
	}

	$result = $class->SUPER::handler($client, $paramRef);

	return $result;
}

sub trim {
	my ($str) = @_;
	$str =~ s{^\s+}{};
	$str =~ s{\s+$}{};
	return $str;
}

1;
