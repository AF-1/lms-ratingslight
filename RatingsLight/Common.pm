#
# Ratings Light
# (c) 2020 AF
# Licensed under the GPLv3 - see LICENSE file
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
use POSIX qw(strftime);
use Time::HiRes qw(time);
use Path::Class;
use FileHandle;

use base 'Exporter';
our %EXPORT_TAGS = (
	all => [qw(createBackup cleanupBackups importRatingsFromCommentTags importRatingsFromBPMTags isTimeOrEmpty getMusicDirs parse_duration pathForItem toIntTimestamp)],
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{all} } );

my $log = logger('plugin.ratingslight');
my $prefs = preferences('plugin.ratingslight');
my $serverPrefs = preferences('server');

my ($backupQueue, $backupOutput, $backupStarted, $backupQueueOriginalSize, $backupTotalCount, $ignoredTracksCount);

sub createBackup {
	my $importerCall = shift;

	if ($prefs->get('status_backuprestore')) {
		$log->warn('A backup is already in progress, please wait for it to finish');
		return;
	}
	$prefs->set('status_backuprestore', 1);
	$prefs->set('backuprestoreprogresspercentage', 0);
	$prefs->set('backuprestoreresult', 0);

	my $backupDir = $prefs->get('rlfolderpath');
	my $dbh = Slim::Schema->dbh;
	my ($trackURL, $trackURLmd5, $trackRating, $trackLastRated, $trackPrevRating, $trackRemote, $trackExtid, $trackMBID);
	$backupStarted = time();
	my $backuptimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;
	my $filename_timestamp = strftime "%Y%m%d-%H%M", localtime time;

	$backupQueue = [];
	$ignoredTracksCount = 0;
	eval {
		my $sth = $dbh->prepare("select tracks.url, tracks.urlmd5, tracks_persistent.rating, tracks_persistent.lastRated, tracks_persistent.prevRating, tracks.remote, tracks.extid, tracks_persistent.musicbrainz_id from tracks_persistent join tracks on tracks.urlmd5 = tracks_persistent.urlmd5 where (tracks_persistent.rating > 0 or tracks_persistent.lastRated is not null)");
		$sth->execute();
		$sth->bind_columns(undef, \$trackURL, \$trackURLmd5, \$trackRating, \$trackLastRated, \$trackPrevRating, \$trackRemote, \$trackExtid, \$trackMBID);
		while ($sth->fetch()) {
			push (@{$backupQueue}, {'url' => $trackURL, 'urlmd5' => $trackURLmd5, 'rating' => $trackRating, 'lastRated' => $trackLastRated, 'prevRating' => $trackPrevRating, 'remote' => $trackRemote, 'extid' => $trackExtid, 'musicbrainzid' => $trackMBID});
		}
		$sth->finish();
	};
	if ($@) {
		$log->error("Database error during backup: $@");
		$prefs->set('backuprestoreresult', 2);
		$prefs->set('status_backuprestore', 0);
		return;
	}

	if (@{$backupQueue}) {
		$backupQueueOriginalSize = scalar(@{$backupQueue});
		$backupTotalCount = scalar(grep { !(($_->{'remote'} == 1) && (!defined($_->{'extid'}))) } @{$backupQueue});
		my $filename = catfile($backupDir, 'RL_Backup_'.$filename_timestamp.'.xml');
		$backupOutput = FileHandle->new($filename, '>:utf8') or do {
			$log->error('Could not open '.$filename.' for writing. Does the RatingsLight folder exist? Does LMS have read/write permissions (755) for the (parent) folder?');
			$prefs->set('backuprestoreresult', 2);
			$prefs->set('status_backuprestore', 0);
			return;
		};
		main::DEBUGLOG && $log->is_debug && $log->debug('Found '.$backupTotalCount.' track(s) with rating data in the LMS persistent database');

		print $backupOutput "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n";
		print $backupOutput "<!-- Backup of Rating Data -->\n";
		print $backupOutput "<!-- ".$backuptimestamp." -->\n";
		print $backupOutput "<RatingsLight>\n";
		print $backupOutput "\t<trackcount>".$backupTotalCount."</trackcount>\n";

		if ($importerCall) {
			while (writeBackupChunk()) {}
		} else {
			Slim::Utils::Scheduler::add_task(\&writeBackupChunk);
		}
	} else {
		main::INFOLOG && $log->is_info && $log->info('Found no tracks with rating data in the LMS database.');
		$prefs->set('backuprestoreresult', 1);
		$prefs->set('status_backuprestore', 0);
	}
}

