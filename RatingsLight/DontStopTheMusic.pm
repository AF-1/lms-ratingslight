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

package Plugins::RatingsLight::DontStopTheMusic;

use strict;
use warnings;
use utf8;

use Data::Dumper;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Schema;

use Plugins::RatingsLight::Common ':all';
use Plugins::RatingsLight::Plugin;
use Slim::Plugin::DontStopTheMusic::Plugin;

my $log = logger('plugin.ratingslight');
my $prefs = preferences('plugin.ratingslight');


sub init {
	Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_RATED', sub {
		dontStopTheMusic('rated', @_);
	});
	Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_TOPRATED', sub {
		dontStopTheMusic('rated_toprated', @_);
	});
	Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_RATED_GENRE', sub {
		dontStopTheMusic('rated_genre', @_);
	});
	Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_RATED_GENRE_TOPRATED', sub {
		dontStopTheMusic('rated_genre_toprated', @_);
	});
	Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_UNRATED_RATED', sub {
		dontStopTheMusic('unrated_rated', @_);
	});
	Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_UNRATED_RATED_GENRE', sub {
		dontStopTheMusic('unrated_rated_genre', @_);
	});
	Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_UNRATED_RATED_UNPLAYED', sub {
		dontStopTheMusic('unrated_rated_unplayed', @_);
	});
	Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_RATINGSLIGHT_DSTM_UNRATED_RATED_UNPLAYED_GENRE', sub {
		dontStopTheMusic('unrated_rated_unplayed_genre', @_);
	});
}

