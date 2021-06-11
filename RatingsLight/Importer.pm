#
# Ratings Light
#
# (c) 2020-2021 AF-1
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

package Plugins::RatingsLight::Importer;

use strict;
use warnings;
use utf8;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Schema;

my $log = Slim::Utils::Log::logger('plugin.ratingslight');
my $prefs = preferences('plugin.ratingslight');
my $serverPrefs = preferences('server');

sub initPlugin {
	$log->debug("importer module init");
	toggleUseImporter();
}

sub toggleUseImporter {
	my $enableautoscan = $prefs->get('autoscan');
	if (defined $enableautoscan) {
		$log->debug("enabling importer");
		Slim::Music::Import->addImporter('Plugins::RatingsLight::Importer', {
			'type' => 'post',
			'weight' => 199,
			'use' => 1,
		});
	} else {
		$log->debug("disabling importer");
		Slim::Music::Import->useImporter('Plugins::RatingsLight::Importer',0);
	}
}

sub startScan {
	$log->debug("starting importer");
	importRatingsFromCommentTags();
	Slim::Music::Import->endImporter(__PACKAGE__);
}

sub importRatingsFromCommentTags {
	$log->debug("starting ratings import from comment tags");
	my $class = shift;
	my $status_importingfromcommenttags = $prefs->get('status_importingfromcommenttags');
	if ($status_importingfromcommenttags == 1) {
		$log->warn('Import is already in progress, please wait for the previous import to finish');
		return;
	}
	$prefs->set('status_importingfromcommenttags', 1);
	my $started = time();

	my $rating_keyword_prefix = $prefs->get('rating_keyword_prefix');
	my $rating_keyword_suffix = $prefs->get('rating_keyword_suffix');
	my $plimportct_dontunrate = $prefs->get('plimportct_dontunrate');

	my $dbh = getCurrentDBH();
	if ((!defined $rating_keyword_prefix || $rating_keyword_prefix eq '') && (!defined $rating_keyword_suffix || $rating_keyword_suffix eq '')) {
		$log->warn('Error: no rating keywords found.');
		$prefs->set('status_importingfromcommenttags', 0);
		return
	} else {
		my $sqlunrate = "UPDATE tracks_persistent
			SET rating = NULL
			WHERE (tracks_persistent.rating > 0
				AND tracks_persistent.urlmd5 IN (
					SELECT tracks.urlmd5
					FROM tracks
					LEFT JOIN comments ON comments.track = tracks.id
					WHERE (comments.value NOT LIKE ? OR comments.value IS NULL))
				);";

		my $sqlrate = "UPDATE tracks_persistent
			SET rating = ?
			WHERE tracks_persistent.urlmd5 IN (
				SELECT tracks.urlmd5
					FROM tracks
				JOIN comments ON comments.track = tracks.id
					WHERE comments.value LIKE ?
			);";

		if (!defined $plimportct_dontunrate) {
			# unrate previously rated tracks in LMS if comment tag does no longer contain keyword(s)
			my $ratingkeyword_unrate = "%%".$rating_keyword_prefix."_".$rating_keyword_suffix."%%";

			my $sth = $dbh->prepare($sqlunrate);
			eval {
				$sth->bind_param(1, $ratingkeyword_unrate);
				$sth->execute();
				commit($dbh);
			};
			if ($@) {
				$log->warn("Database error: $DBI::errstr");
				eval {
					rollback($dbh);
				};
			}
			$sth->finish();
		}

		# rate tracks according to comment tag keyword
		my $rating = 1;

		until ($rating > 5) {
			my $rating100scalevalue = ($rating * 20);
			my $ratingkeyword = "%%".$rating_keyword_prefix.$rating.$rating_keyword_suffix."%%";
			my $sth = $dbh->prepare($sqlrate);
			eval {
				$sth->bind_param(1, $rating100scalevalue);
				$sth->bind_param(2, $ratingkeyword);
				$sth->execute();
				commit($dbh);
			};
			if ($@) {
				$log->warn("Database error: $DBI::errstr");
				eval {
					rollback($dbh);
				};
			}
			$rating++;
			$sth->finish();
		}
	}

	my $ended = time() - $started;

	$log->debug('Import completed after '.$ended.' seconds.');
	$prefs->set('status_importingfromcommenttags', 0);
}

sub getCurrentDBH {
	return Slim::Schema->storage->dbh();
}

sub commit {
	my $dbh = shift;
	if (!$dbh->{'AutoCommit'}) {
		$dbh->commit();
	}
}

sub rollback {
	my $dbh = shift;
	if (!$dbh->{'AutoCommit'}) {
		$dbh->rollback();
	}
}

1;
