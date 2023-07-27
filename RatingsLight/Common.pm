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

package Plugins::RatingsLight::Common;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Schema;
use Slim::Utils::DateTime;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Text;
use File::Basename;
use File::Copy qw(move);
use File::Spec::Functions qw(:ALL);
use File::stat;
use FindBin qw($Bin);
use POSIX qw(strftime);
use Time::HiRes qw(time);
use Path::Class;

use base 'Exporter';
our %EXPORT_TAGS = (
	all => [qw(commit rollback createBackup cleanupBackups importRatingsFromCommentsTags importRatingsFromBPMTags isTimeOrEmpty getMusicDirs parse_duration pathForItem)],
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{all} } );

my $log = logger('plugin.ratingslight');
my $prefs = preferences('plugin.ratingslight');
my $serverPrefs = preferences('server');

sub createBackup {
	my $status_creatingbackup = $prefs->get('status_creatingbackup');
	if ($status_creatingbackup == 1) {
		$log->warn('A backup is already in progress, please wait for the previous backup to finish');
		return;
	}
	$prefs->set('status_creatingbackup', 1);

	my $backupDir = $prefs->get('rlfolderpath');
	my ($sql, $sth) = undef;
	my $dbh = Slim::Schema->dbh;
	my ($trackURL, $trackURLmd5, $trackRating, $trackRemote, $trackExtid);
	my $started = time();
	my $backuptimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;
	my $filename_timestamp = strftime "%Y%m%d-%H%M", localtime time;

	$sql = "select tracks.url, tracks.urlmd5, tracks_persistent.rating, tracks.remote, tracks.extid from tracks_persistent join tracks on tracks.urlmd5 = tracks_persistent.urlmd5 where tracks_persistent.rating > 0";
	$sth = $dbh->prepare($sql);
	$sth->execute();

	$sth->bind_col(1,\$trackURL);
	$sth->bind_col(2,\$trackURLmd5);
	$sth->bind_col(3,\$trackRating);
	$sth->bind_col(4,\$trackRemote);
	$sth->bind_col(5,\$trackExtid);

	my @ratedTracks = ();
	while ($sth->fetch()) {
		push (@ratedTracks, {'url' => $trackURL, 'urlmd5' => $trackURLmd5, 'rating' => $trackRating, 'remote' => $trackRemote, 'extid' => $trackExtid});
	}
	$sth->finish();

	if (@ratedTracks) {
		my $filename = catfile($backupDir, 'RL_Backup_'.$filename_timestamp.'.xml');
		my $output = FileHandle->new($filename, '>:utf8') or do {
			$log->error('Could not open '.$filename.' for writing. Does the RatingsLight folder exist? Does LMS have read/write permissions (755) for the (parent) folder?');
			$prefs->set('status_creatingbackup', 0);
			return;
		};
		my $trackcount = scalar(@ratedTracks);
		my $ignoredtracks = 0;
		main::DEBUGLOG && $log->is_debug && $log->debug('Found '.$trackcount.($trackcount == 1 ? ' rated track' : ' rated tracks').' in the LMS persistent database');

		print $output "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n";
		print $output "<!-- Backup of Rating Values -->\n";
		print $output "<!-- ".$backuptimestamp." -->\n";
		print $output "<RatingsLight>\n";
		for my $ratedTrack (@ratedTracks) {
			my $BACKUPtrackURL = $ratedTrack->{'url'};
			my $urlmd5 = $ratedTrack->{'urlmd5'};
			if (($ratedTrack->{'remote'} == 1) && (!defined($ratedTrack->{'extid'}))) {
				$log->warn('Warning: ignoring this track. Track is remote but not part of LMS library: '.$BACKUPtrackURL);
				$trackcount--;
				$ignoredtracks++;
				next;
			}
			my $rating100ScaleValue = $ratedTrack->{'rating'};
			my $remote = $ratedTrack->{'remote'};
			my $BACKUPrelFilePath = getRelFilePath($BACKUPtrackURL);
			$BACKUPtrackURL = escape($BACKUPtrackURL);
			$BACKUPrelFilePath = escape($BACKUPrelFilePath);
			print $output "\t<track>\n\t\t<url>".$BACKUPtrackURL."</url>\n\t\t<urlmd5>".$urlmd5."</urlmd5>\n\t\t<relurl>".$BACKUPrelFilePath."</relurl>\n\t\t<rating>".$rating100ScaleValue."</rating>\n\t\t<remote>".$remote."</remote>\n\t</track>\n";
		}
		print $output "</RatingsLight>\n";

		if ($ignoredtracks > 0) {
			print $output "<!-- WARNING: ".$ignoredtracks.($ignoredtracks == 1 ? " track was" : " tracks were")." ignored. Check server.log for more information. -->\n";
		}
		print $output "<!-- This backup contains ".$trackcount.($trackcount == 1 ? " rated track" : " rated tracks")." -->\n";
		close $output;
		main::DEBUGLOG && $log->is_debug && $log->debug('Backup completed after '.(time() - $started).' seconds.');

		cleanupBackups();
	} else {
		main::INFOLOG && $log->is_info && $log->info('Found no rated tracks in the LMS database.');
	}
	$prefs->set('status_creatingbackup', 0);
}

