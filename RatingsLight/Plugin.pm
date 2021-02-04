package Plugins::RatingsLight::Plugin;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::Base);
use base qw(FileHandle);
use Digest::MD5 qw(md5_hex);
use File::Basename;
use File::Spec::Functions qw(:ALL);
use FindBin qw($Bin);
use POSIX qw(strftime ceil floor);
use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Utils::DateTime;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Scanner::API;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Text;
use Time::HiRes qw(time);
use URI::Escape;
use Slim::Schema;

#use Data::Dumper;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.ratingslight',
	'defaultLevel' => 'DEBUG',
	'description'  => 'PLUGIN_RATINGSLIGHT',
});

my $RATING_CHARACTER = ' *';
my $fractionchar = ' '.HTML::Entities::decode_entities('&#189;');

my $prefs = preferences('plugin.ratingslight');
my $serverPrefs = preferences('server');

my $rating_keyword_prefix = $prefs->get('rating_keyword_prefix');
if ((! defined $rating_keyword_prefix) || ($rating_keyword_prefix eq '')) {
	$prefs->set('rating_keyword_prefix', '');
}
my $rating_keyword_suffix = $prefs->get('rating_keyword_suffix');
if ((! defined $rating_keyword_suffix) || ($rating_keyword_suffix eq '')) {
	$prefs->set('rating_keyword_suffix', '');
}
my $autoscan = $prefs->get('autoscan');
if (! defined $autoscan) {
	$prefs->set('autoscan', '0');
}
my $onlyratingnotmatchcommenttag = $prefs->get('onlyratingnotmatchcommenttag');
if (! defined $onlyratingnotmatchcommenttag) {
	$prefs->set('onlyratingnotmatchcommenttag', '0');
}
my $exectime_import = $prefs->get('exectime_import');
if (! defined $exectime_import) {
	$prefs->set('exectime_import', '8000');
}
my $exectime_export = $prefs->get('exectime_export');
if (! defined $exectime_export) {
	$prefs->set('exectime_export', '6000');
}
my $showratedtracksmenus = $prefs->get('showratedtracksmenus');
if (! defined $showratedtracksmenus) {
	$prefs->set('showratedtracksmenus', '0');
}
my $autorebuildvirtualibraryafterrating = $prefs->get('autorebuildvirtualibraryafterrating');
if (! defined $autorebuildvirtualibraryafterrating) {
	$prefs->set('autorebuildvirtualibraryafterrating', '0');
}
my $ratingcontextmenudisplaymode = $prefs->get('ratingcontextmenudisplaymode'); # 0 = stars & text, 1 = stars only, 2 = text only
if (! defined $ratingcontextmenudisplaymode) {
	$prefs->set('ratingcontextmenudisplaymode', '1');
}
my $ratingcontextmenusethalfstars = $prefs->get('ratingcontextmenusethalfstars');
if (! defined $ratingcontextmenusethalfstars) {
	$prefs->set('ratingcontextmenusethalfstars', '0');
}
my $enableIRremotebuttons = $prefs->get('enableIRremotebuttons');
if (! defined $enableIRremotebuttons) {
	$prefs->set('enableIRremotebuttons', '0');
}
my $DPLintegration = $prefs->get('DPLintegration');
if (! defined $DPLintegration) {
	$prefs->set('DPLintegration', '1');
}

$prefs->init({
	rating_keyword_prefix => $rating_keyword_prefix,
	rating_keyword_suffix => $rating_keyword_suffix,
	autoscan => $autoscan,
	onlyratingnotmatchcommenttag => $onlyratingnotmatchcommenttag,
	exectime_import => $exectime_import,
	exectime_export => $exectime_export,
	showratedtracksmenus => $showratedtracksmenus,
	autorebuildvirtualibraryafterrating => $autorebuildvirtualibraryafterrating,
	ratingcontextmenudisplaymode => $ratingcontextmenudisplaymode,
	ratingcontextmenusethalfstars => $ratingcontextmenusethalfstars,
	enableIRremotebuttons => $enableIRremotebuttons,
	DPLintegration => $DPLintegration,
});

$prefs->setValidate({
	validator => sub {
		return if $_[1] =~ m|[^a-zA-Z]|;
		return if $_[1] =~ m|[a-zA-Z]{31,}|;
		return 1;
	}
}, 'rating_keyword_prefix');
$prefs->setValidate({
	validator => sub {
		return if $_[1] =~ m|[^a-zA-Z]|;
		return if $_[1] =~ m|[a-zA-Z]{31,}|;
		return 1;
	}
}, 'rating_keyword_suffix');

