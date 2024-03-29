#
# Ratings Light
#
# (c) 2020 AF
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

package Plugins::RatingsLight::Settings::DSTM;

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
	return ($prefs, qw(dstm_minTrackDuration dstm_percentagerated dstm_percentagetoprated dstm_num_seedtracks dstm_playedtrackstokeep dstm_batchsizenewtracks));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $callHandler = 1;
	if ($paramRef->{'saveSettings'}) {

		my $excludegenres_namelist;
		my $genres = getGenres();

		# %{$paramRef} will contain a key called genre_<genre id> for each ticked checkbox on the page
		for my $genre (keys %{$genres}) {
			if ($paramRef->{'genre_'.$genres->{$genre}->{'id'}}) {
				push (@{$excludegenres_namelist}, $genre);
			}
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('*** SAVED *** excludegenres_namelist = '.Data::Dump::dump($excludegenres_namelist));
		$prefs->set('excludegenres_namelist', $excludegenres_namelist);

		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	} elsif ($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
	}

	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;

	my $genrelist = getGenres();
	main::DEBUGLOG && $log->is_debug && $log->debug('genrelist (all genres) = '.Data::Dump::dump($genrelist));
	$paramRef->{'genrelist'} = $genrelist;

	my $genrelistsorted = [getSortedGenres()];
	main::DEBUGLOG && $log->is_debug && $log->debug('genrelistsorted (just names) = '.Data::Dump::dump($genrelistsorted));
	$paramRef->{'genrelistsorted'} = $genrelistsorted;
}

sub getGenres {
	my $genres = {};
	my $genreSQL = "select genres.id,genres.name,genres.namesearch from genres order by namesort asc";

	my $excludenamelist = $prefs->get('excludegenres_namelist');
	my %exclude;
	if (defined $excludenamelist) {
		%exclude = map { $_ => 1 } @{$excludenamelist}; # Extract each genre name into a hash
	}

	my $i = 0;
	my $sth = Slim::Schema->dbh->prepare($genreSQL);
	main::DEBUGLOG && $log->is_debug && $log->debug("Executing: $genreSQL");
	eval {
		$sth->execute() or do {
			$log->error("Error executing: $genreSQL");
			$genreSQL = undef;
		};

		my ($id, $name, $namesearch);
		$sth->bind_col(1, \$id);
		$sth->bind_col(2, \$name);
		$sth->bind_col(3, \$namesearch);
		while($sth->fetch()) {
			my %item = (
				'id' => Slim::Utils::Unicode::utf8decode($id, 'utf8'),
				'name' => Slim::Utils::Unicode::utf8decode($name, 'utf8'),
				'namesearch' => Slim::Utils::Unicode::utf8decode($namesearch, 'utf8'),
				'chosen' => $exclude{$namesearch} ? 'yes' : '',
				'sort' => $i++,
			);
			$genres->{$namesearch} = \%item;
		}
		$sth->finish();
	};
	if ($@) {
		$log->error("Database error: $DBI::errstr");
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('genre list before render = '.Data::Dump::dump($genres));
	return $genres;
}

sub getSortedGenres {
	my $genres = getGenres();
	return sort {
		$genres->{$a}->{sort} <=> $genres->{$b}->{sort};
	} keys %{$genres};
}

1;
