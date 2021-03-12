package Plugins::RatingsLight::Settings::DSTM;

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
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RATINGSLIGHT_SETTINGS_DSTM');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/RatingsLight/settings/dstm.html');
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
	return ($prefs, qw(dstm_minTrackDuration dstm_percentagerated dstm_percentageratedhigh num_seedtracks));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $callHandler = 1;
	if ($paramRef->{'saveSettings'}) {

		my $excludegenres_namelist;
		my $genres = getGenres();

		# %$paramRef will contain a key called genre_<genre id> for each ticked checkbox on the page
		for my $genre (keys %{$genres}) {
			if ($paramRef->{'genre_'.$genres->{$genre}->{'id'}}) {
				push (@$excludegenres_namelist, $genre);
			}
		}
		$log->debug("*** SAVED *** excludegenres_namelist = ".Dumper($excludegenres_namelist));
		$prefs->set('excludegenres_namelist', $excludegenres_namelist);

		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	}elsif($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
	}

	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;

	my $genrelist = getGenres();
	$log->debug("genrelist (all genres) = ".Dumper($genrelist));
	$paramRef->{'genrelist'} = $genrelist;

	my $genrelistsorted = [getSortedGenres()];
	$log->debug("genrelistsorted (just names) = ".Dumper($genrelistsorted));
	$paramRef->{'genrelistsorted'} = $genrelistsorted;
}

sub getGenres {
	my $genres = {};
	my $query = ['genres', 0, 999_999];

	my $request = Slim::Control::Request::executeRequest(undef, $query);

	my $excludenamelist = $prefs->get('excludegenres_namelist');
	# Extract each genre name into a hash
	my %exclude;
	if (defined $excludenamelist) {
		%exclude = map { $_ => 1 } @$excludenamelist;
	}

	my $i = 0;
	foreach my $genre ( @{ $request->getResult('genres_loop') || [] } ) {
		my $name = $genre->{genre};
		$genres->{$name} = {
			'name' => $name,
			'id' => $genre->{id},
			'chosen' => $exclude{$name} ? 'yes' : '',
			'sort' => $i++,
		};
	}
	return $genres;
}

sub getSortedGenres {
	my $genres = getGenres();
	return sort {
		$genres->{$a}->{sort} <=> $genres->{$b}->{sort};
	} keys %$genres;
}

1;