sub dontStopTheMusic {
	my ($mixtype, $client, $cb) = @_;
	return unless $client;
	$log->debug('DSTM mixtype = '.$mixtype);

	my $topratedminrating = $prefs->get('topratedminrating');
	my $tracks = [];
	my $dstm_batchsizenewtracks = $prefs->get('dstm_batchsizenewtracks');
	my $excludedgenrelist = getExcludedGenreList();
	$log->debug('excludedgenrelist = '.$excludedgenrelist);
	my $dstm_minTrackDuration = $prefs->get('dstm_minTrackDuration');
	my $dstm_percentagerated = $prefs->get('dstm_percentagerated');
	my $dstm_percentagetoprated = $prefs->get('dstm_percentagetoprated');
	my $currentLibrary = Slim::Music::VirtualLibraries->getLibraryIdForClient($client);
	$log->debug('current client VlibID = '.$currentLibrary);

	my $sqlstatement;

	### shared sql
	# track min duration, library view
	my $shared_curlib_sql = " join library_track on library_track.track = tracks.id and library_track.library = \"$currentLibrary\" where audio=1 and tracks.secs >= $dstm_minTrackDuration";
	# track min duration
	my $shared_completelib_sql = " where audio=1 and tracks.secs >= $dstm_minTrackDuration";
	# excluded genres
	my $excludegenre_sql = " and not exists (select * from tracks t2,genre_track,genres where t2.id=tracks.id and tracks.id=genre_track.track and genre_track.genre=genres.id and genres.name in ($excludedgenrelist))";

	### Mix sql
	# Mix: Rated
	if ($mixtype eq 'rated') {
		$sqlstatement = "select tracks.url from tracks join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $dstm_batchsizenewtracks;";
	}

	# Mix: "Rated (with % of top rated)"
	if ($mixtype eq 'rated_toprated') {
		$sqlstatement = "drop table if exists randomweightedratingshigh;
drop table if exists randomweightedratingslow;
drop table if exists randomweightedratingscombined;
";
		$sqlstatement .="create temporary table randomweightedratingslow as select tracks.url as url from tracks join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating < $topratedminrating";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$dstm_percentagetoprated);
";

		$sqlstatement .= "create temporary table randomweightedratingshigh as select tracks.url as url from tracks join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating >= $topratedminrating";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $dstm_percentagetoprated;
";
		$sqlstatement .= "create temporary table randomweightedratingscombined as select * from randomweightedratingslow union select * from randomweightedratingshigh;
select * from randomweightedratingscombined order by random() limit $dstm_batchsizenewtracks;
drop table randomweightedratingshigh;
drop table randomweightedratingslow;
drop table randomweightedratingscombined;";
	}

	# Mix: "Rated (seed genres)"
	if ($mixtype eq 'rated_genre') {
		my $dstm_includegenres = getSeedGenres($client);
		$sqlstatement = "select tracks.url from tracks join genre_track on genre_track.track=tracks.id and genre_track.genre in ($dstm_includegenres) join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $dstm_batchsizenewtracks;";
	}

	# Mix: "Rated (seed genres with % of top rated)"
	if ($mixtype eq 'rated_genre_toprated') {
		my $dstm_includegenres = getSeedGenres($client);
		$sqlstatement = "drop table if exists randomweightedratingshigh;
drop table if exists randomweightedratingslow;
drop table if exists randomweightedratingscombined;
create temporary table randomweightedratingslow as select tracks.url as url from tracks join genre_track on genre_track.track=tracks.id and genre_track.genre in ($dstm_includegenres) join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating < $topratedminrating";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$dstm_percentagetoprated);
";
		$sqlstatement .="create temporary table randomweightedratingshigh as select tracks.url as url from tracks join genre_track on genre_track.track=tracks.id and genre_track.genre in ($dstm_includegenres) join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating >= $topratedminrating";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $dstm_percentagetoprated;
";
		$sqlstatement .= "create temporary table randomweightedratingscombined as select * from randomweightedratingslow union select * from randomweightedratingshigh;
select * from randomweightedratingscombined order by random() limit $dstm_batchsizenewtracks;
drop table randomweightedratingshigh;
drop table randomweightedratingslow;
drop table randomweightedratingscombined;";
	}

	# Mix: "Unrated (with % of rated songs)"
	if ($mixtype eq 'unrated_rated') {
		$sqlstatement = "drop table if exists randomweightedratingsrated;
drop table if exists randomweightedratingsunrated;
drop table if exists randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and (tracks_persistent.rating = 0 or tracks_persistent.rating is null)";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$dstm_percentagerated);
";

		$sqlstatement .= "create temporary table randomweightedratingsrated as select tracks.url as url from tracks join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $dstm_percentagerated;
";
		$sqlstatement .= "create temporary table randomweightedratingscombined as select * from randomweightedratingsunrated union select * from randomweightedratingsrated;
select * from randomweightedratingscombined order by random() limit $dstm_batchsizenewtracks;
drop table randomweightedratingsrated;
drop table randomweightedratingsunrated;
drop table randomweightedratingscombined;";
	}

	# Mix: "Unrated (seed genres with % of rated songs)"
	if ($mixtype eq 'unrated_rated_genre') {
		my $dstm_includegenres = getSeedGenres($client);
		$sqlstatement = "drop table if exists randomweightedratingsrated;
drop table if exists randomweightedratingsunrated;
drop table if exists randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join genre_track on genre_track.track=tracks.id and genre_track.genre in ($dstm_includegenres) join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and (tracks_persistent.rating = 0 or tracks_persistent.rating is null)";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$dstm_percentagerated);
";

		$sqlstatement .= "create temporary table randomweightedratingsrated as select tracks.url as url from tracks join genre_track on genre_track.track=tracks.id and genre_track.genre in ($dstm_includegenres) join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $dstm_percentagerated;
";
		$sqlstatement .= "create temporary table randomweightedratingscombined as select * from randomweightedratingsunrated union select * from randomweightedratingsrated;
select * from randomweightedratingscombined order by random() limit $dstm_batchsizenewtracks;
drop table randomweightedratingsrated;
drop table randomweightedratingsunrated;
drop table randomweightedratingscombined;";
	}

	# Mix: "Unrated (unplayed, with % of rated songs)"
	if ($mixtype eq 'unrated_rated_unplayed') {
		$sqlstatement = "drop table if exists randomweightedratingsrated;
drop table if exists randomweightedratingsunrated;
drop table if exists randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and (tracks_persistent.rating = 0 or tracks_persistent.rating is null) and (tracks_persistent.playCount = 0 or tracks_persistent.playCount is null)";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$dstm_percentagerated);
";

		$sqlstatement .= "create temporary table randomweightedratingsrated as select tracks.url as url from tracks join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 and (tracks_persistent.playCount = 0 or tracks_persistent.playCount is null)";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $dstm_percentagerated;
";
		$sqlstatement .= "create temporary table randomweightedratingscombined as select * from randomweightedratingsunrated union select * from randomweightedratingsrated;
select * from randomweightedratingscombined order by random() limit $dstm_batchsizenewtracks;
drop table randomweightedratingsrated;
drop table randomweightedratingsunrated;
drop table randomweightedratingscombined;";
	}

	# Mix: "Unrated (unplayed, seed genres with % of rated songs)"
	if ($mixtype eq 'unrated_rated_unplayed_genre') {
		my $dstm_includegenres = getSeedGenres($client);
		$sqlstatement = "drop table if exists randomweightedratingsrated;
drop table if exists randomweightedratingsunrated;
drop table if exists randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join genre_track on genre_track.track=tracks.id and genre_track.genre in ($dstm_includegenres) join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and (tracks_persistent.rating = 0 or tracks_persistent.rating is null) and (tracks_persistent.playCount = 0 or tracks_persistent.playCount is null)";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit (100-$dstm_percentagerated);
";

		$sqlstatement .= "create temporary table randomweightedratingsrated as select tracks.url as url from tracks join genre_track on genre_track.track=tracks.id and genre_track.genre in ($dstm_includegenres) join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 and (tracks_persistent.playCount = 0 or tracks_persistent.playCount is null)";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= $shared_curlib_sql;
		} else {
			$sqlstatement .= $shared_completelib_sql;
		}
		if ($excludedgenrelist ne '') {
			$sqlstatement .= $excludegenre_sql;
		}
		$sqlstatement .= " group by tracks.id order by random() limit $dstm_percentagerated;