sub initPlugin {
	my $class = shift;

	Slim::Music::Import->addImporter('Plugins::RatingsLight::Plugin', {
		'type'         => 'post',
		'weight'       => 99,
		'use'          => 1,
	});

	if (!main::SCANNER) {
		my $enableIRremotebuttons = $prefs->get('enableIRremotebuttons');
		my $showratedtracksmenus = $prefs->get('showratedtracksmenus');

		if ($enableIRremotebuttons == 1) {
			Slim::Control::Request::subscribe( \&newPlayerCheck, [['client']],[['new']]);
			Slim::Buttons::Common::addMode('PLUGIN.RatingsLight::Plugin', getFunctions(),\&Slim::Buttons::Input::Choice::setMode);
		}

		Slim::Control::Request::addDispatch(['ratingslight','setrating','_trackid','_rating','_incremental'], [1, 0, 1, \&setRating]);
		Slim::Control::Request::addDispatch(['ratingslight','setratingpercent', '_trackid', '_rating','_incremental'], [1, 0, 1, \&setRating]);
		Slim::Control::Request::addDispatch(['ratingslight','ratingmenu','_trackid'], [0, 1, 1, \&getRatingMenu]);
		Slim::Control::Request::addDispatch(['ratingslight','manualimport'], [0, 0, 0, \&importRatingsFromCommentTags]);
		Slim::Control::Request::addDispatch(['ratingslight','exportplayliststofiles'], [0, 0, 0, \&exportRatingsToPlaylistFiles]);

		Slim::Web::HTTP::CSRF->protectCommand('ratingslight');

		addTitleFormat('RATINGSLIGHT_RATING');
		Slim::Music::TitleFormatter::addFormat('RATINGSLIGHT_RATING',\&getTitleFormat_Rating);

		if (main::WEBUI) {
			require Plugins::RatingsLight::Settings;
			Plugins::RatingsLight::Settings->new();
		}

		if(UNIVERSAL::can("Slim::Menu::TrackInfo","registerInfoProvider")) {
					Slim::Menu::TrackInfo->registerInfoProvider( ratingslightrating => (
							before    => 'artwork',
							func     => \&trackInfoHandlerRating,
					) );
		}

		if($::VERSION ge '7.9') {
			if ($showratedtracksmenus > 0) {
				my @libraries = ();
				push @libraries,{
					id => 'RATED',
					name => 'Rated',
					sql => qq{
						INSERT OR IGNORE INTO library_track (library, track)
						SELECT '%s', tracks.id
						FROM tracks
							JOIN tracks_persistent tracks_persistent ON tracks_persistent.urlmd5 = tracks.urlmd5
								WHERE tracks_persistent.rating > 0
						GROUP by tracks.id
					},
				};
				if ($showratedtracksmenus == 2) {
					push @libraries,{
						id => 'RATED_HIGH',
						name => 'Rated - 3 stars+',
						sql => qq{
							INSERT OR IGNORE INTO library_track (library, track)
							SELECT '%s', tracks.id
							FROM tracks
								JOIN tracks_persistent tracks_persistent ON tracks_persistent.urlmd5 = tracks.urlmd5
									WHERE tracks_persistent.rating >= 60
							GROUP by tracks.id
						}
					};
				}
				foreach my $library (@libraries) {
					Slim::Music::VirtualLibraries->unregisterLibrary($library);
					Slim::Music::VirtualLibraries->registerLibrary($library);
					Slim::Music::VirtualLibraries->rebuild($library->{id});
				}

					Slim::Menu::BrowseLibrary->deregisterNode('RatingsLightRatedTracksMenuFolder');

					Slim::Menu::BrowseLibrary->registerNode({
									type         => 'link',
									name         => 'PLUGIN_RATINGSLIGHT_RATED_TRACKS_MENU_FOLDER',
									id           => 'RatingsLightRatedTracksMenuFolder',
									feed         => sub {
										my ($client, $cb, $args, $pt) = @_;
										my @items = ();

										if ($showratedtracksmenus == 2) {
											# Artists with tracks rated 3 stars+
											$pt = { library_id => Slim::Music::VirtualLibraries->getRealId('RATED_HIGH') };
											push @items,{
												type => 'link',
												name => string('PLUGIN_RATINGSLIGHT_ARTISTMENU_RATEDHIGH'),
												url => \&Slim::Menu::BrowseLibrary::_artists,
												icon => 'html/images/artists.png',
												jiveIcon => 'html/images/artists.png',
												id => string('myMusicArtists_RATED_HIGH_TracksByArtist'),
												condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
												weight => 210,
												cache => 1,
												passthrough => [{
													library_id => $pt->{'library_id'},
													searchTags => [
														'library_id:'.$pt->{'library_id'}
													],
												}],
											};

											# Genres with tracks rated 3 stars+
											$pt = { library_id => Slim::Music::VirtualLibraries->getRealId('RATED_HIGH') };
											push @items,{
												type => 'link',
												name => string('PLUGIN_RATINGSLIGHT_GENREMENU_RATEDHIGH'),
												url => \&Slim::Menu::BrowseLibrary::_genres,
												icon => 'html/images/genres.png',
												jiveIcon => 'html/images/genres.png',
												id => string('myMusicGenres_RATED_HIGH_TracksByGenres'),
												condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
												weight => 212,
												cache => 1,
												passthrough => [{
													library_id => $pt->{'library_id'},
													searchTags => [
														'library_id:'.$pt->{'library_id'}
													],
												}],
											};
										}
										# Artists with rated tracks
										$pt = { library_id => Slim::Music::VirtualLibraries->getRealId('RATED') };
										push @items,{
											type => 'link',
											name => string('PLUGIN_RATINGSLIGHT_ARTISTMENU_RATED'),
											url => \&Slim::Menu::BrowseLibrary::_artists,
											icon => 'html/images/artists.png',
											jiveIcon => 'html/images/artists.png',
											id => string('myMusicArtists_RATED_TracksByArtist'),
											condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
											weight => 209,
											cache => 1,
											passthrough => [{
												library_id => $pt->{'library_id'},
												searchTags => [
													'library_id:'.$pt->{'library_id'}
												],
											}],
										};

										# Genres with rated tracks
										$pt = { library_id => Slim::Music::VirtualLibraries->getRealId('RATED') };
										push @items,{
											type => 'link',
											name => string('PLUGIN_RATINGSLIGHT_GENREMENU_RATED'),
											url => \&Slim::Menu::BrowseLibrary::_genres,
											icon => 'html/images/genres.png',
											jiveIcon => 'html/images/genres.png',
											id => string('myMusicGenres_RATED_TracksByGenres'),
											condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
											weight => 211,
											cache => 1,
											passthrough => [{
												library_id => $pt->{'library_id'},
												searchTags => [
													'library_id:'.$pt->{'library_id'}
												],
											}],
										};

										$cb->({
											items => \@items,
										});
									 },

									weight       => 88,
									cache        => 1,
									icon => 'plugins/RatingsLight/html/images/ratedtracksmenuicon.png',
									jiveIcon => 'plugins/RatingsLight/html/images/ratedtracksmenuicon.png',
							});
			}
		}
		$class->SUPER::initPlugin(@_);
	}
}

sub startScan {
	my $enableautoscan = $prefs->get('autoscan');
	if ($enableautoscan == 1) {
		importRatingsFromCommentTags();
	}
	Slim::Music::Import->endImporter(__PACKAGE__);
}

sub importRatingsFromCommentTags {
	my $rating_keyword_prefix = $prefs->get('rating_keyword_prefix');
	my $rating_keyword_suffix = $prefs->get('rating_keyword_suffix');

	my $class = shift;
	my $dbh = getCurrentDBH();

	if ((!defined $rating_keyword_prefix || $rating_keyword_prefix eq '') && (!defined $rating_keyword_suffix || $rating_keyword_suffix eq '')) {
		$log->error('Error: no rating keywords found.');
		return
	} else {
		my $started = time();
		my $sqlunrate = "UPDATE tracks_persistent
		  SET rating = NULL
		WHERE 	(tracks_persistent.rating > 0
				AND tracks_persistent.urlmd5 IN (
				   SELECT tracks.urlmd5
					 FROM tracks
						  LEFT JOIN comments ON comments.track = tracks.id
					WHERE (comments.value NOT LIKE ? OR comments.value IS NULL) )
				);";

		my $sqlrate = "UPDATE tracks_persistent
			  SET rating = ?
			WHERE tracks_persistent.urlmd5 IN (
				SELECT tracks.urlmd5
					FROM tracks
				JOIN comments ON comments.track = tracks.id
					WHERE comments.value LIKE ?
			);";

		# unrate previously rated tracks in LMS if comment tag does no longer contain keyword(s)
		my $ratingkeyword_unrate = "%%".$rating_keyword_prefix."_".$rating_keyword_suffix."%%";

		my $sth = $dbh->prepare( $sqlunrate );
		eval {
			$sth->bind_param(1, $ratingkeyword_unrate);
			$sth->execute();
			commit($dbh);
		};
		if( $@ ) {
			$log->warn("Database error: $DBI::errstr\n");
			eval {
				rollback($dbh);
			};
		}
		$sth->finish();

		# rate tracks according to comment tag keyword
		my $rating = 1;

		until ($rating > 5) {
			my $rating100scalevalue = ($rating * 20);
			my $ratingkeyword = "%%".$rating_keyword_prefix.$rating.$rating_keyword_suffix."%%";
			my $sth = $dbh->prepare( $sqlrate );
			eval {
				$sth->bind_param(1, $rating100scalevalue);
				$sth->bind_param(2, $ratingkeyword);
				$sth->execute();
				commit($dbh);
			};
			if( $@ ) {
				$log->warn("Database error: $DBI::errstr\n");
				eval {
					rollback($dbh);
				};
			}
			$rating++;
			$sth->finish();
		}
		my $ended = time() - $started;
		#$log->debug("Import took ".$ended." seconds.");
		$exectime_import = ((floor($ended) + 2) * 1000);
		$prefs->set('exectime_import', $exectime_import);
	}
}