sub cleanupBackups {
	my $autodeletebackups = $prefs->get('autodeletebackups');
	my $backupFilesMin = $prefs->get('backupfilesmin');
	if (defined $autodeletebackups) {
		my $backupDir = $prefs->get('rlfolderpath');
		return unless (-d $backupDir);
		my $backupsdaystokeep = $prefs->get('backupsdaystokeep');
		my $maxkeeptime = $backupsdaystokeep * 24 * 60 * 60; # in seconds
		my @files;
		opendir(my $DH, $backupDir) or die "Error opening $backupDir: $!";
		@files = grep(/^RL_Backup_.*$/, readdir($DH));
		closedir($DH);
		main::DEBUGLOG && $log->is_debug && $log->debug('number of backup files found: '.scalar(@files));
		my $mtime;
		my $etime = int(time());
		my $n = 0;
		if (scalar(@files) > $backupFilesMin) {
			foreach my $file (@files) {
				my $filepath = catfile($backupDir, $file);
				$mtime = stat($filepath)->mtime;
				if (($etime - $mtime) > $maxkeeptime) {
					unlink($filepath) or die "Can't delete $file: $!";
					$n++;
					last if ((scalar(@files) - $n) <= $backupFilesMin);
				}
			}
		} else {
			main::DEBUGLOG && $log->is_debug && $log->debug('Not deleting any backups. Number of backup files to keep ('.$backupFilesMin.') '.((scalar(@files) - $n) == $backupFilesMin ? '=' : '>').' backup files found ('.scalar(@files).').');
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('Deleted '.$n.($n == 1 ? ' backup. ' : ' backups. ').(scalar(@files) - $n).((scalar(@files) - $n) == 1 ? " backup" : " backups")." remaining.");
	}
}

sub importRatingsFromCommentsTags {
	main::DEBUGLOG && $log->is_debug && $log->debug('starting ratings import from comments tags');
	my $class = shift;
	if ($prefs->get('status_importingfromcommentstags') == 1) {
		$log->warn('Import is already in progress, please wait for the previous import to finish');
		return;
	}
	$prefs->set('status_importingfromcommentstags', 1);
	my $started = time();

	my $rating_keyword_prefix = $prefs->get('rating_keyword_prefix');
	my $rating_keyword_suffix = $prefs->get('rating_keyword_suffix');
	my $tagimport_dontunrate = $prefs->get('tagimport_dontunrate');

	my $dbh = Slim::Schema->dbh;
	if ((!defined $rating_keyword_prefix || $rating_keyword_prefix eq '') && (!defined $rating_keyword_suffix || $rating_keyword_suffix eq '')) {
		$log->warn('Error: no rating keywords found.');
		$prefs->set('status_importingfromcommentstags', 0);
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

		# unrate previously rated tracks in LMS if comments tag does no longer contain keyword(s)
		if (!defined $tagimport_dontunrate) {
			my $ratingkeyword_unrate = "%%".$rating_keyword_prefix."_".$rating_keyword_suffix."%%";

			my $sth = $dbh->prepare($sqlunrate);
			eval {
				$sth->bind_param(1, $ratingkeyword_unrate);
				$sth->execute();
				commit($dbh);
			};
			if ($@) {
				$log->error("Database error: $DBI::errstr");
				eval {
					rollback($dbh);
				};
			}
			$sth->finish();
		}

		# rate tracks according to comments tag keyword
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
				$log->error("Database error: $DBI::errstr");
				eval {
					rollback($dbh);
				};
			}
			$rating++;
			$sth->finish();
		}
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('Import completed after '.(time() - $started).' seconds.');
	$prefs->set('status_importingfromcommentstags', 0);
}