";
		$sqlstatement .= "create temporary table randomweightedratingscombined as select * from randomweightedratingsunrated union select * from randomweightedratingsrated;
select * from randomweightedratingscombined order by random() limit $dstm_batchsizenewtracks;
drop table randomweightedratingsrated;
drop table randomweightedratingsunrated;
drop table randomweightedratingscombined;";
	}

	my $dbh = getCurrentDBH();
	for my $sql (split(/[\n\r]/,$sqlstatement)) {
		eval {
			my $sth = $dbh->prepare($sql);
			$sth->execute() or do {
				$sql = undef;
			};
			if ($sql =~ /^\(*select+/oi) {
				my $trackURL;
				$sth->bind_col(1,\$trackURL);

				while ($sth->fetch()) {
					my $track = Slim::Schema->resultset('Track')->objectForUrl($trackURL);
					push @{$tracks}, $track;
				}
			}
			$sth->finish();
		};
	}
	my $tracksfound = scalar @{$tracks} || 0;
	$log->debug('RL DSTM - tracks found/used: '.$tracksfound);
	# Prune previously played playlist tracks
	my $songIndex = Slim::Player::Source::streamingSongIndex($client);
	my $dstm_playedtrackstokeep = $prefs->get('dstm_playedtrackstokeep');
	if ($songIndex) {
		for (my $i = 0; $i < $songIndex - $dstm_playedtrackstokeep; $i++) {
			my $request = $client->execute(['playlist', 'delete', 0]);
			$request->source('PLUGIN_RATINGSLIGHT');
		}
	}

	$cb->($client, $tracks);
}

sub getSeedGenres {
	my $client = shift;
	my $dstm_num_seedtracks = $prefs->get('dstm_num_seedtracks');
	my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, $dstm_num_seedtracks);

	if ($seedTracks && ref $seedTracks && scalar @{$seedTracks}) {
		my @seedIDs = ();
		my @seedsToUse = ();
		foreach my $seedTrack (@{$seedTracks}) {
			my ($trackObj) = Slim::Schema->find('Track', $seedTrack->{id});
			if ($trackObj) {
				push @seedsToUse, $trackObj;
				push @seedIDs, $seedTrack->{id};
			}
		}

		if (scalar @seedsToUse > 0) {
			my $genrelist;
			foreach my $thisID (@seedIDs) {
				my $track = Slim::Schema->resultset('Track')->find($thisID);
				my $thisgenreid = $track->genre->id;
				$log->debug('seed genrename = '.$track->genre->name.' -- genre ID: '.$thisgenreid);
				push @{$genrelist},$thisgenreid;
			}
			my @filteredgenrelist = sort (uniq(@{$genrelist}));
			my $includedgenrelist = join (',', @filteredgenrelist);
			return $includedgenrelist;
		}
	}
}

sub getExcludedGenreList {
	my $excludegenres_namelist = $prefs->get('excludegenres_namelist');
	my $excludedgenreString = '';
	if ((defined $excludegenres_namelist) && (scalar @{$excludegenres_namelist} > 0)) {
		$excludedgenreString = join ',', map qq/'$_'/, @{$excludegenres_namelist};
	}
	return $excludedgenreString;
}

sub uniq {
	my %seen;
	grep !$seen{$_}++, @_;
}

1;