sub exportRatingsToPlaylistFiles {
	my $playlistDir = $serverPrefs->get('playlistdir');
	my $exportDir = $playlistDir."/RatingsLight";
	mkdir($exportDir, 0755) unless(-d $exportDir );
	chdir($exportDir) or $exportDir = $playlistDir;

	my $onlyratingnotmatchcommenttag = $prefs->get('onlyratingnotmatchcommenttag');
	my $rating_keyword_prefix = $prefs->get('rating_keyword_prefix');
	my $rating_keyword_suffix = $prefs->get('rating_keyword_suffix');
	my ($sql, $sth) = undef;
	my $dbh = getCurrentDBH();
	my ($rating5starScaleValue, $rating100ScaleValueCeil) = 0;
	my $rating100ScaleValue = 10;
	my $started = time();
	my $exporttimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;
	my $filename_timestamp = strftime "%Y%m%d-%H%M", localtime time;

	until ($rating100ScaleValue > 100) {
		$rating100ScaleValueCeil = $rating100ScaleValue + 9;
		if ($onlyratingnotmatchcommenttag == 1) {
			if ((!defined $rating_keyword_prefix || $rating_keyword_prefix eq '') && (!defined $rating_keyword_suffix || $rating_keyword_suffix eq '')) {
				$log->error('Error: no rating keywords found.');
				return
			} else {
				$sql = "SELECT tracks_persistent.url FROM tracks_persistent
				WHERE (tracks_persistent.rating >= $rating100ScaleValue
						AND tracks_persistent.rating <= $rating100ScaleValueCeil
						AND tracks_persistent.urlmd5 IN (
						   SELECT tracks.urlmd5
							 FROM tracks
								  LEFT JOIN comments ON comments.track = tracks.id
							WHERE (comments.value NOT LIKE ? OR comments.value IS NULL) )
						);";
				$sth = $dbh->prepare($sql);
				$rating5starScaleValue = $rating100ScaleValue/20;
				my $ratingkeyword = "%%".$rating_keyword_prefix.$rating5starScaleValue.$rating_keyword_suffix."%%";
				$sth->bind_param(1, $ratingkeyword);
			}
		} else {
			$sql = "SELECT tracks_persistent.url FROM tracks_persistent WHERE (tracks_persistent.rating >= $rating100ScaleValue	AND tracks_persistent.rating <= $rating100ScaleValueCeil)";
			$sth = $dbh->prepare($sql);
		}
		$sth->execute();

		my $trackURL;
		$sth->bind_col(1,\$trackURL);

		my @trackURLs = ();
		while( $sth->fetch()) {
			push @trackURLs,$trackURL;
		}
		$sth->finish();

		if (@trackURLs) {
			$rating5starScaleValue = $rating100ScaleValue/20;
			my $PLfilename = ($rating5starScaleValue == 1 ? 'RL_Export_Rated_'.$rating5starScaleValue.'_star__'.$filename_timestamp.'.m3u.txt' : 'RL_Export_Rated_'.$rating5starScaleValue.'_stars__'.$filename_timestamp.'.m3u.txt');

			my $filename = catfile($exportDir,$PLfilename);
			my $output = FileHandle->new($filename, ">") or do {
				$log->warn("Could not open $filename for writing.\n");
				return;
			};
			print $output '#EXTM3U'."\n";
			print $output '# exported with \'Ratings Light\' LMS plugin ('.$exporttimestamp.")\n\n";
			if ($onlyratingnotmatchcommenttag == 1) {
				print $output "# *** This export only contains tracks whose ratings differ from the rating value derived from their comment tag keywords. ***\n";
				print $output "# *** If you want to export ALL rated tracks change the preference on the Ratings Light settings page. ***\n\n";
			}
			for my $PLtrackURL (@trackURLs) {
				print $output "#EXTURL:".$PLtrackURL."\n";
				my $unescapedURL = uri_unescape($PLtrackURL);
				print $output $unescapedURL."\n";
			}
			close $output;
		}
		$rating100ScaleValue = $rating100ScaleValue + 10;
	}
	my $ended = time() - $started;
	#$log->debug("Export took ".$ended." seconds.");
	$exectime_export = ((floor($ended) + 2) * 1000);
	$prefs->set('exectime_export', $exectime_export);
}

sub setRating {
	my $request = shift;

	if (Slim::Music::Import->stillScanning) {
		$log->warn("Warning: access to rating values blocked until library scan is completed");
		return;
	}

	my $rating100ScaleValue = 0;
	my $showratedtracksmenus = $prefs->get('showratedtracksmenus');
	my $autorebuildvirtualibraryafterrating = $prefs->get('autorebuildvirtualibraryafterrating');


	if (($request->isNotCommand([['ratingslight'],['setrating']])) && ($request->isNotCommand([['ratingslight'],['setratingpercent']]))) {
		$request->setStatusBadDispatch();
		return;
	}
	my $client = $request->client();
	if(!defined $client) {
		$request->setStatusNeedsClient();
		return;
	}

  	my $trackId = $request->getParam('_trackid');
	if(defined($trackId) && $trackId =~ /^track_id:(.*)$/) {
		$trackId = $1;
	}elsif(defined($request->getParam('_trackid'))) {
		$trackId = $request->getParam('_trackid');
	}

  	my $rating = $request->getParam('_rating');
	if(defined($rating) && $rating =~ /^rating:(.*)$/) {
		$rating = $1;
	}elsif(defined($request->getParam('_rating'))) {
		$rating = $request->getParam('_rating');
	}

  	my $incremental = $request->getParam('_incremental');
	if(defined($incremental) && $incremental =~ /^incremental:(.*)$/) {
		$incremental = $1;
	}elsif(defined($request->getParam('_incremental'))) {
		$incremental = $request->getParam('_incremental');
	}

  	if(!defined $trackId || $trackId eq '' || !defined $rating || $rating eq '') {
		$request->setStatusBadParams();
		return;
  	}

	my $track = Slim::Schema->resultset("Track")->find($trackId);
	my $trackURL = $track->url;

	if(!defined($incremental)) {
		if($request->isNotCommand([['ratingslight'],['setratingpercent']])) {
			$rating100ScaleValue = int($rating * 20);
		} else {
			$rating100ScaleValue = $rating;
		}
	}

	if(defined($incremental) && (($incremental eq '+') || ($incremental eq '-'))) {
		my $currentrating = $track->rating;
		if (!defined $currentrating) {
			$currentrating = 0;
		}
		if ($incremental eq '+') {
			if($request->isNotCommand([['ratingslight'],['setratingpercent']])) {
				$rating100ScaleValue = $currentrating + int($rating * 20);
			} else {
				$rating100ScaleValue = $currentrating + int($rating);
			}
		} elsif ($incremental eq '-') {
			if($request->isNotCommand([['ratingslight'],['setratingpercent']])) {
				$rating100ScaleValue = $currentrating - int($rating * 20);
			} else {
				$rating100ScaleValue = $currentrating - int($rating);
			}
		}
	}
	if ($rating100ScaleValue > 100) {
		$rating100ScaleValue = 100;
	}
	if ($rating100ScaleValue < 0) {
		$rating100ScaleValue = 0;
	}
	my $rating5starScaleValue = ($rating100ScaleValue/20);

	writeRatingToDB($trackURL, $rating100ScaleValue);

	$request->addResult('rating', $rating5starScaleValue);
	$request->addResult('ratingpercentage', $rating100ScaleValue);
	$request->setStatusDone();

	# refresh virtual libraries
	if($::VERSION ge '7.9') {
		if (($showratedtracksmenus > 0) && ($autorebuildvirtualibraryafterrating == 1)) {
			my $library_id_rated_all = Slim::Music::VirtualLibraries->getRealId('RATED');
			Slim::Music::VirtualLibraries->rebuild($library_id_rated_all);

			if ($showratedtracksmenus == 2) {
			my $library_id_rated_high = Slim::Music::VirtualLibraries->getRealId('RATED_HIGH');
			Slim::Music::VirtualLibraries->rebuild($library_id_rated_high);
			}
		}
	}
}