sub importRatingsFromBPMTags {
	main::DEBUGLOG && $log->is_debug && $log->debug('starting ratings import from BPM tags');
	my $class = shift;
	if ($prefs->get('status_importingfromBPMtags') == 1) {
		$log->warn('Import is already in progress, please wait for the previous import to finish');
		return;
	}
	$prefs->set('status_importingfromBPMtags', 1);
	my $started = time();
	my $tagimport_dontunrate = $prefs->get('tagimport_dontunrate');

	my $dbh = Slim::Schema->dbh;
	my $sqlunrate = "update tracks_persistent
		set rating = null
		where (tracks_persistent.rating > 0
			and tracks_persistent.urlmd5 in (
				select tracks.urlmd5
				from tracks
				where tracks.audio == 1
				and (tracks.bpm == 0 or tracks.bpm is null))
			);";

	my $sqlrate = "update tracks_persistent
		set rating = ?
		where tracks_persistent.urlmd5 in (
			select tracks.urlmd5
				from tracks
				where tracks.audio == 1
				and tracks.bpm == ?
			);";

	# unrate previously rated tracks in LMS if BPM tag value is zero or null
	if (!defined $tagimport_dontunrate) {
		my $sth = $dbh->prepare($sqlunrate);
		eval {
			$sth->execute();
			commit($dbh);
		};
		if ($@) {
			$log->error("Database error: $DBI::errstr");
			eval {
				rollback($dbh);
			};
		}
		$sth->finish();
	}

	# rate tracks according to BPM value
	my $rating = 1;

	until ($rating > 10) {
		my $rating100scalevalue = ($rating * 10);
		my $sth = $dbh->prepare($sqlrate);
		eval {
			$sth->bind_param(1, $rating100scalevalue);
			$sth->bind_param(2, $rating100scalevalue);
			$sth->execute();
			commit($dbh);
		};
		if ($@) {
			$log->error("Database error: $DBI::errstr");
			eval {
				rollback($dbh);
			};
		}
		$rating++;
		$sth->finish();
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('Import completed after '.(time() - $started).' seconds.');
	$prefs->set('status_importingfromBPMtags', 0);
}

sub getRelFilePath {
	main::DEBUGLOG && $log->is_debug && $log->debug('Getting relative file url/path.');
	my $fullTrackURL = shift;
	my $relFilePath;
	my $lmsmusicdirs = getMusicDirs();
	main::DEBUGLOG && $log->is_debug && $log->debug('Valid LMS music dirs = '.Data::Dump::dump($lmsmusicdirs));

	foreach (@{$lmsmusicdirs}) {
		my $dirSep = File::Spec->canonpath("/");
		my $mediaDirPath = $_.$dirSep;
		my $fullTrackPath = Slim::Utils::Misc::pathFromFileURL($fullTrackURL);
		my $match = checkInFolder($fullTrackPath, $mediaDirPath);

		main::DEBUGLOG && $log->is_debug && $log->debug("Full file path \"$fullTrackPath\" is".($match == 1 ? "" : " NOT")." part of media dir \"".$mediaDirPath."\"");
		if ($match == 1) {
			$relFilePath = file($fullTrackPath)->relative($_);
			$relFilePath = Slim::Utils::Misc::fileURLFromPath($relFilePath);
			$relFilePath =~ s/^(file:)?\/+//isg;
			main::DEBUGLOG && $log->is_debug && $log->debug('Saving RELATIVE file path: '.$relFilePath);
			last;
		}
	}
	if (!$relFilePath) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Couldn't get relative file path for \"$fullTrackURL\".");
	}
	return $relFilePath;
}

sub checkInFolder {
	my $path = shift || return;
	my $checkdir = shift;

	$path = Slim::Utils::Misc::fixPath($path) || return 0;
	$path = Slim::Utils::Misc::pathFromFileURL($path) || return 0;
	main::DEBUGLOG && $log->is_debug && $log->debug('path = '.$path.' -- checkdir = '.$checkdir);

	if ($checkdir && $path =~ /^\Q$checkdir\E/) {
		return 1;
	} else {
		return 0;
	}
}

sub getMusicDirs {
	my $mediadirs = $serverPrefs->get('mediadirs');
	my $ignoreInAudioScan = $serverPrefs->get('ignoreInAudioScan');
	my $lmsmusicdirs = [];
	my %musicdircount;
	my $thisdir;
	foreach $thisdir (@{$mediadirs}, @{$ignoreInAudioScan}) {$musicdircount{$thisdir}++}
	foreach $thisdir (keys %musicdircount) {
		if ($musicdircount{$thisdir} == 1) {
			push (@{$lmsmusicdirs}, $thisdir);
		}
	}
	return $lmsmusicdirs;
}

sub parse_duration {
	use integer;
	sprintf("%02dh:%02dm", $_[0]/3600, $_[0]/60%60);
}

sub isTimeOrEmpty {
	my $name = shift;
	my $arg = shift;
	if (!$arg || $arg eq '') {
		return 1;
	} elsif ($arg =~ m/^([0\s]?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$/isg) {
		return 1;
	}
	return 0;
}

sub pathForItem {
	my $item = shift;
	if (Slim::Music::Info::isFileURL($item) && !Slim::Music::Info::isFragment($item)) {
		my $path = Slim::Utils::Misc::fixPath($item) || return 0;
		return Slim::Utils::Misc::pathFromFileURL($path);
	}
	return $item;
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

*escape = \&URI::Escape::uri_escape_utf8;

1;