sub writeBackupChunk {
	if (my $ratedTrack = shift(@{$backupQueue})) {
		my $BACKUPtrackURL = $ratedTrack->{'url'};
		if (($ratedTrack->{'remote'} == 1) && (!defined($ratedTrack->{'extid'}))) {
			main::INFOLOG && $log->is_info && $log->info('Warning: ignoring this track. Track is remote but not part of LMS library: '.$BACKUPtrackURL);
			$ignoredTracksCount++;
			_advanceBackupProgress();
			return 1;
		}
		my $urlmd5 = $ratedTrack->{'urlmd5'};
		my $rating100ScaleValue = $ratedTrack->{'rating'} // '';
		my $lastRatedValue = toIntTimestamp($ratedTrack->{'lastRated'}) // '';
		my $previousRatingValue = $ratedTrack->{'prevRating'} // '';
		my $remote = $ratedTrack->{'remote'};
		my $BACKUPrelFilePath = ($remote == 0 ? getRelFilePath($BACKUPtrackURL) : '');
		$BACKUPtrackURL = escape($BACKUPtrackURL);
		$BACKUPrelFilePath = $BACKUPrelFilePath ? escape($BACKUPrelFilePath) : '';
		my $BACKUPtrackMBID = $ratedTrack->{'musicbrainzid'} || '';
		print $backupOutput "\t<track>\n\t\t<url>".$BACKUPtrackURL."</url>\n\t\t<urlmd5>".$urlmd5."</urlmd5>\n\t\t<relurl>".$BACKUPrelFilePath."</relurl>\n\t\t<rating>".$rating100ScaleValue."</rating>\n\t\t<lastRated>".$lastRatedValue."</lastRated>\n\t\t<prevRating>".$previousRatingValue."</prevRating>\n\t\t<remote>".$remote."</remote>\n\t\t<musicbrainzid>".$BACKUPtrackMBID."</musicbrainzid>\n\t</track>\n";
		_advanceBackupProgress();
		return 1;
	}

	print $backupOutput "</RatingsLight>\n";
	if ($ignoredTracksCount > 0) {
		print $backupOutput "<!-- WARNING: ".$ignoredTracksCount.($ignoredTracksCount == 1 ? " track was" : " tracks were")." ignored. Check server.log for more information. -->\n";
	}
	close $backupOutput;
	$backupOutput = undef;
	main::DEBUGLOG && $log->is_debug && $log->debug('Backup completed after '.(time() - $backupStarted).' seconds.');

	$prefs->set('lastbackup', int(time()));
	cleanupBackups();
	$prefs->set('backuprestoreprogresspercentage', 100);
	$prefs->set('backuprestoreresult', 1);
	$prefs->set('status_backuprestore', 0);
	return 0;
}

sub _advanceBackupProgress {
	return unless $backupQueueOriginalSize;
	$prefs->set('backuprestoreprogresspercentage', sprintf("%.0f", (($backupQueueOriginalSize - scalar(@{$backupQueue})) / $backupQueueOriginalSize) * 100));
}