sub getDynamicPlayLists {
	my $DPLintegration = $prefs->get('DPLintegration');

	if ($DPLintegration == 1) {
		my ($client) = @_;
		my %result = ();

		### all possible parameters ###

		# % rated high #
		my %parametertop1 = (
				'id' => 1, # 1-10
				'type' => 'list', # album, artist, genre, year, playlist, list or custom
				'name' => 'Select percentage of songs rated 3 stars or higher',
				'definition' => '0:0%,10:10%,20:20%,30:30%,40:40%,50:50%,60:60%,70:70%,80:80%,90:90%,100:100%'
		);
		my %parametertop2 = (
				'id' => 2,
				'type' => 'list',
				'name' => 'Select percentage of songs rated 3 stars or higher',
				'definition' => '0:0%,10:10%,20:20%,30:30%,40:40%,50:50%,60:60%,70:70%,80:80%,90:90%,100:100%'
		);
		my %parametertop3 = (
				'id' => 3,
				'type' => 'list',
				'name' => 'Select percentage of songs rated 3 stars or higher',
				'definition' => '0:0%,10:10%,20:20%,30:30%,40:40%,50:50%,60:60%,70:70%,80:80%,90:90%,100:100%'
		);

		# % rated #
		my %parameterrated1 = (
				'id' => 1,
				'type' => 'list',
				'name' => 'Select percentage of rated songs',
				'definition' => '0:0%,10:10%,20:20%,30:30%,40:40%,50:50%,60:60%,70:70%,80:80%,90:90%,100:100%'
		);
		my %parameterrated2 = (
				'id' => 2,
				'type' => 'list',
				'name' => 'Select percentage of rated songs',
				'definition' => '0:0%,10:10%,20:20%,30:30%,40:40%,50:50%,60:60%,70:70%,80:80%,90:90%,100:100%'
		);
		my %parameterrated3 = (
				'id' => 3,
				'type' => 'list',
				'name' => 'Select percentage of rated songs',
				'definition' => '0:0%,10:10%,20:20%,30:30%,40:40%,50:50%,60:60%,70:70%,80:80%,90:90%,100:100%'
		);

		# genre #
		my %parametergen1 = (
				'id' => 1,
				'type' => 'genre',
				'name' => 'Select genre'
		);

		# decade #
		my %parameterdec1 = (
				'id' => 1,
				'type' => 'custom',
				'name' => 'Select decade',
				'definition' => "select cast(((tracks.year/10)*10) as int),case when tracks.year>0 then cast(((tracks.year/10)*10) as int)||'s' else 'Unknown' end from tracks where tracks.audio=1 group by cast(((tracks.year/10)*10) as int) order by tracks.year desc"
		);
		my %parameterdec2 = (
				'id' => 2,
				'type' => 'custom',
				'name' => 'Select decade',
				'definition' => "select cast(((tracks.year/10)*10) as int),case when tracks.year>0 then cast(((tracks.year/10)*10) as int)||'s' else 'Unknown' end from tracks where tracks.audio=1 group by cast(((tracks.year/10)*10) as int) order by tracks.year desc"
		);

		#### playlists ###
		my %playlist1 = (
			'name' => 'Rated',
			'groups' => [['Ratings Light ']]
		);
		my %playlist2 = (
			'name' => 'Rated (with % of rated 3 stars+)',
			'groups' => [['Ratings Light ']]
		);
		my %playlist3 = (
			'name' => 'Rated - by DECADE',
			'groups' => [['Ratings Light ']]
		);
		my %playlist4 = (
			'name' => 'Rated - by DECADE (with % of rated 3 stars+)',
			'groups' => [['Ratings Light ']]
		);
		my %playlist5 = (
			'name' => 'Rated - by GENRE',
			'groups' => [['Ratings Light ']]
		);
		my %playlist6 = (
			'name' => 'Rated - by GENRE (with % of rated 3 stars+)',
			'groups' => [['Ratings Light ']]
		);
		my %playlist7 = (
			'name' => 'Rated - by GENRE + DECADE',
			'groups' => [['Ratings Light ']]
		);
		my %playlist8 = (
			'name' => 'Rated - by GENRE + DECADE (with % of rated 3 stars+)',
			'groups' => [['Ratings Light ']]
		);
		my %playlist9 = (
			'name' => 'UNrated (with % of RATED Songs)',
			'groups' => [['Ratings Light ']]
		);
		my %playlist10 = (
			'name' => 'UNrated by DECADE (with % of RATED Songs)',
			'groups' => [['Ratings Light ']]
		);
		my %playlist11 = (
			'name' => 'UNrated by GENRE (with % of RATED songs)',
			'groups' => [['Ratings Light ']]
		);
		my %playlist12 = (
			'name' => 'UNrated by GENRE + DECADE (with % of RATED songs)',
			'groups' => [['Ratings Light ']]
		);

		# Playlist1: "Rated"
		$result{'ratingslight_rated'} = \%playlist1;

		# Playlist2: "Rated (with % of rated 3 stars+)"
		my %parametersPL2 = (
			1 => \%parametertop1
		);
		$playlist2{'parameters'} = \%parametersPL2;
		$result{'ratingslight_rated-with_top_percentage'} = \%playlist2;

		# Playlist3: "Rated - by DECADE"
		my %parametersPL3 = (
			1 => \%parameterdec1
		);
		$playlist3{'parameters'} = \%parametersPL3;
		$result{'ratingslight_rated-by_decade'} = \%playlist3;

		# Playlist4: "Rated - by DECADE (with % of rated 3 stars+)"
		my %parametersPL4 = (
			1 => \%parameterdec1,
			2 => \%parametertop2
		);
		$playlist4{'parameters'} = \%parametersPL4;
		$result{'ratingslight_rated-by_decade_with_top_percentage'} = \%playlist4;

		# Playlist5: "Rated - by GENRE"
		my %parametersPL5 = (
			1 => \%parametergen1
		);
		$playlist5{'parameters'} = \%parametersPL5;
		$result{'ratingslight_rated-by_genre'} = \%playlist5;

		# Playlist6: "Rated - by GENRE (with % of rated 3 stars+)"
		my %parametersPL6 = (
			1 => \%parametergen1,
			2 => \%parametertop2
		);
		$playlist6{'parameters'} = \%parametersPL6;
		$result{'ratingslight_rated-by_genre_with_top_percentage'} = \%playlist6;

		# Playlist7: "Rated - by GENRE + DECADE"
		my %parametersPL7 = (
			1 => \%parametergen1,
			2 => \%parameterdec2
		);
		$playlist7{'parameters'} = \%parametersPL7;
		$result{'ratingslight_rated-by_genre_and_decade'} = \%playlist7;

		# Playlist8: "Rated - by GENRE + DECADE (with % of rated 3 stars+)"
		my %parametersPL8 = (
			1 => \%parametergen1,
			2 => \%parameterdec2,
			3 => \%parametertop3
		);
		$playlist8{'parameters'} = \%parametersPL8;
		$result{'ratingslight_rated-by_genre_and_decade_with_top_percentage'} = \%playlist8;

		# Playlist9: "UNrated (with % of RATED Songs)"
		my %parametersPL9 = (
			1 => \%parameterrated1
		);
		$playlist9{'parameters'} = \%parametersPL9;
		$result{'ratingslight_unrated-with_rated_percentage'} = \%playlist9;

		# Playlist10: "UNrated by DECADE (with % of RATED Songs)"
		my %parametersPL10 = (
			1 => \%parameterdec1,
			2 => \%parameterrated2
		);
		$playlist10{'parameters'} = \%parametersPL10;
		$result{'ratingslight_unrated-by_decade_with_rated_percentage'} = \%playlist10;

		# Playlist11: "UNrated by GENRE (with % of RATED songs)"
		my %parametersPL11 = (
			1 => \%parametergen1,
			2 => \%parameterrated2
		);
		$playlist11{'parameters'} = \%parametersPL11;
		$result{'ratingslight_unrated-by_genre_with_rated_percentage'} = \%playlist11;

		# Playlist12: "UNrated by GENRE + DECADE (with % of RATED songs)"
		my %parametersPL12 = (
			1 => \%parametergen1,
			2 => \%parameterdec2,
			3 => \%parameterrated3
		);
		$playlist12{'parameters'} = \%parametersPL12;
		$result{'ratingslight_unrated-by_genre_and_decade_with_rated_percentage'} = \%playlist12;

		return \%result;
	}
}

