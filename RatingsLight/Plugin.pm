package Plugins::RatingsLight::Plugin;

use strict;
use warnings;
use utf8;

use Slim::Player::Client;
use base qw(Slim::Plugin::Base);
use base qw(FileHandle);
use Digest::MD5 qw(md5_hex);
use File::Basename;
use File::Spec::Functions qw(:ALL);
use POSIX;
use Slim::Control::Request;
use Slim::Utils::DateTime;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Scanner::API;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Text;
use Time::HiRes qw(time);
use URI::Escape;

use Slim::Schema;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.ratingslight',
	'defaultLevel' => 'DEBUG',
	'description'  => 'PLUGIN_RATINGSLIGHT',
});

use Data::Dumper;

my $RATING_CHARACTER = ' *';
my $fractionchar = ' '.HTML::Entities::decode_entities('&#189;');
my $ratingQueue = {};

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
});

$prefs->setValidate({
	validator => sub {
		return if $_[1] =~ m|[^a-zA-Z]|;
		return if $_[1] =~ m|[a-zA-Z]{31,}|;
		#return if $_[1] eq '';
		return 1;
	}
}, 'rating_keyword_prefix');
$prefs->setValidate({
	validator => sub {
		return if $_[1] =~ m|[^a-zA-Z]|;
		return if $_[1] =~ m|[a-zA-Z]{31,}|;
		#return if $_[1] eq '';
		return 1;
	}
}, 'rating_keyword_suffix');

sub initPlugin {
	my $class = shift;

	Slim::Music::Import->addImporter('Plugins::RatingsLight::Plugin', {
		'type'         => 'post',
		'weight'       => 95,
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
	my $onlyratingnotmatchcommenttag = $prefs->get('onlyratingnotmatchcommenttag');
	my $rating_keyword_prefix = $prefs->get('rating_keyword_prefix');
	my $rating_keyword_suffix = $prefs->get('rating_keyword_suffix');
	my ($sql, $sth) = undef;
	my $dbh = getCurrentDBH();
	my ($rating5starScaleValue, $rating100ScaleValueCeil) = 0;
	my $rating100ScaleValue = 10;
	my $started = time();
	my $exporttimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;	

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
			my $PLfilename = ($rating5starScaleValue == 1 ? 'RL_Export_Rated_'.$rating5starScaleValue.'_star.m3u.txt' : 'RL_Export_Rated_'.$rating5starScaleValue.'_stars.m3u.txt');

			my $filename = catfile($playlistDir,$PLfilename);
			my $output = FileHandle->new($filename, ">") or do {
				$log->warn("Could not open $filename for writing.\n");
				return;
			};
			print $output '#EXTM3U'."\n";
			print $output '# exported with \'Ratings Light\' LMS plugin ('.$exporttimestamp.")s\n";

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
	my $rating100ScaleValue = 0;
	my $showratedtracksmenus = $prefs->get('showratedtracksmenus');
	my $autorebuildvirtualibraryafterrating = $prefs->get('autorebuildvirtualibraryafterrating');

	my $request = shift;

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
	} else {
		if($request->isNotCommand([['ratingslight'],['setratingpercent']])) {
			$rating100ScaleValue = int($rating * 20);
		} else {
			$rating100ScaleValue = $rating;
		}
	}
	if ($rating100ScaleValue > 100) {
		$rating100ScaleValue = 100;
	}
	if ($rating100ScaleValue < 0) {
		$rating100ScaleValue = 0;
	}
	my $rating5starScaleValue = (($rating100ScaleValue+10)/20);

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

our %menuFunctions = (
	'saveremoteratings' => sub {
		my $rating = undef;
		my $client = shift;
		my $button = shift;
		my $digit = shift;

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
	Slim::Music::Info::clearFormatDisplayCache();
}

sub getRatingFromDB {
	my $track = shift;
	my $rating = 0;

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