sub cleanupBackups {
	my $backupFilesMin = $prefs->get('backupfilesmin');
	if ($prefs->get('autodeletebackups')) {
		my $backupDir = $prefs->get('rlfolderpath');
		return unless (-d $backupDir);
		my $backupsdaystokeep = $prefs->get('backupsdaystokeep');
		my $maxkeeptime = $backupsdaystokeep * 24 * 60 * 60; # in seconds
		opendir(my $DH, $backupDir) or do { $log->error("Error opening $backupDir: $!"); return; };
		my @files = grep(/^RL_Backup_.*$/, readdir($DH));
		closedir($DH);
		main::DEBUGLOG && $log->is_debug && $log->debug('number of backup files found: '.scalar(@files));
		my $etime = int(time());
		my $n = 0;
		if (scalar(@files) > $backupFilesMin) {
			foreach my $file (@files) {
				my $filepath = catfile($backupDir, $file);
				my $mtime = stat($filepath)->mtime;
				if (($etime - $mtime) > $maxkeeptime) {
					if (unlink($filepath)) {
						$n++;
						last if ((scalar(@files) - $n) <= $backupFilesMin);
					} else {
						$log->error("Can't delete $file: $!");
					}
				}
			}
		} else {
			main::DEBUGLOG && $log->is_debug && $log->debug('Not deleting any backups. Number of backup files to keep ('.$backupFilesMin.') '.((scalar(@files) - $n) == $backupFilesMin ? '=' : '>').' backup files found ('.scalar(@files).').');
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('Deleted '.$n.($n == 1 ? ' backup. ' : ' backups. ').(scalar(@files) - $n).((scalar(@files) - $n) == 1 ? " backup" : " backups")." remaining.");
	}
}

sub importRatingsFromCommentTags {
	main::DEBUGLOG && $log->is_debug && $log->debug('starting ratings import from comment tags');
	my $class = shift;
	if ($prefs->get('status_importingfromcommenttags') == 1) {
		$log->warn('Import is already in progress, please wait for the previous import to finish');
		return;
	}
	$prefs->set('status_importingfromcommenttags', 1);
	my $started = time();

	my $rating_keyword_prefix = $prefs->get('rating_keyword_prefix');
	my $rating_keyword_suffix = $prefs->get('rating_keyword_suffix');

	if ((!defined $rating_keyword_prefix || $rating_keyword_prefix eq '') && (!defined $rating_keyword_suffix || $rating_keyword_suffix eq '')) {
		$log->warn('Error: no rating keywords found.');
		$prefs->set('status_importingfromcommenttags', 0);
		return;
	}

	my $dbh = Slim::Schema->dbh;
	my $ratingTime = int(time());

	# unrate previously rated tracks if comment tag no longer contains keyword(s)
	my $ratingkeyword_unrate = '%%'.$rating_keyword_prefix.'_'.$rating_keyword_suffix.'%%';
	eval {
		$dbh->do("update tracks_persistent
			set rating = 0, lastRated = ?, prevRating = tracks_persistent.rating
			where (tracks_persistent.rating > 0
				and tracks_persistent.urlmd5 in (
					select tracks.urlmd5 from tracks
					left join comments on comments.track = tracks.id
					where (comments.value not like ? or comments.value is null))
			)", undef, $ratingTime, $ratingkeyword_unrate);
	};
	if ($@) {
		$log->error("Database error: $@");
	}

	# rate tracks according to comment tag keyword
	for my $rating (1..5) {
		my $rating100scalevalue = $rating * 20;
		my $ratingkeyword = '%%'.$rating_keyword_prefix.$rating.$rating_keyword_suffix.'%%';
		eval {
			$dbh->do("update tracks_persistent
				set rating = ?, lastRated = ?, prevRating = tracks_persistent.rating
				where tracks_persistent.urlmd5 in (
					select tracks.urlmd5 from tracks
					left join comments on comments.track = tracks.id
					where comments.value like ?
				)", undef, $rating100scalevalue, $ratingTime, $ratingkeyword);
		};
		if ($@) {
			$log->error("Database error: $@");
		}
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('Import completed after '.(time() - $started).' seconds.');
	$prefs->set('status_importingfromcommenttags', 0);
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
	my $ratingTime = int(time());

	my $dbh = Slim::Schema->dbh;

	# unrate previously rated tracks in LMS if BPM tag value is zero or null
	eval {
		$dbh->do("update tracks_persistent
			set rating = 0, lastRated = ?, prevRating = tracks_persistent.rating
			where (tracks_persistent.rating > 0
				and tracks_persistent.urlmd5 in (
					select tracks.urlmd5 from tracks
					where tracks.audio = 1
					and (tracks.bpm = 0 or tracks.bpm is null))
			)", undef, $ratingTime);
	};
	if ($@) {
		$log->error("Database error: $@");
	}

	# rate tracks according to BPM value
	for my $rating (1..10) {
		my $rating100scalevalue = $rating * 10;
		eval {
			$dbh->do("update tracks_persistent
				set rating = ?, lastRated = ?, prevRating = tracks_persistent.rating
				where tracks_persistent.urlmd5 in (
					select tracks.urlmd5 from tracks
					where tracks.audio = 1 and tracks.bpm = ?
				)", undef, $rating100scalevalue, $ratingTime, $rating100scalevalue);
		};
		if ($@) {
			$log->error("Database error: $@");
		}
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
	} elsif ($arg =~ m/^(0?[0-9]|1[0-9]|2[0-3]):([0-5][0-9])$/) {
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

sub toIntTimestamp {
	my $val = shift;
	return undef unless defined $val && $val ne '';
	$val =~ s/,/./;
	return undef unless $val =~ /^\d+(?:\.\d+)?$/;
	return int($val + 0.5);
}

*escape = \&URI::Escape::uri_escape_utf8;

1;