sub getNextDynamicPlayListTracks {
	my ($client,$playlist,$limit,$offset,$parameters) = @_;
	my $clientID = $client->id;
	my $DPLid = @$playlist{dynamicplaylistid};
	my @result = ();
	my ($items, $sqlstatement, $track);
	my $dbh = getCurrentDBH();
	#$log->debug("DPLid: #### ".$DPLid." ####");
	#$log->debug("parameters: ".Dumper($parameters));

	# Playlist1: "Rated"
	if ($DPLid eq 'ratingslight_rated') {
		$sqlstatement = "select tracks.url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and dynamicplaylist_history.id is null and excludecomments.id is null and tracks.secs>90 and not exists (select * from tracks t2,genre_track,genres where t2.id=tracks.id and tracks.id=genre_track.track and genre_track.genre=genres.id and genres.name in ('Classical','Classical - Opera','Classical - BR','Soundtrack - TV & Movie Themes')) group by tracks.id order by random() limit $limit;";
	}

	# Playlist2: "Rated (with % of rated 3 stars+)"
	if ($DPLid eq 'ratingslight_rated-with_top_percentage') {
		my $percentagevalue = $parameters->{1}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingshigh;
DROP TABLE IF EXISTS randomweightedratingslow;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingslow as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating <= 49 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and excludecomments.id is null and tracks.secs>90 and dynamicplaylist_history.id is null and not exists (select * from tracks t2,genre_track,genres where t2.id=tracks.id and tracks.id=genre_track.track and genre_track.genre=genres.id and genres.name in ('Classical','Classical - Opera','Classical - BR','Soundtrack - TV & Movie Themes')) order by random() limit (100-$percentagevalue);
create temporary table randomweightedratingshigh as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 49 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='clientID' where audio=1 and excludecomments.id is null and tracks.secs>90 and dynamicplaylist_history.id is null and not exists (select * from tracks t2,genre_track,genres where t2.id=tracks.id and tracks.id=genre_track.track and genre_track.genre=genres.id and genres.name in ('Classical','Classical - Opera','Classical - BR','Soundtrack - TV & Movie Themes')) order by random() limit $percentagevalue;
create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingslow UNION SELECT * from randomweightedratingshigh;
SELECT * from randomweightedratingscombined ORDER BY random() limit $limit;
DROP TABLE randomweightedratingshigh;
DROP TABLE randomweightedratingslow;
DROP TABLE randomweightedratingscombined;";
	}

	# Playlist3: "Rated - by DECADE"
	if ($DPLid eq 'ratingslight_rated-by_decade') {
		my $decade = $parameters->{1}->{'value'};
		$sqlstatement = "select tracks.url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='clientID' where audio=1 and dynamicplaylist_history.id is null and tracks.year>=$decade and tracks.year<$decade+10 and excludecomments.id is null and tracks.secs>90 and not exists (select * from tracks t2,genre_track,genres where t2.id=tracks.id and tracks.id=genre_track.track and genre_track.genre=genres.id and genres.name in ('Classical','Classical - Opera','Classical - BR','Soundtrack - TV & Movie Themes')) group by tracks.id order by random() limit $limit;";
	}

	# Playlist4: "Rated - by DECADE (with % of rated 3 stars+)"
	if ($DPLid eq 'ratingslight_rated-by_decade_with_top_percentage') {
		my $decade = $parameters->{1}->{'value'};
		my $percentagevalue = $parameters->{2}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingshigh;
DROP TABLE IF EXISTS randomweightedratingslow;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingslow as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating <= 49 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and tracks.year>=$decade and tracks.year<$decade+10 and excludecomments.id is null and tracks.secs>90 and dynamicplaylist_history.id is null and not exists (select * from tracks t2,genre_track,genres where t2.id=tracks.id and tracks.id=genre_track.track and genre_track.genre=genres.id and genres.name in ('Classical','Classical - Opera','Classical - BR','Soundtrack - TV & Movie Themes')) order by random() limit (100-$percentagevalue);
create temporary table randomweightedratingshigh as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating >= 50 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and tracks.year>=$decade and tracks.year<$decade+10 and excludecomments.id is null and tracks.secs>90 and dynamicplaylist_history.id is null and not exists (select * from tracks t2,genre_track,genres where t2.id=tracks.id and tracks.id=genre_track.track and genre_track.genre=genres.id and genres.name in ('Classical','Classical - Opera','Classical - BR','Soundtrack - TV & Movie Themes')) order by random() limit $percentagevalue;
create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingslow UNION SELECT * from randomweightedratingshigh;
SELECT * from randomweightedratingscombined ORDER BY random()limit $limit;
DROP TABLE randomweightedratingshigh;
DROP TABLE randomweightedratingslow;
DROP TABLE randomweightedratingscombined;";
	}

	# Playlist5: "Rated - by GENRE"
	if ($DPLid eq 'ratingslight_rated-by_genre') {
		my $genre = $parameters->{1}->{'value'};
		$sqlstatement = "select tracks.url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and dynamicplaylist_history.id is null and excludecomments.id is null and tracks.secs>90 group by tracks.id order by random() limit $limit;";
	}

	# Playlist6: "Rated - by GENRE (with % of rated 3 stars+)"
	if ($DPLid eq 'ratingslight_rated-by_genre_with_top_percentage') {
		my $genre = $parameters->{1}->{'value'};
		my $percentagevalue = $parameters->{2}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingshigh;
DROP TABLE IF EXISTS randomweightedratingslow;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingslow as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating <= 49 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and excludecomments.id is null and tracks.secs>90 and dynamicplaylist_history.id is null order by random() limit (100-$percentagevalue);
create temporary table randomweightedratingshigh as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating >= 50 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and excludecomments.id is null and tracks.secs>90 and dynamicplaylist_history.id is null order by random() limit $percentagevalue;
create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingslow UNION SELECT * from randomweightedratingshigh;
SELECT * from randomweightedratingscombined ORDER BY random() limit $limit;
DROP TABLE randomweightedratingshigh;
DROP TABLE randomweightedratingslow;
DROP TABLE randomweightedratingscombined;";
	}

	# Playlist7: "Rated - by GENRE + DECADE"
	if ($DPLid eq 'ratingslight_rated-by_genre_and_decade') {
		my $genre = $parameters->{1}->{'value'};
		my $decade = $parameters->{2}->{'value'};
		$sqlstatement = "select tracks.url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and dynamicplaylist_history.id is null and excludecomments.id is null and tracks.secs>90 and tracks.year>=$decade and tracks.year<$decade+10 group by tracks.id order by random() limit $limit;";
	}

	# Playlist8: "Rated - by GENRE + DECADE (with % of rated 3 stars+)"
	if ($DPLid eq 'ratingslight_rated-by_genre_and_decade_with_top_percentage') {
		my $genre = $parameters->{1}->{'value'};
		my $decade = $parameters->{2}->{'value'};
		my $percentagevalue = $parameters->{3}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingshigh;
DROP TABLE IF EXISTS randomweightedratingslow;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingslow as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating <= 49 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and tracks.year>=$decade and tracks.year<$decade+10 and excludecomments.id is null and tracks.secs>90 and dynamicplaylist_history.id is null order by random() limit (100-$percentagevalue);
create temporary table randomweightedratingshigh as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 50 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and tracks.year>=$decade and tracks.year<$decade+10 and excludecomments.id is null and tracks.secs>90 and dynamicplaylist_history.id is null order by random() limit $percentagevalue;
create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingslow UNION SELECT * from randomweightedratingshigh;
SELECT * from randomweightedratingscombined ORDER BY random() limit $limit;
DROP TABLE randomweightedratingshigh;
DROP TABLE randomweightedratingslow;
DROP TABLE randomweightedratingscombined;";
	}

	# Playlist9: "UNrated (with % of RATED Songs)"
	if ($DPLid eq 'ratingslight_unrated-with_rated_percentage') {
		my $percentagevalue = $parameters->{1}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingsrated;
DROP TABLE IF EXISTS randomweightedratingsunrated;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and (tracks_persistent.rating = 0 or tracks_persistent.rating is null) left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and excludecomments.id is null and tracks.secs>90 and dynamicplaylist_history.id is null and not exists (select * from tracks t2,genre_track,genres where t2.id=tracks.id and tracks.id=genre_track.track and genre_track.genre=genres.id and genres.name in ('Classical','Classical - Opera','Classical - BR','Soundtrack - TV & Movie Themes')) order by random() limit (100-$percentagevalue);
create temporary table randomweightedratingsrated as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and excludecomments.id is null and tracks.secs>90 and dynamicplaylist_history.id is null and not exists (select * from tracks t2,genre_track,genres where t2.id=tracks.id and tracks.id=genre_track.track and genre_track.genre=genres.id and genres.name in ('Classical','Classical - Opera','Classical - BR','Soundtrack - TV & Movie Themes')) order by random() limit $percentagevalue;
create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingsunrated UNION SELECT * from randomweightedratingsrated;
SELECT * from randomweightedratingscombined ORDER BY random() limit $limit;
DROP TABLE randomweightedratingsrated;
DROP TABLE randomweightedratingsunrated;
DROP TABLE randomweightedratingscombined;";
	}

	# Playlist10: "UNrated by DECADE (with % of RATED Songs)"
	if ($DPLid eq 'ratingslight_unrated-by_decade_with_rated_percentage') {
		my $decade = $parameters->{1}->{'value'};
		my $percentagevalue = $parameters->{2}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingsrated;
DROP TABLE IF EXISTS randomweightedratingsunrated;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and (tracks_persistent.rating = 0 or tracks_persistent.rating is null) left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and tracks.year>=$decade and tracks.year<$decade+10 and tracks.secs>90 and dynamicplaylist_history.id is null and not exists (select * from tracks t2,genre_track,genres where t2.id=tracks.id and tracks.id=genre_track.track and genre_track.genre=genres.id and genres.name in ('Classical','Classical - Opera','Classical - BR','Soundtrack - TV & Movie Themes')) order by random() limit (100-$percentagevalue);
create temporary table randomweightedratingsrated as select tracks.url as url from tracks join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and tracks.year>=$decade and tracks.year<$decade+10 and excludecomments.id is null and tracks.secs>90 and dynamicplaylist_history.id is null and not exists (select * from tracks t2,genre_track,genres where t2.id=tracks.id and tracks.id=genre_track.track and genre_track.genre=genres.id and genres.name in ('Classical','Classical - Opera','Classical - BR','Soundtrack - TV & Movie Themes')) order by random() limit $percentagevalue;
create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingsunrated UNION SELECT * from randomweightedratingsrated;
SELECT * from randomweightedratingscombined ORDER BY random() limit $limit;
DROP TABLE randomweightedratingsrated;
DROP TABLE randomweightedratingsunrated;
DROP TABLE randomweightedratingscombined;";
	}

	# Playlist11: "UNrated by GENRE (with % of RATED songs)"
	if ($DPLid eq 'ratingslight_unrated-by_genre_with_rated_percentage') {
		my $genre = $parameters->{1}->{'value'};
		my $percentagevalue = $parameters->{2}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingsrated;
DROP TABLE IF EXISTS randomweightedratingsunrated;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and (tracks_persistent.rating = 0 or tracks_persistent.rating is null) left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and excludecomments.id is null and tracks.secs>90 and dynamicplaylist_history.id is null order by random() limit (100-$percentagevalue);
create temporary table randomweightedratingsrated as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and excludecomments.id is null and tracks.secs>90 and dynamicplaylist_history.id is null order by random() limit $percentagevalue;
create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingsunrated UNION SELECT * from randomweightedratingsrated;
SELECT * from randomweightedratingscombined ORDER BY random() limit $limit;
DROP TABLE randomweightedratingsrated;
DROP TABLE randomweightedratingsunrated;
DROP TABLE randomweightedratingscombined;";
	}

	# Playlist12: "UNrated by GENRE + DECADE (with % of RATED songs)"
	if ($DPLid eq 'ratingslight_unrated-by_genre_and_decade_with_rated_percentage') {
		my $genre = $parameters->{1}->{'value'};
		my $decade = $parameters->{2}->{'value'};
		my $percentagevalue = $parameters->{3}->{'value'};
		$sqlstatement = "DROP TABLE IF EXISTS randomweightedratingsrated;
DROP TABLE IF EXISTS randomweightedratingsunrated;
DROP TABLE IF EXISTS randomweightedratingscombined;
create temporary table randomweightedratingsunrated as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and (tracks_persistent.rating = 0 or tracks_persistent.rating is null) left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and tracks.year>=$decade and tracks.year<$decade+10 and excludecomments.id is null and tracks.secs>90 and dynamicplaylist_history.id is null order by random() limit (100-$percentagevalue);
create temporary table randomweightedratingsrated as select tracks.url as url from tracks join genre_track on tracks.id=genre_track.track join genres on genre_track.genre=genres.id and genre_track.genre=$genre join tracks_persistent on tracks.url=tracks_persistent.url and tracks_persistent.rating > 0 left join comments as excludecomments on tracks.id=excludecomments.track and excludecomments.value like '%%never%%' left join dynamicplaylist_history on tracks.id=dynamicplaylist_history.id and dynamicplaylist_history.client='$clientID' where audio=1 and tracks.year>=$decade and tracks.year<$decade+10 and excludecomments.id is null and tracks.secs>90 and dynamicplaylist_history.id is null order by random() limit $percentagevalue;
create temporary table randomweightedratingscombined as SELECT * FROM randomweightedratingsunrated UNION SELECT * from randomweightedratingsrated;
SELECT * from randomweightedratingscombined ORDER BY random() limit $limit;
DROP TABLE randomweightedratingsrated;
DROP TABLE randomweightedratingsunrated;
DROP TABLE randomweightedratingscombined;";
	}

	for my $sql (split(/[\n\r]/,$sqlstatement)) {
    	eval {
			my $sth = $dbh->prepare( $sql );
			$sth->execute() or do {
				$sql = undef;
			};
			if ($sql =~ /^\(*SELECT+/oi) {
				my $url;
				$sth->bind_col(1,\$url);

				while( $sth->fetch()) {
					$track = Slim::Schema->resultset("Track")->objectForUrl($url);
					push @result,$track;
				}
			}
			$sth->finish();
		};
	}
	return \@result;
}

our %menuFunctions = (
	'saveremoteratings' => sub {
		my $rating = undef;
		my $client = shift;
		my $button = shift;
		my $digit = shift;

		if (Slim::Music::Import->stillScanning) {
			$log->warn("Warning: access to rating values blocked until library scan is completed");
			$client->showBriefly({
				'line' => [$client->string('PLUGIN_RATINGSLIGHT'),$client->string('PLUGIN_RATINGSLIGHT_BLOCKED')]},
				3);
			return;
		}

		return unless $digit>='0' && $digit<='9';

		my $song = Slim::Player::Playlist::song($client);
		my $curtrackinfo = $song->{_column_data};
		#$log->debug(Dumper($curtrackinfo));

		my $curtrackURL = @$curtrackinfo{url};
		my $curtrackid = @$curtrackinfo{id};

		if ($digit == 0) {
			$rating = 0;
		}

		if ($digit > 0 && $digit <=5) {
			$rating = $digit*20;
		}

		if ($digit >= 6 && $digit <= 9) {
			my $track = Slim::Schema->resultset("Track")->find($curtrackid);
			my $currentrating = $track->rating;
			if (!defined $currentrating) {
				$currentrating = 0;
			}
			if ($digit == 6) {
				$rating = $currentrating - 20;
			}
			if ($digit == 7) {
				$rating = $currentrating + 20;
			}
			if ($digit == 8) {
				$rating = $currentrating - 10;
			}
			if ($digit == 9) {
				$rating = $currentrating + 10;
			}
			if ($rating > 100) {
				$rating = 100;
			}
			if ($rating < 0) {
				$rating = 0;
			}
		}
		writeRatingToDB($curtrackURL, $rating);

		my $detecthalfstars = ($rating/2)%2;
		my $ratingStars = $rating/20;
		my $ratingtext = string('PLUGIN_RATINGSLIGHT_UNRATED');
		if ($rating > 0) {
			if ($detecthalfstars == 1) {
				$ratingStars = floor($ratingStars);
				$ratingtext = ($RATING_CHARACTER x $ratingStars).$fractionchar;
			} else {
				$ratingtext = ($RATING_CHARACTER x $ratingStars);
			}
		}
		$client->showBriefly({
			'line' => [$client->string('PLUGIN_RATINGSLIGHT'),$client->string('PLUGIN_RATINGSLIGHT_RATING').' '.($ratingtext)]},
			3);
	},
);

sub getFunctions {
	return \%menuFunctions;
}

sub newPlayerCheck {
	my ($request) = @_;
	my $client = $request->client();
	my $clientID = $client->id;
	my $model = Slim::Player::Client::getClient($clientID)->model;

	if ( defined($client) && $request->{_requeststr} eq "client,new" ) {
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, '1', 'modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_1');
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, '2', 'modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_2');
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, '3', 'modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_3');
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, '4', 'modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_4');
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, '5', 'modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_5');
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, '8', 'modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_8');
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, '9', 'modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_9');
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, '0', 'modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_0');
		if ($model eq 'boom') {
			Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, 'arrow_down', 'modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_6');
			Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, 'arrow_up', 'modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_7');
		}
	}
}

sub mapKeyHold {
	# from Peter Watkins' plugin AllQuiet
	my $client = shift;
	my $baseKeyName = shift;
	my $function = shift;
	if ( defined($client) ) {
		my $mapsAltered = 0;
		my @maps  = @{$client->irmaps};
		for (my $i = 0; $i < scalar(@maps) ; ++$i) {
			if (ref($maps[$i]) eq 'HASH') {
				my %mHash = %{$maps[$i]};
				foreach my $key (keys %mHash) {
					if (ref($mHash{$key}) eq 'HASH') {
						my %mHash2 = %{$mHash{$key}};
						# if no $baseKeyName.hold
						if ( (!defined($mHash2{$baseKeyName.'.hold'})) || ($mHash2{$baseKeyName.'.hold'} eq 'dead') ) {
							#$log->debug("mapping $function to ${baseKeyName}.hold for $i-$key");
							if ( (defined($mHash2{$baseKeyName}) || (defined($mHash2{$baseKeyName.'.*'}))) &&
								 (!defined($mHash2{$baseKeyName.'.single'})) ) {
								# make baseKeyName.single = baseKeyName
								$mHash2{$baseKeyName.'.single'} = $mHash2{$baseKeyName};
							}
							# make baseKeyName.hold = $function
							$mHash2{$baseKeyName.'.hold'} = $function;
							# make baseKeyName.repeat = "dead"
							$mHash2{$baseKeyName.'.repeat'} = 'dead';
							# make baseKeyName.release = "dead"
							$mHash2{$baseKeyName.'.hold_release'} = 'dead';
							# delete unqualified baseKeyName
							$mHash2{$baseKeyName} = undef;
							# delete baseKeyName.*
							$mHash2{$baseKeyName.'.*'} = undef;
							++$mapsAltered;
						#} else {
							#$log->debug("${baseKeyName}.hold mapping already exists for $i-$key");
						}
						$mHash{$key} = \%mHash2;
					}
				}
				$maps[$i] = \%mHash;
			}
		}
		if ( $mapsAltered > 0 ) {
			#$log->info("mapping ${baseKeyName}.hold to $function for \"".$client->name()."\" in $mapsAltered modes");
			$client->irmaps(\@maps);
		}
	}
}

sub trackInfoHandlerRating {
	my $ratingcontextmenudisplaymode = $prefs->get('ratingcontextmenudisplaymode');
 	my ($rating100ScaleValue, $rating5starScaleValue, $rating5starScaleValueExact) = 0;
	my $text = string('PLUGIN_RATINGSLIGHT_RATING');
	my ($text1, $text2) = '';
	my $ishalfstarrating = '0';

	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;
    $tags ||= {};

	if (Slim::Music::Import->stillScanning) {
		if ( $tags->{menuMode} ) {
			my $jive = {};
			return {
				type      => '',
				name      => $text." ".string('PLUGIN_RATINGSLIGHT_BLOCKED'),
				jive      => $jive,
			};
		}else {
			return {
				type => 'text',
				name => $text." ".string('PLUGIN_RATINGSLIGHT_BLOCKED'),
			};
		}
	}

	$rating100ScaleValue = getRatingFromDB($track);

    if ( $tags->{menuMode} ) {
		my $jive = {};
		my $actions = {
			go => {
				player => 0,
				cmd => ['ratingslight', 'ratingmenu', $track->id],
			},
		};
		$jive->{actions} = $actions;
		$text = string('PLUGIN_RATINGSLIGHT_RATING').' '.string('PLUGIN_RATINGSLIGHT_UNRATED');
		if ($rating100ScaleValue > 0) {
			$rating5starScaleValueExact = $rating100ScaleValue/20;
			my $detecthalfstars = ($rating100ScaleValue/2)%2;
			if ($detecthalfstars == 1) {
				my $displayrating5starScaleValueExact = floor($rating5starScaleValueExact);
				$text1 = ($RATING_CHARACTER x $displayrating5starScaleValueExact).$fractionchar;
				$text2 = ($displayrating5starScaleValueExact > 0 ? '$displayrating5starScaleValueExact.5 ' : '0.5 ').'stars';
			} else {
				$text1 = ($RATING_CHARACTER x $rating5starScaleValueExact);
				$text2 = '$rating5starScaleValueExact '.($rating5starScaleValueExact == 1 ? 'star' : 'stars');
			}
			if ($ratingcontextmenudisplaymode == 1) {
				$text = string('PLUGIN_RATINGSLIGHT_RATING').' '.$text1;
			} elsif ($ratingcontextmenudisplaymode == 2) {
				$text = string('PLUGIN_RATINGSLIGHT_RATING').' '.$text2;
			} else {
				$text = string('PLUGIN_RATINGSLIGHT_RATING').' '.$text1.'   ('.$text2.')';
			}
		}
		return {
			type      => 'redirect',
			name      => $text,
			jive      => $jive,
		};
	}else {
		if ($rating100ScaleValue > 0) {
			$rating5starScaleValueExact = $rating100ScaleValue/20;
			my $detecthalfstars = ($rating100ScaleValue/2)%2;
			if ($detecthalfstars == 1) {
				my $displayrating5starScaleValueExact = floor($rating5starScaleValueExact);
				$text1 = ($RATING_CHARACTER x $displayrating5starScaleValueExact).$fractionchar;
				$text2 = ($displayrating5starScaleValueExact > 0 ? '$displayrating5starScaleValueExact.5 ' : '0.5 ').'stars';
			} else {
				$text1 = ($RATING_CHARACTER x $rating5starScaleValueExact);
				$text2 = '$rating5starScaleValueExact '.($rating5starScaleValueExact == 1 ? 'star' : 'stars');
			}
			if ($ratingcontextmenudisplaymode == 1) {
				$text = string('PLUGIN_RATINGSLIGHT_RATING').' '.$text1;
			} elsif ($ratingcontextmenudisplaymode == 2) {
				$text = string('PLUGIN_RATINGSLIGHT_RATING').' '.$text2;
			} else {
				$text = string('PLUGIN_RATINGSLIGHT_RATING').' '.$text1.'   ('.$text2.')';
			}
		}
 		return {
			type => 'text',
			name => $text,
			itemvalue => $rating100ScaleValue,
			itemvalue5starexact => $rating5starScaleValueExact,
			itemid => $track->id,
			web      => {
				'type' => 'htmltemplate',
				'value' => 'plugins/RatingsLight/html/trackratinginfo.html'
			},
		};
	}
}

sub getRatingMenu {
	my $request = shift;
	my $client = $request->client();
	my $ratingcontextmenudisplaymode = $prefs->get('ratingcontextmenudisplaymode');
	my $ratingcontextmenusethalfstars = $prefs->get('ratingcontextmenusethalfstars');

	if (!$request->isQuery([['ratingslight'],['ratingmenu']])) {
		$log->warn("Incorrect command\n");
		$request->setStatusBadDispatch();
		$log->debug("Exiting getRatingMenu\n");
		return;
	}
	if(!defined $client) {
		$log->warn("Client required\n");
		$request->setStatusNeedsClient();
		$log->debug("Exiting cliJiveHandler\n");
		return;
	}
	my $track_id = $request->getParam('_trackid');

	my %baseParams = ();
	my $baseMenu = {
		'actions' => {
			'do' => {
				'cmd' => ['ratingslight', 'setratingpercent', $track_id],
				'itemsParams' => 'params',
			},
			'play' => {
				'cmd' => ['ratingslight', 'setratingpercent', $track_id],
				'itemsParams' => 'params',
			},
		}
	};
	$request->addResult('base',$baseMenu);
	my $cnt = 0;

	my @ratingValues = ();
	if ($ratingcontextmenusethalfstars == 1) {
		@ratingValues = qw(100 90 80 70 60 50 40 30 20 10);
	} else {
		@ratingValues = qw(100 80 60 40 20);
	}

	foreach my $rating (@ratingValues) {
		my %itemParams = (
			'rating' => $rating,
		);
		$request->addResultLoop('item_loop',$cnt,'params',\%itemParams);
		my $detecthalfstars = ($rating/2)%2;
		my $ratingStars = $rating/20;
		my $spacechar = " ";
		my $maxlength = 22;
		my $spacescount = 0;
		my ($text, $text1, $text2) = '';

		if ($detecthalfstars == 1) {
			$ratingStars = floor($ratingStars);
			$text1 = ($RATING_CHARACTER x $ratingStars).$fractionchar;
			$text2 = ($ratingStars > 0 ? "$ratingStars.5 " : "0.5 ")."stars";
		} else {
			$text1 = ($RATING_CHARACTER x $ratingStars);
			$text2 = "$ratingStars ".($ratingStars == 1 ? "star" : "stars");
		}
		if ($ratingcontextmenudisplaymode == 1) {
			$text = $text1;
		} elsif ($ratingcontextmenudisplaymode == 2) {
			$text = $text2;
		} else {
			$spacescount = $maxlength - (length $text1) - (length $text2);
			$text = $text1.($spacechar x $spacescount)."(".$text2.")";
		}
		$request->addResultLoop('item_loop',$cnt,'text',$text);

		$request->addResultLoop('item_loop',$cnt,'nextWindow','parent');
		$cnt++;
	}
	my %itemParams = (
		'rating' => 0,
	);
	$request->addResultLoop('item_loop',$cnt,'params',\%itemParams);
	$request->addResultLoop('item_loop',$cnt,'text',string("PLUGIN_RATINGSLIGHT_UNRATED"));
	$request->addResultLoop('item_loop',$cnt,'nextWindow','parent');
	$cnt++;

	$request->addResult('offset',0);
	$request->addResult('count',$cnt);
	$request->setStatusDone();
}

sub getTitleFormat_Rating {
	my $track = shift;
	my $ratingtext = HTML::Entities::decode_entities('&nbsp;');
	my $rating100ScaleValue = 0;
	my $rating5starScaleValue = 0;

	$rating100ScaleValue = getRatingFromDB($track);
	if ($rating100ScaleValue > 0) {
		my $detecthalfstars = ($rating100ScaleValue/2)%2;
		my $ratingStars = $rating100ScaleValue/20;

		if ($detecthalfstars == 1) {
			$ratingStars = floor($ratingStars);
			$ratingtext = ($RATING_CHARACTER x $ratingStars).$fractionchar;
		} else {
			$ratingtext = ($RATING_CHARACTER x $ratingStars);
		}
	}
	return $ratingtext;
}

sub getCustomSkipFilterTypes {
	my @result = ();
	my %rated = (
		'id' => 'ratingslight_rated',
		'name' => 'Rated low',
		'description' => 'Skip tracks with ratings below specified value',
		'mixtype' => 'track',
		'parameters' => [
			{
				'id' => 'rating',
				'type' => 'singlelist',
				'name' => 'Maximum rating to skip',
				'data' => "29=* (0-29),49=** (0-49),69=*** (0-69),89=**** (0-89),100=***** (0-100)",
				'value' => 49
			}
		]
	);
	push @result, \%rated;

	my %notrated = (
		'id' => 'ratingslight_notrated',
		'name' => 'Not rated',
		'description' => 'Skip tracks without a rating',
		'mixtype' => 'track'
	);
	push @result, \%notrated;

	return \@result;
}

sub checkCustomSkipFilterType {
	my $client = shift;
	my $filter = shift;
	my $track = shift;

	my $parameters = $filter->{'parameter'};

	if($filter->{'id'} eq 'ratingslight_rated') {
		my $rating100ScaleValue = getRatingFromDB($track);
		for my $parameter (@$parameters) {
			if($parameter->{'id'} eq 'rating') {
				my $ratings = $parameter->{'value'};
				my $rating = $ratings->[0] if(defined($ratings) && scalar(@$ratings)>0);
				if($rating100ScaleValue <= $rating) {
					return 1;
				}
				last;
			}
		}
	}elsif($filter->{'id'} eq 'ratingslight_notrated') {
		my $rating100ScaleValue = getRatingFromDB($track);
		if($rating100ScaleValue == 0) {
			return 1;
		}
	}
	return 0;
}

sub writeRatingToDB {
	my ($trackURL, $rating100ScaleValue) = @_;
	my $urlmd5 = md5_hex($trackURL);

	my $sql = "UPDATE tracks_persistent set rating=$rating100ScaleValue where urlmd5 = ?";
	my $dbh = getCurrentDBH();
	my $sth = $dbh->prepare( $sql );
	eval {
		$sth->bind_param(1, $urlmd5);
		$sth->execute();
		commit($dbh);
	};
	if( $@ ) {
		$log->warn("Database error: $DBI::errstr\n");
		eval {
			rollback($dbh);
		};
	}
	$sth->finish();
	if (!main::SCANNER) {
		Slim::Music::Info::clearFormatDisplayCache();
	}
}

sub getRatingFromDB {
	my $track = shift;
	my $rating = 0;

	if (Slim::Music::Import->stillScanning) {
		$log->warn("Warning: access to rating values blocked until library scan is completed");
		return $rating;
	}

	my $thisrating = $track->rating;
	if (defined $thisrating) {
		$rating = $thisrating;
	}
	return $rating;
}

sub addTitleFormat {
	my $titleformat = shift;
	my $titleFormats = $serverPrefs->get('titleFormat');
	foreach my $format ( @$titleFormats ) {
		if($titleformat eq $format) {
			return;
		}
	}
	push @$titleFormats,$titleformat;
	$serverPrefs->set('titleFormat',$titleFormats);
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
