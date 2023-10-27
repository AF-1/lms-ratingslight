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

package Plugins::RatingsLight::Plugin;

use strict;
use warnings;
use utf8;

use base qw(FileHandle);
use base qw(Slim::Plugin::Base);
use Digest::MD5 qw(md5_hex);
use File::Basename;
use File::Copy qw(move);
use File::Spec::Functions qw(:ALL);
use File::stat;
use FindBin qw($Bin);
use POSIX qw(strftime floor);
use Scalar::Util qw(blessed);
use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Player::Source;
use Slim::Schema;
use Slim::Utils::DateTime;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Scanner::API;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Text;
use Time::HiRes qw(time);
use XML::Parser;

use Plugins::RatingsLight::Common ':all';
use Plugins::RatingsLight::Importer;

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.ratingslight',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_RATINGSLIGHT',
});

my $prefs = preferences('plugin.ratingslight');
my $serverPrefs = preferences('server');

my (%restoreitem, $currentKey, $inTrack, $inValue, $backupParser, $backupParserNB, $restorestarted, $material_enabled, $MAIprefs);
my $opened = 0;

sub initPlugin {
	my $class = shift;

	initPrefs();
	initIR();

	Slim::Control::Request::addDispatch(['ratingslight', 'setrating', '_trackid', '_rating', '_incremental'], [1, 0, 1, \&setRating]);
	Slim::Control::Request::addDispatch(['ratingslight', 'setratingpercent', '_trackid', '_rating', '_incremental'], [1, 0, 1, \&setRating]);
	Slim::Control::Request::addDispatch(['ratingslight', 'ratealbumoptions', '_albumid'], [1, 1, 1, \&rateAlbumTracksOptions_jive]);
	Slim::Control::Request::addDispatch(['ratingslight', 'ratingmenu', '_trackid', '_isalbum', '_unratedonly'], [0, 1, 1, \&getRatingMenu]);
	Slim::Control::Request::addDispatch(['ratingslight', 'ratealbum', '_albumid', '_rating', '_unratedonly'], [1, 1, 1, \&rateAlbumTracks_jive]);
	Slim::Control::Request::addDispatch(['ratingslight', 'ratedtracksmenu', '_trackid', '_thisid', '_objecttype'], [0, 1, 1, \&getRatedTracksMenu]);
	Slim::Control::Request::addDispatch(['ratingslight', 'actionsmenu'], [0, 1, 1, \&getActionsMenu]);
	Slim::Control::Request::addDispatch(['ratingslight', 'changedrating', '_url', '_trackid', '_rating', '_ratingpercent'], [0, 0, 0, undef]);
	Slim::Control::Request::addDispatch(['ratingslightchangedratingupdate'], [0, 1, 0, undef]);

	Slim::Control::Request::subscribe(\&setRefreshTimer, [['rescan'],['done']]);

	Slim::Web::HTTP::CSRF->protectCommand('ratingslight');

	addTitleFormat('RL_RATING_STARS');
	Slim::Music::TitleFormatter::addFormat('RL_RATING_STARS',\&getTitleFormat_Rating, 1);

	addTitleFormat('RL_RATING_STARS_APPENDED');
	Slim::Music::TitleFormatter::addFormat('RL_RATING_STARS_APPENDED',\&getTitleFormat_Rating_AppendedStars, 1);

	if (main::WEBUI) {
		require Plugins::RatingsLight::Settings::Basic;
		require Plugins::RatingsLight::Settings::Backup;
		require Plugins::RatingsLight::Settings::Import;
		require Plugins::RatingsLight::Settings::Export;
		require Plugins::RatingsLight::Settings::Menus;
		require Plugins::RatingsLight::Settings::DSTM;
		Plugins::RatingsLight::Settings::Basic->new($class);
		Plugins::RatingsLight::Settings::Backup->new($class);
		Plugins::RatingsLight::Settings::Import->new($class);
		Plugins::RatingsLight::Settings::Export->new($class);
		Plugins::RatingsLight::Settings::Menus->new($class);
		Plugins::RatingsLight::Settings::DSTM->new($class);

		Slim::Web::Pages->addPageFunction('showratedtrackslist.html', \&handleRatedWebTrackList);
		Slim::Web::Pages->addPageFunction('ratealbumtracksselect', \&rateAlbumTracks_web);
		Slim::Web::Pages->addPageFunction('ratealbumtracksoptions.html', \&rateAlbumTracks_web);
	}

	Slim::Menu::TrackInfo->registerInfoProvider(ratingslightrating => (
		before => 'artwork',
		func => \&trackInfoHandlerRating,
	));
	Slim::Menu::TrackInfo->registerInfoProvider(ratingslightmoreratedtracksbyartist => (
		after => 'ratingslightrating',
		before => 'ratingslightmoreratedtracksinalbum',
		func => sub {
			return objectInfoHandler('trackArtist', @_);
		},
	));
	Slim::Menu::TrackInfo->registerInfoProvider(ratingslightmoreratedtracksinalbum => (
		after => 'ratingslightrating',
		func => sub {
			return objectInfoHandler('trackAlbum', @_);
		},
	));
	Slim::Menu::ArtistInfo->registerInfoProvider(ratingslightratedtracksbyartist => (
		after => 'addartist',
		func => sub {
			return objectInfoHandler('artist', @_);
		},
	));
	Slim::Menu::AlbumInfo->registerInfoProvider(ratingslightratedtracksinalbum => (
		after => 'addalbum',
		func => sub {
			return objectInfoHandler('album', @_);
		},
	));
	Slim::Menu::AlbumInfo->registerInfoProvider(ratingslightratealbum => (
		after => 'ratingslightratedtracksinalbum',
		func => sub {
			return rateAlbumContextMenu(@_);
		},
	));
	Slim::Menu::GenreInfo->registerInfoProvider(ratingslightratedtracksingenre => (
		after => 'addgenre',
		func => sub {
			return objectInfoHandler('genre', @_);
		},
	));
	Slim::Menu::YearInfo->registerInfoProvider(ratingslightratedtracksfromyear => (
		after => 'addyear',
		before => 'ratingslightratedtracksfromdecade',
		func => sub {
			return objectInfoHandler('year', @_);
		},
	));
	Slim::Menu::YearInfo->registerInfoProvider(ratingslightratedtracksfromdecade => (
		after => 'addyear',
		func => sub {
			return objectInfoHandler('decade', @_);
		},
	));
	Slim::Menu::PlaylistInfo->registerInfoProvider(ratingslightratedtracksinplaylist => (
		after => 'addplaylist',
		func => sub {
			return objectInfoHandler('playlist', @_);
		},
	));

	initExportBaseFilePathMatrix();
	$class->SUPER::initPlugin(@_);
}

sub initPrefs {
	$prefs->init({
		rlparentfolderpath => Slim::Utils::OSDetect::dirsFor('prefs'),
		topratedminrating => 60,
		prescanbackup => 1,
		playlistimport_maxtracks => 1000,
		filetagtype => 1,
		rating_keyword_prefix => '',
		rating_keyword_suffix => '',
		backuptime => '05:28',
		backup_lastday => '',
		backupsdaystokeep => 30,
		backupfilesmin => 20,
		selectiverestore => 0,
		showratedtracksmenus => 0,
		displayratingchar => 0,
		recentlymaxcount => 30,
		ratedtracksweblimit => 80,
		ratedtrackscontextmenulimit => 80,
		dstm_minTrackDuration => 90,
		dstm_percentagerated => 30,
		dstm_percentagetoprated => 30,
		dstm_num_seedtracks => 10,
		dstm_playedtrackstokeep => 5,
		dstm_batchsizenewtracks => 20,
		postscanscheduledelay => 10,
		browsemenus_artists => 1,
		browsemenus_genres => 1,
		browsemenus_tracks => 1
	});

	createRLfolder();

	$prefs->setValidate(sub {
		return if (!$_[1] || !(-d $_[1]) || (main::ISWINDOWS && !(-d Win32::GetANSIPathName($_[1]))) || !(-d Slim::Utils::Unicode::encode_locale($_[1])));
		my $rlFolderPath = catdir($_[1], 'RatingsLight');
		eval {
			mkdir($rlFolderPath, 0755) unless (-d $rlFolderPath);
		} or do {
			$log->error("Could not create RatingsLight folder in parent folder '$_[1]'! Please make sure that LMS has read/write permissions (755) for the parent folder.");
			return;
		};
		$prefs->set('rlfolderpath', $rlFolderPath);
		return 1;
	}, 'rlparentfolderpath');

	$prefs->set('ratethisplaylistid', '');
	$prefs->set('ratethisplaylistrating', '');
	$prefs->set('exportVL_id', '');
	$prefs->set('status_exportingtoplaylistfiles', 0);
	$prefs->set('status_importingfromcommentstags', 0);
	$prefs->set('status_importingfromBPMtags', 0);
	$prefs->set('status_batchratingplaylisttracks', 0);
	$prefs->set('status_creatingbackup', 0);
	$prefs->set('status_restoringfrombackup', 0);
	$prefs->set('isTSlegacyBackupFile', 0);
	$prefs->set('status_clearingallratings', 0);
	$prefs->set('status_adjustingratings', 0);

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
	$prefs->setValidate({
		validator => sub {
			return if $_[1] =~ m|[^a-zA-Z0-9]|;
			return if $_[1] =~ m|[a-zA-Z0-9]{10,}|;
			return 1;
		}
	}, 'exportextension');
	$prefs->setValidate({
		validator => sub {
			return if $_[1] =~ m|[^a-zA-Z0-9,]|;
			return 1;
		}
	}, 'exportextensionexceptions');

	$prefs->setValidate({'validator' => 'intlimit', 'low' => 1, 'high' => 5000}, 'playlistimport_maxtracks');
	$prefs->setValidate({'validator' => \&isTimeOrEmpty}, 'backuptime');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 1, 'high' => 365}, 'backupsdaystokeep');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 1, 'high' => 100}, 'backupfilesmin');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 2, 'high' => 200}, 'recentlymaxcount');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 5, 'high' => 200}, 'ratedtracksweblimit');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 5, 'high' => 200}, 'ratedtrackscontextmenulimit');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 0, 'high' => 1800}, 'dstm_minTrackDuration');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 0, 'high' => 100}, 'dstm_percentagerated');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 0, 'high' => 100}, 'dstm_percentagetoprated');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 1, 'high' => 20}, 'dstm_num_seedtracks');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 1, 'high' => 200}, 'dstm_playedtrackstokeep');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 5, 'high' => 50}, 'dstm_batchsizenewtracks');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 5, 'high' => 600}, 'postscanscheduledelay');
	$prefs->setValidate('file', 'restorefile');

	$prefs->setChange(\&Plugins::RatingsLight::Importer::toggleUseImporter, 'autoscan');
	$prefs->setChange(\&initVLibsTimer, 'browsemenus_sourceVL_id', 'showratedtracksmenus', 'browsemenus_artists', 'browsemenus_genres', 'browsemenus_tracks');
	$prefs->setChange(\&initIR, 'enableIRremotebuttons');
	$prefs->setChange(sub {
			Slim::Music::Info::clearFormatDisplayCache();
			refreshTitleFormats();
		}, 'displayratingchar');
}

sub postinitPlugin {
	unless (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		initVirtualLibraries();
		backupScheduler();
	}

	if (Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin')) {
		require Plugins::RatingsLight::DontStopTheMusic;
		Plugins::RatingsLight::DontStopTheMusic->init();
	}

	$material_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin');
	main::DEBUGLOG && $log->is_debug && $log->debug('Plugin "Material Skin" is enabled') if $material_enabled;

	if (Slim::Utils::PluginManager->isEnabled('Plugins::MusicArtistInfo::Plugin')) {
		$MAIprefs = preferences('plugin.musicartistinfo');
	}

	# temp. workaround to allow legacy TS rating in iPeng until iPeng supports RL or is discontinued
	if ($prefs->get('enableipengtslegacyrating') && !Slim::Utils::PluginManager->isEnabled('Plugins::TrackStat::Plugin')) {
		Slim::Control::Request::addDispatch(['trackstat', 'getrating', '_trackid'], [0, 1, 0, \&getRatingTSLegacy]);
		Slim::Control::Request::addDispatch(['trackstat', 'setrating', '_trackid', '_rating', '_incremental'], [1, 0, 1, \&setRating]);
		Slim::Control::Request::addDispatch(['trackstat', 'setratingpercent', '_trackid', '_rating', '_incremental'], [1, 0, 1, \&setRating]);
		Slim::Control::Request::addDispatch(['trackstat', 'changedrating', '_url', '_trackid', '_rating', '_ratingpercent'],[0, 0, 0, undef]);
	}
}


### set ratings

sub setRating {
	my $request = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug('request params = '.Data::Dump::dump($request->getParamsCopy()));
	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: access to rating values blocked until library scan is completed');
		return;
	}

	if ($request->isNotCommand([['ratingslight'],['setrating']]) && $request->isNotCommand([['ratingslight'],['setratingpercent']]) && $request->isNotCommand([['trackstat'],['setrating']]) && $request->isNotCommand([['trackstat'],['setratingpercent']])) {
		$request->setStatusBadDispatch();
		$log->warn('incorrect command');
		return;
	}

	if (($request->isCommand([['trackstat'],['setrating']]) || $request->isCommand([['trackstat'],['setratingpercent']])) && $request->source !~ /iPeng/) {
		$request->setStatusBadDispatch();
		$log->warn('TS legacy rating is only available for iPeng clients as a temp. workaround. Please use the correct ratingslight dispatch instead.');
		return;
	}

	my $client = $request->client();
	if (!defined $client) {
		$request->setStatusNeedsClient();
		return;
	}

	my $ratingScale;
	if ($request->isCommand([['ratingslight'],['setratingpercent']]) || $request->isCommand([['trackstat'],['setratingpercent']])) {
		$ratingScale = "percent";
	}

	my $trackID = $request->getParam('_trackid');
	if (defined($trackID) && $trackID =~ /^track_id:(.*)$/) {
		$trackID = $1;
	} elsif (defined($request->getParam('_trackid'))) {
		$trackID = $request->getParam('_trackid');
	} else {
		$log->error("Can't set rating. No (valid) track ID found. Provided track ID was ".Data::Dump::dump($trackID));
		return;
	}

	my $rating = $request->getParam('_rating');
	if (defined($rating) && $rating =~ /^rating:(.*)$/) {
		$rating = ratingValidator($1, $ratingScale);
	} elsif (defined($request->getParam('_rating'))) {
		$rating = ratingValidator($request->getParam('_rating'), $ratingScale);
	} else {
		$log->error("Can't set rating. No (valid) rating value found.");
		return;
	}
	return if !defined($rating);

	my $incremental = $request->getParam('_incremental');
	if (defined($incremental) && $incremental =~ /^incremental:(.*)$/) {
		$incremental = $1;
	} elsif (defined($request->getParam('_incremental'))) {
		$incremental = $request->getParam('_incremental');
	}

	if (!defined $trackID || $trackID eq '' || !defined $rating || $rating eq '') {
		$request->setStatusBadParams();
		return;
	}

	my $track = Slim::Schema->resultset('Track')->find($trackID);
	my $trackURL = $track->url;

	# check if remote track is part of online library
	if ((Slim::Music::Info::isRemoteURL($trackURL) == 1) && (!defined($track->extid))) {
		$log->warn("Can't set rating. Track is remote but not part of LMS library. Track URL: ".$trackURL);
		return;
	}

	# check for dead/moved local tracks
	if ((Slim::Music::Info::isRemoteURL($trackURL) != 1) && (!defined($track->filesize))) {
		$log->error("Can't set rating. Track dead or moved? Track URL: ".$trackURL);
		return;
	}

	my $rating100ScaleValue = 0;

	if (defined($incremental) && (($incremental eq '+') || ($incremental eq '-'))) {
		my $currentrating = $track->rating;
		if (!defined $currentrating) {
			$currentrating = 0;
		}
		if ($incremental eq '+') {
			if (!defined($ratingScale)) {
				$rating100ScaleValue = $currentrating + int($rating * 20);
			} else {
				$rating100ScaleValue = $currentrating + int($rating);
			}
		} elsif ($incremental eq '-') {
			if (!defined($ratingScale)) {
				$rating100ScaleValue = $currentrating - int($rating * 20);
			} else {
				$rating100ScaleValue = $currentrating - int($rating);
			}
		}
	} else {
		if (!defined($ratingScale)) {
			$rating100ScaleValue = int($rating * 20);
		} else {
			$rating100ScaleValue = $rating;
		}
	}
	$rating100ScaleValue = ratingSanityCheck($rating100ScaleValue);

	writeRatingToDB($trackID, undef, undef, $track, $rating100ScaleValue);

	Slim::Control::Request::notifyFromArray($client, ['ratingslight', 'changedrating', $trackURL, $trackID, $rating100ScaleValue/20, $rating100ScaleValue]);
	Slim::Control::Request::notifyFromArray(undef, ['ratingslightchangedratingupdate', $trackURL, $trackID, $rating100ScaleValue/20, $rating100ScaleValue]);

	$request->addResult('rating', $rating100ScaleValue/20);
	$request->addResult('ratingpercentage', $rating100ScaleValue);
	$request->setStatusDone();
	refreshAll();
}

sub VFD_deviceRating {
	my ($client, $callback, $params, $trackID, $trackURL, $track, $rating100ScaleValue) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('trackID = '.$trackID.' ## trackURL = '.$trackURL.' ## rating = '.$rating100ScaleValue.' ## callback = '.Data::Dump::dump($callback));

	$track = Slim::Schema->resultset('Track')->find($trackID) if (!$track && defined($trackID));
	$track = Slim::Schema->rs('Track')->objectForUrl($trackURL) if (!$track && defined($trackURL));

	# check if remote track is part of online library
	if ((Slim::Music::Info::isRemoteURL($track->url) == 1) && (!defined($track->extid))) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Track is remote but not part of LMS library. Track URL: '.$track->url);
		return;
	}

	# check for dead/moved local tracks
	if ((Slim::Music::Info::isRemoteURL($track->url) != 1) && (!defined($track->filesize))) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Track dead or moved??? Track URL: '.$track->url);
		return;
	}
	writeRatingToDB($trackID, $track->url, undef, $track, $rating100ScaleValue);

	my $cbtext = string('PLUGIN_RATINGSLIGHT_RATING').' '.(getRatingTextLine($rating100ScaleValue));
	if ($callback) {
		$callback->([{
			type => 'text',
			name => $cbtext,
			showBriefly => 1, popback => 3,
			favorites => 0, refresh => 1
		}]);
	} else {
		$client->showBriefly({
			'line' => [string('PLUGIN_RATINGSLIGHT_TRACK_RATED'), $cbtext]
		}, 3);
	}
	Slim::Control::Request::notifyFromArray($client, ['ratingslight', 'changedrating', $track->url, $trackID, $rating100ScaleValue/20, $rating100ScaleValue]);
	Slim::Control::Request::notifyFromArray(undef, ['ratingslightchangedratingupdate', $track->url, $trackID, $rating100ScaleValue/20, $rating100ScaleValue]);
	refreshAll();
}

# rate album tracks
sub rateAlbumContextMenu {
	my ($client, $url, $obj, $remoteMeta, $tags) = @_;
	$tags ||= {};

	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: not available until library scan is completed');
		return;
	}

	my $albumID = $obj->id;
	my $albumName = $obj->name;
	$albumName = trimStringLength($albumName, 70);
	main::DEBUGLOG && $log->is_debug && $log->debug('album id = '.$albumID.' ## objectName = '.Data::Dump::dump($albumName));

	if ($tags->{menuMode}) {
		return {
			type => 'redirect',
			name => string('PLUGIN_RATINGSLIGHT_RATEALBUM'),
			jive => {
				actions => {
					go => {
						player => 0,
						cmd => ['ratingslight', 'ratealbumoptions', $albumID, $albumName],
					},
				}
			},
			favorites => 0,
		};
	} else {
		return {
			type => 'redirect',
			name => $client->string('PLUGIN_RATINGSLIGHT_RATEALBUM'),
			favorites => 0,
			web => {
				url => 'plugins/RatingsLight/html/ratealbumtracksselect?albumid='.$albumID.'&albumname='.$albumName
			},
		};
	}
}

sub rateAlbumTracks_web {
	my ($client, $params, $callback, $httpClient, $response) = @_;

	my $usehalfstarratings = $prefs->get('usehalfstarratings');
	my $albumID = $params->{albumid};
	my $albumName = $params->{albumname};
	main::DEBUGLOG && $log->is_debug && $log->debug('albumID = '.$albumID.' ## albumName = '.Data::Dump::dump($albumName));

	$params->{albumid} = $albumID;
	$params->{albumname} = $albumName;

	my @ratingValues = ();
	if (defined $usehalfstarratings) {
		@ratingValues = qw(100 90 80 70 60 50 40 30 20 10 0);
	} else {
		@ratingValues = qw(100 80 60 40 20 0);
	}
	$params->{'ratingvalues'} = \@ratingValues;

	my $ratingStrings = {};
	foreach my $rating100ScaleValue (@ratingValues) {
		$ratingStrings->{$rating100ScaleValue} = getRatingTextLine($rating100ScaleValue);
	}
	$params->{'ratingstrings'} = $ratingStrings;

	my $albumRatingValue = $params->{'albumratingvalue'};
	if (defined($albumRatingValue)) {
		my $unratedOnly = $params->{'unratedonly'};
		main::DEBUGLOG && $log->is_debug && $log->debug('albumRatingValue = '.$albumRatingValue.' ## unratedOnly = '.Data::Dump::dump($unratedOnly));
		my $ratingSuccess = rateAlbum($albumID, $albumRatingValue, $unratedOnly);
		if (!$ratingSuccess) {
			$params->{'failed'} = 1;
		} else {
			$params->{'albumrated'} = 1;
		}
	}
	return Slim::Web::HTTP::filltemplatefile('plugins/RatingsLight/html/ratealbumtracksoptions.html', $params);
}

sub rateAlbumTracksOptions_jive {
	my $request = shift;
	my $client = $request->client();

	if (!$request->isQuery([['ratingslight'],['ratealbumoptions']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('client required!');
		$request->setStatusNeedsClient();
		return;
	}
	my $albumID = $request->getParam('_albumid');
	main::DEBUGLOG && $log->is_debug && $log->debug('albumID = '.Data::Dump::dump($albumID));
	return unless $albumID;

	$request->addResult('window', {text => string('PLUGIN_RATINGSLIGHT_RATEALBUM_OPTIONS')});

	my @ratingOptions = (string('PLUGIN_RATINGSLIGHT_RATEALBUM_OPTIONS_ALL'), string('PLUGIN_RATINGSLIGHT_RATEALBUM_OPTIONS_UNRATED'));

	my $cnt = 0;
	foreach (@ratingOptions) {
		my $action = {
			'go' => {
				'player' => 0,
				'cmd' => ['ratingslight', 'ratingmenu', $albumID, 1, $cnt],
			},
		};

		$request->addResultLoop('item_loop', $cnt, 'text', $_);
		$request->addResultLoop('item_loop', $cnt, 'style', 'itemNoAction');
		$request->addResultLoop('item_loop', $cnt, 'type', 'redirect');
		$request->addResultLoop('item_loop', $cnt, 'actions', $action);
		$cnt++;
	}

	$request->addResult('offset', 0);
	$request->addResult('count', $cnt);
	$request->setStatusDone();
}

sub rateAlbumTracks_jive {
	my $request = shift;
	my $client = $request->client();

	if (!$request->isQuery([['ratingslight'],['ratealbum']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('client required!');
		$request->setStatusNeedsClient();
		return;
	}
	my $albumID = $request->getParam('_albumid');
	my $albumRatingValue = $request->getParam('_rating');
	main::DEBUGLOG && $log->is_debug && $log->debug('albumID = '.$albumID.' ## albumRatingValue = '.$albumRatingValue);
	return unless $albumID && $albumRatingValue;
	my $unratedOnly = $request->getParam('_unratedonly');

	my $ratingSuccess = rateAlbum($albumID, $albumRatingValue, $unratedOnly);
	my $message = '';
	if ($ratingSuccess) {
		$message = string('PLUGIN_RATINGSLIGHT_RATEALBUM_SUCCESS');
	} else {
		$message = string('PLUGIN_RATINGSLIGHT_RATEALBUM_FAILED');
	}

	if (Slim::Buttons::Common::mode($client) !~ /^SCREENSAVER./) {
		$client->showBriefly({'line' => [string('PLUGIN_RATINGSLIGHT'), $message]}, 5);
	}
	if ($material_enabled) {
		Slim::Control::Request::executeRequest(undef, ['material-skin', 'send-notif', 'type:info', 'msg:'.$message, 'client:'.$client->id, 'timeout:5']);
	}
	$request->setStatusDone();
}

sub rateAlbum {
	my ($albumID, $albumRatingValue, $unratedOnly) = @_;

	my $album = Slim::Schema->resultset('Album')->single({'id' => $albumID});
	my @albumTracks = $album->tracks;

	if (scalar @albumTracks > 0) {
		foreach (@albumTracks) {
			if ($unratedOnly) {
				my $curTrackRating = $_->rating || 0;
				if ($curTrackRating > 0) {
					main::DEBUGLOG && $log->is_debug && $log->debug('Not rating already rated track "'.$_->title.'"');
					next;
				}
			}
			main::DEBUGLOG && $log->is_debug && $log->debug('Setting rating of track "'.$_->title.'" to '.$albumRatingValue);
			writeRatingToDB($_->id, undef, undef, $_, $albumRatingValue);
		}
	}
	refreshAll();
	return 1;
}


### rating menu

sub trackInfoHandlerRating {
	my ($client, $url, $track, $remoteMeta, $tags) = @_;
	my $rating100ScaleValue = 0;
	my $usehalfstarratings = $prefs->get('usehalfstarratings');
	my $text = string('PLUGIN_RATINGSLIGHT_RATING');
	$tags ||= {};

	if (Slim::Music::Import->stillScanning) {
		if ($tags->{menuMode}) {
			return {
				type => 'text',
				name => $text.' '.string('PLUGIN_RATINGSLIGHT_BLOCKED'),
				jive => {},
			};
		} else {
			return {
				type => 'text',
				name => $text.' '.string('PLUGIN_RATINGSLIGHT_BLOCKED'),
			};
		}
	}

	# check if remote track is part of online library
	if ((Slim::Music::Info::isRemoteURL($url) == 1) && (!defined($track->extid))) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Track is remote but not part of LMS library. Track URL: '.$url);
		return;
	}

	# check for dead/moved local tracks
	if ((Slim::Music::Info::isRemoteURL($url) != 1) && (!defined($track->filesize))) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Track dead or moved??? Track URL: '.$url);
		return;
	}

	$rating100ScaleValue = getRatingFromDB($track);
	$text = string('PLUGIN_RATINGSLIGHT_RATING').' '.(getRatingTextLine($rating100ScaleValue));

	if ($tags->{menuMode}) {
		return {
			type => 'redirect',
			name => $text,
			jive => {
				actions => {
					go => {
						player => 0,
						cmd => ['ratingslight', 'ratingmenu', $track->id],
					},
				}
			},
		};
	} else {
		my $item = {
			type => 'text',
			name => $text,
			itemvalue => $rating100ScaleValue,
			usehalfstars => $usehalfstarratings,
			itemid => $track->id,
			web => {
				'type' => 'htmltemplate',
				'value' => 'plugins/RatingsLight/html/trackratinginfo.html'
			},
		};

		delete $item->{type};
		my @ratingValues = ();
		if ($usehalfstarratings) {
			@ratingValues = qw(100 90 80 70 60 50 40 30 20 10 0);
		} else {
			@ratingValues = qw(100 80 60 40 20 0);
		}

		my @items = ();
		foreach my $ratingValue (@ratingValues) {
			push(@items,
			{
				name => getRatingTextLine($ratingValue),
				url => \&VFD_deviceRating,
				passthrough => [$track->id, $url, $track, $ratingValue],
			});
		}
		$item->{items} = \@items;
		return $item;
	}
}

sub getRatingMenu {
	my $request = shift;
	my $client = $request->client();
	my $usehalfstarratings = $prefs->get('usehalfstarratings');

	if (!$request->isQuery([['ratingslight'],['ratingmenu']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('client required');
		$request->setStatusNeedsClient();
		return;
	}
	my $track_id = $request->getParam('_trackid');

	my $isAlbum = $request->getParam('_isalbum');
	main::DEBUGLOG && $log->is_debug && $log->debug('isAlbum = '.Data::Dump::dump($isAlbum));
	my $albumID = $track_id;

	my $cnt = 0;

	my @ratingValues = ();
	if (defined $usehalfstarratings) {
		@ratingValues = qw(100 90 80 70 60 50 40 30 20 10 0);
	} else {
		@ratingValues = qw(100 80 60 40 20 0);
	}

	if ($isAlbum) {
		my $windowTitle = string('PLUGIN_RATINGSLIGHT_RATEALBUM');
		$request->addResult('window', {text => $windowTitle});

		my $unratedOnly = $request->getParam('_unratedonly');
		main::DEBUGLOG && $log->is_debug && $log->debug('unratedOnly = '.Data::Dump::dump($unratedOnly));

		foreach my $rating100ScaleValue (@ratingValues) {
			my $actions = {
				'do' => {
					'cmd' => ['ratingslight', 'ratealbum', $albumID, $rating100ScaleValue, $unratedOnly]
				},
				'play' => {
					'cmd' => ['ratingslight', 'ratealbum', $albumID, $rating100ScaleValue, $unratedOnly]
				},
			};

			my $text = getRatingTextLine($rating100ScaleValue);
			$request->addResultLoop('item_loop', $cnt, 'text', $text);
			$request->addResultLoop('item_loop', $cnt, 'actions', $actions);
			$request->addResultLoop('item_loop', $cnt, 'nextWindow', 'grandparent');

			$cnt++;
		}

	} else {
		foreach my $rating100ScaleValue (@ratingValues) {
			my $actions = {
				'do' => {
					'cmd' => ['ratingslight', 'setratingpercent', $track_id, $rating100ScaleValue]
				},
				'play' => {
					'cmd' => ['ratingslight', 'setratingpercent', $track_id, $rating100ScaleValue]
				},
			};

			my $text = getRatingTextLine($rating100ScaleValue);
			$request->addResultLoop('item_loop', $cnt, 'text', $text);
			$request->addResultLoop('item_loop', $cnt, 'actions', $actions);
			$request->addResultLoop('item_loop', $cnt, 'nextWindow', 'parent');
			$cnt++;
		}
	}

	$request->addResult('offset', 0);
	$request->addResult('count', $cnt);
	$request->setStatusDone();
}


### common subs

sub objectInfoHandler {
	my ($objectType, $client, $url, $obj, $remoteMeta, $tags) = @_;
	$tags ||= {};
	main::DEBUGLOG && $log->is_debug && $log->debug('objectType = '.$objectType.' ## url = '.Data::Dump::dump($url));
	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: not available until library scan is completed');
		return;
	}

	my $trackID = 0;
	my $vfd = 0;
	my $objectID = $obj->id unless ($objectType eq 'year' || $objectType eq 'decade');
	my $objectName;
	if ($objectType eq 'year' || $objectType eq 'decade') {
		$objectName = "".$obj;
	} else {
		$objectName = $obj->name;
	}
	my $curTrackRating = 0;

	if (($objectType eq 'trackAlbum') || ($objectType eq 'trackArtist')) {
		# check if remote track is part of online library
		if ((Slim::Music::Info::isRemoteURL($url) == 1) && (!defined($obj->extid))) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Track is remote but not part of LMS library. Track URL: '.$url);
			return;
		}

		# check for dead/moved local tracks
		if ((Slim::Music::Info::isRemoteURL($url) != 1) && (!defined($obj->filesize))) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Track dead or moved??? Track URL: '.$url);
			return;
		}
	}
	my $menuItemTitlePrefixString;

	if ($objectType eq 'trackAlbum') {
		$objectType = 'album';
		$trackID = $objectID;
		if ($obj->album) {
			$objectID = $obj->album->id;
		} else {
			main::DEBUGLOG && $log->is_debug && $log->debug('Track has no album. Cannot retrieve album id.');
			return;
		}
		$objectName = $obj->album->name;
		$curTrackRating = getRatingFromDB($obj);
		$vfd = 1;
	}

	if ($objectType eq 'trackArtist') {
		$objectType = 'artist';
		$trackID = $objectID;
		if ($obj->artist) {
			$objectID = $obj->artist->id;
		} else {
			main::DEBUGLOG && $log->is_debug && $log->debug('Track has no artist. Cannot retrieve artist id.');
			return;
		}
		$objectName = $obj->artist->name;
		$curTrackRating = getRatingFromDB($obj);
		$vfd = 1;
	}
	$objectName = trimStringLength($objectName, 70);

	if ($objectType eq 'album') {
		$menuItemTitlePrefixString = $curTrackRating > 0 ? string('PLUGIN_RATINGSLIGHT_MENUS_MORERATEDTRACKSINALBUM') : string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKSINALBUM');
	}
	if ($objectType eq 'artist') {
		$objectName = trimStringLength($objectName, 50);
		$menuItemTitlePrefixString = $curTrackRating > 0 ? string('PLUGIN_RATINGSLIGHT_MENUS_MORERATEDTRACKSBYARTIST') : string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKSBYARTIST');
	}
	if ($objectType eq 'genre') {
		$menuItemTitlePrefixString = string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKSINGENRE');
	}
	if ($objectType eq 'year') {
		$menuItemTitlePrefixString = string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKSFROMYEAR');
		$objectID = $obj;
	}
	if ($objectType eq 'decade') {
		$menuItemTitlePrefixString = string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKSFROMDECADE');
		$objectID = floor($obj/10) * 10 + 0;
		$objectName = $objectID.'s';
	}
	if ($objectType eq 'playlist') {
		$menuItemTitlePrefixString = string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKSINPLAYLIST');
	}

	my $menuItemTitle = $menuItemTitlePrefixString.' '.$objectName;
	my $trackCount = getRatedTracks(1, $client, $objectType, $objectID, $trackID, undef);

	if ($trackCount > 0) {
		if ($tags->{menuMode}) {
			return {
				type => 'redirect',
				name => $menuItemTitle,
				jive => {
					actions => {
						go => {
							player => 0,
							cmd => ['ratingslight', 'ratedtracksmenu', $trackID, $objectID, $objectType],
						},
					}
				},
				favorites => 0,
			};
		} else {
			my $item = {
				type => 'text',
				name => $menuItemTitlePrefixString.' '.$objectName,
				prefix => $menuItemTitlePrefixString,
				objectname => $objectName,
				objecttype => $objectType,
				objectid => $objectID,
				trackid => $trackID,
				titlemore => ($curTrackRating > 0 ? 'more' : undef),
				web => {
					'type' => 'htmltemplate',
					'value' => 'plugins/RatingsLight/html/showratedtracks.html'
				},
			};

			if ($vfd == 1) {
				delete $item->{type};
				my @items = ();
				my $ratedsongs = VFD_ratedtracks($client, $objectType, $objectID, $trackID);
				$item->{items} = \@{$ratedsongs};
			}
			return $item;
		}
	} else {
		return;
	}
}

sub getRatedTracks {
	my ($countOnly, $client, $objectType, $objectID, $currentTrackID, $listlimit) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('objectType = '.$objectType.' ## countOnly = '.$countOnly.' ## trackID = '.$currentTrackID.' ## thisID = '.$objectID);

	my %validObjectTypes = map {$_ => 1} ('artist', 'album', 'genre', 'year', 'decade', 'playlist');

	unless ($validObjectTypes{$objectType}) {
		$log->warn('No valid objectType');
		return 0;
	}

	my $ratedtrackscontextmenulimit = $prefs->get('ratedtrackscontextmenulimit');
	my $currentLibrary = Slim::Music::VirtualLibraries->getLibraryIdForClient($client);
	my $sqlstatement = ($countOnly == 1 ? "select count(*)" : "select tracks.id")." from tracks";

	if ((defined $currentLibrary) && ($currentLibrary ne '')) {
		$sqlstatement .= " join library_track on library_track.track = tracks.id and library_track.library = \"$currentLibrary\"";
	}

	$sqlstatement .= " join genre_track on genre_track.track = tracks.id and genre_track.genre = $objectID" if ($objectType eq 'genre');

	$sqlstatement .= " join playlist_track on playlist_track.track = tracks.url and playlist_track.playlist = $objectID" if ($objectType eq 'playlist');

	$sqlstatement .= " join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 where tracks.audio = 1 and tracks.id != $currentTrackID";

	$sqlstatement .= " and tracks.primary_artist = $objectID" if ($objectType eq 'artist');

	$sqlstatement .= " and tracks.album = $objectID" if ($objectType eq 'album');

	$sqlstatement .= " and tracks.year >= $objectID and tracks.year < ($objectID + 10)" if ($objectType eq 'decade');

	$sqlstatement .= " and tracks.year = $objectID" if ($objectType eq 'year');

	if ($countOnly == 0) {
		$sqlstatement .= " limit $listlimit" if ($objectType eq 'artist' || $objectType eq 'album' || $objectType eq 'playlist');

		$sqlstatement .= " order by random() limit $listlimit" if ($objectType eq 'genre' || $objectType eq 'year' || $objectType eq 'decade');
	}

	my @ratedtracks = ();
	my $trackCount = 0;
	my $dbh = Slim::Schema->dbh;
	eval{
		my $sth = $dbh->prepare($sqlstatement);
		$sth->execute() or do {$sqlstatement = undef;};

		if ($countOnly == 1) {
			$trackCount = $sth->fetchrow;
		} else {
			my ($trackID, $track);
			$sth->bind_col(1,\$trackID);

			while ($sth->fetch()) {
				$track = Slim::Schema->resultset('Track')->single({'id' => $trackID});
				push @ratedtracks, $track;
			}
		}
		$sth->finish();
	};
	if ($@) {main::DEBUGLOG && $log->is_debug && $log->debug("error: $@");}

	if ($countOnly == 1) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Pre-check found '.$trackCount.($trackCount == 1 ? ' rated track' : ' rated tracks')." for $objectType with ID: $objectID");
		return $trackCount;
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug('Fetched '.scalar (@ratedtracks).(scalar (@ratedtracks) == 1 ? ' rated track' : ' rated tracks')." for $objectType with ID: $objectID");
		return \@ratedtracks;
	}
}


### show rated tracks menus - WEB

sub handleRatedWebTrackList {
	my ($client, $params, $callback, $httpClient, $response) = @_;
	my $ratedtracksweblimit = $prefs->get('ratedtracksweblimit');

	## execute action if action and action track id(s) provided
	my $action = $params->{'action'};
	main::DEBUGLOG && $log->is_debug && $log->debug('action = '.Data::Dump::dump($action));
	my $actionTrackIDs = $params->{'actiontrackids'};
	main::DEBUGLOG && $log->is_debug && $log->debug('actionTrackIDs = '.Data::Dump::dump($actionTrackIDs));

	if ($action && ($action eq 'load' || $action eq 'insert' || $action eq 'add') && $actionTrackIDs) {
		$client->execute(['playlistcontrol', 'cmd:'.$action, 'track_id:'.$actionTrackIDs]);
	}

	my $trackID = $params->{trackid} || 0;
	my $objectType = $params->{objecttype};
	my $objectID = $params->{objectid};
	my $objectName = $params->{objectname};
	main::DEBUGLOG && $log->is_debug && $log->debug('objectType = '.$objectType.' ## objectID = '.$objectID.' ## trackID = '.$trackID);

	my $ratedtracks = getRatedTracks(0, $client, $objectType, $objectID, $trackID, $ratedtracksweblimit);

	my @ratedtracks_webpage = ();
	my @alltrackids = ();

	foreach my $ratedtrack (@{$ratedtracks}) {
		my $track_id = $ratedtrack->id;
		my $tracktitle = trimStringLength($ratedtrack->title, 70);
		my $rating100ScaleValue = getRatingFromDB($ratedtrack);
		my $ratingtext = getRatingTextLine($rating100ScaleValue, 'appended');
		$tracktitle = $tracktitle.$ratingtext;
		my $artworkID = $ratedtrack->album->artwork;

		if ($objectType eq 'album') {
			my $artistname = $ratedtrack->artist->name;
			$artistname = trimStringLength($artistname, 80);
			my $artistID = $ratedtrack->artist->id;
			push (@ratedtracks_webpage, {trackid => $track_id, tracktitle => $tracktitle, artistname => $artistname, artistID => $artistID, artworkid => $artworkID});
		} elsif ($objectType eq 'artist') {
			my $albumname = $ratedtrack->album->name;
			$albumname = trimStringLength($albumname, 80);
			my $albumID = $ratedtrack->album->id;
			push (@ratedtracks_webpage, {trackid => $track_id, tracktitle => $tracktitle, albumname => $albumname, albumID => $albumID, artworkid => $artworkID});
		} elsif (($objectType eq 'genre') || ($objectType eq 'year') || ($objectType eq 'decade') || ($objectType eq 'playlist')) {
			my $artistname = $ratedtrack->artist->name;
			$artistname = trimStringLength($artistname, 80);
			my $artistID = $ratedtrack->artist->id;
			my $albumname = $ratedtrack->album->name;
			$albumname = trimStringLength($albumname, 80);
			my $albumID = $ratedtrack->album->id;
			push (@ratedtracks_webpage, {trackid => $track_id, tracktitle => $tracktitle, artistname => $artistname, artistID => $artistID, albumname => $albumname, albumID => $albumID, artworkid => $artworkID});
		}
		push @alltrackids, $track_id;
	}
	my $listalltrackids = join (',', @alltrackids);

	my $listheadername;
	if ($objectType eq 'album') {
		$listheadername = (@{$ratedtracks})[0]->album->name;
	} elsif ($objectType eq 'artist') {
		$listheadername = (@{$ratedtracks})[0]->artist->name;
	} elsif ($objectType eq 'genre') {
		$listheadername = (@{$ratedtracks})[0]->genre->name;
	} elsif ($objectType eq 'year') {
		$listheadername = ''.(@{$ratedtracks})[0]->year;
	} elsif ($objectType eq 'decade') {
		$listheadername = (floor(((@{$ratedtracks})[0]->year)/10) * 10 + 0).'s';
	} elsif ($objectType eq 'playlist') {
		$listheadername = $objectName || 'this playlist';
	}

	$listheadername = trimStringLength($listheadername, 50);
	$params->{listheadername} = $listheadername;

	$params->{trackcount} = scalar(@ratedtracks_webpage);
	$params->{alltrackids} = $listalltrackids;
	$params->{ratedtracks} = \@ratedtracks_webpage;
	return Slim::Web::HTTP::filltemplatefile('plugins/RatingsLight/html/showratedtrackslist.html', $params);
}


### show rated tracks menus - JIVE

sub getRatedTracksMenu {
	my $ratedtrackscontextmenulimit = $prefs->get('ratedtrackscontextmenulimit');
	my $request = shift;
	my $client = $request->client();

	if (!$request->isQuery([['ratingslight'],['ratedtracksmenu']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('client required!');
		$request->setStatusNeedsClient();
		return;
	}
	my $trackID = $request->getParam('_trackid') || 0;
	my $thisID = $request->getParam('_thisid');
	my $objectType = $request->getParam('_objecttype');;
	main::DEBUGLOG && $log->is_debug && $log->debug('objectType = '.$objectType.' ## thisID = '.$thisID.' ## trackID = '.$trackID);

	my $ratedtracks = getRatedTracks(0, $client, $objectType, $thisID, $trackID, $ratedtrackscontextmenulimit);

	my %menuStyle = ();
	$menuStyle{'titleStyle'} = 'mymusic';
	$menuStyle{'menuStyle'} = 'album';
	$menuStyle{'windowStyle'} = 'icon_list';
	$request->addResult('window',\%menuStyle);

	my $cnt = 0;
	my $trackCount = scalar(@{$ratedtracks});
	if ($trackCount > 1) {
		$cnt = 1;
	}
	my @alltrackids = ();

	foreach my $ratedtrack (@{$ratedtracks}) {
		$request->addResultLoop('item_loop',$cnt,'icon-id',$ratedtrack->coverid);
		push @alltrackids, $ratedtrack->id;

		my ($tracktitle, $ratingtext, $returntext) = '';
		my $rating100ScaleValue = getRatingFromDB($ratedtrack);
		$ratingtext = getRatingTextLine($rating100ScaleValue, 'appended');
		$tracktitle = trimStringLength($ratedtrack->title, 60);

		if ($objectType eq 'album') {
			my $artistname = $ratedtrack->artist->name;
			$artistname = trimStringLength($artistname, 70);
			$returntext = $tracktitle.$ratingtext."\n".$artistname;
		} elsif ($objectType eq 'artist') {
			my $albumname = $ratedtrack->album->name;
			$albumname = trimStringLength($albumname, 70);
			$returntext = $tracktitle.$ratingtext."\n".$albumname;
		} else {
			my $sepchar = HTML::Entities::decode_entities('&#x2022;'); # "bullet" - HTML Entity (hex): &#x2022;
			my $artistname = $ratedtrack->artist->name;
			$artistname = trimStringLength($artistname, 70);
			my $albumname = $ratedtrack->album->name;
			$albumname = trimStringLength($albumname, 70);
			$returntext = $tracktitle.$ratingtext."\n".$artistname.' '.$sepchar.' '.$albumname;
		}

		my $actions = {
			'go' => {
				'player' => 0,
				'cmd' => ['ratingslight', 'actionsmenu', 'track_id:'.$ratedtrack->id, 'allsongs:0'],
			},
		};

		$request->addResultLoop('item_loop', $cnt, 'type', 'redirect');
		$request->addResultLoop('item_loop', $cnt, 'actions', $actions);
		$request->addResultLoop('item_loop', $cnt, 'text', $returntext);
		$cnt++;
	}

	if ($trackCount > 1) {
		my $listalltrackids = join (',', @alltrackids);
		my $actions = {
			'go' => {
				'player' => 0,
				'cmd' => ['ratingslight', 'actionsmenu', 'track_id:'.$listalltrackids, 'allsongs:1'],
			},
		};
		$request->addResultLoop('item_loop', 0, 'type', 'redirect');
		$request->addResultLoop('item_loop', 0, 'actions', $actions);
		$request->addResultLoop('item_loop', 0, 'icon', 'plugins/RatingsLight/html/images/coverplaceholder.png');
		$request->addResultLoop('item_loop', 0, 'text', string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_ALLSONGS').' ('.$trackCount.')');
		$cnt++;
	}

	$request->addResult('offset', 0);
	$request->addResult('count', $cnt);
	$request->setStatusDone();
}

sub getActionsMenu {
	my $request = shift;
	if (!$request->isQuery([['ratingslight'],['actionsmenu']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}

	my $trackID = $request->getParam('track_id');
	my $allsongs = $request->getParam('allsongs');

	$request->addResult('window', {
		menustyle => 'album',
	});

	my $actionsmenuitems = [
		{
			itemtext => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNOW'),
			itemcmd1 => 'playlistcontrol',
			itemcmd2 => 'load'
		},
		{
			itemtext => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNEXT'),
			itemcmd1 => 'playlistcontrol',
			itemcmd2 => 'insert'
		},
		{
			itemtext => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_APPEND'),
			itemcmd1 => 'playlistcontrol',
			itemcmd2 => 'add'
		},
		{
			itemtext => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_MOREINFO'),
			itemcmd1 => 'trackinfo',
			itemcmd2 => 'items'
		}];

	my $cnt = 0;
	foreach my $menuitem (@{$actionsmenuitems}) {
		my $menuitemtext = $menuitem->{'itemtext'};
		my $menuitemcmd1 = $menuitem->{'itemcmd1'};
		my $menuitemcmd2 = $menuitem->{'itemcmd2'};
		my $actions;

		unless (($menuitemcmd1 eq 'trackinfo') && ($allsongs == 1)) {
			my $thisitem->{'actionParam'} = 'track_id';

			if ($menuitemcmd1 eq 'trackinfo') {
				my %itemParams = (
					'track_id' => $trackID,
					'menu' => 1,
					'usecontextmenu' => 1,
				);
				$actions = {
					'player' => 0,
					'go' => {
						'cmd' => [$menuitemcmd1, $menuitemcmd2],
						'params' => {
							'menu' => 1,
							$thisitem->{'actionParam'} => $trackID,
						},
					},
					'player' => 0,
					'play' => {
						'cmd' => [$menuitemcmd1, $menuitemcmd2],
						'params' => {
							'menu' => 1,
							$thisitem->{'actionParam'} => $trackID,
						},
					}
				};
			} else {
				$actions = {
					'player' => 0,
					'go' => {
						'cmd' => [$menuitemcmd1, 'cmd:'.$menuitemcmd2, 'track_id:'.$trackID],
					},
					'player' => 0,
					'play' => {
						'cmd' => [$menuitemcmd1, 'cmd:'.$menuitemcmd2, 'track_id:'.$trackID],
					}
				};
				$request->addResultLoop('item_loop',$cnt,'nextWindow','parent');
			}

			$request->addResultLoop('item_loop',$cnt,'actions',$actions);
			$request->addResultLoop('item_loop',$cnt,'text',$menuitemtext);
			$request->addResultLoop('item_loop',$cnt,'style', 'itemplay') unless $menuitemcmd1 eq 'trackinfo';
			$cnt++;
		}
	}
	$request->addResult('offset',0);
	$request->addResult('count',$cnt);
	$request->setStatusDone();
}


### show rated tracks menus - VF devices
# only objectType trackArtist + trackAlbum

sub VFD_ratedtracks {
	my ($client, $objectType, $thisID, $trackID) = @_;
	my $ratedtrackscontextmenulimit = $prefs->get('ratedtrackscontextmenulimit');
	main::DEBUGLOG && $log->is_debug && $log->debug('objectType = '.$objectType.' ## thisID = '.$thisID.' ## trackID = '.$trackID);

	my $ratedtracks = getRatedTracks(0, $client, $objectType, $thisID, $trackID, $ratedtrackscontextmenulimit);
	my @vfd_ratedtracks = ();
	my @alltrackids = ();

	foreach my $ratedtrack (@{$ratedtracks}) {
		my $track_id = $ratedtrack->id;
		push @alltrackids, $track_id;
		my $tracktitle = $ratedtrack->title;
		$tracktitle = trimStringLength($tracktitle, 70);

		my $rating100ScaleValue = getRatingFromDB($ratedtrack);
		my $ratingtext = getRatingTextLine($rating100ScaleValue, 'appended');
		$tracktitle = $tracktitle.$ratingtext;
		push (@vfd_ratedtracks, {
			type => 'redirect',
			name => $tracktitle,
			items => [
				{
					name => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNOW'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$track_id, 'load', string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNOW_MSG')],
				},
				{
					name => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNEXT'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$track_id, 'insert', string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNEXT_MSG')],
				},
				{
					name => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_APPEND'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$track_id, 'add', string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_APPEND_MSG')],
				},
			]
		});
	}
	my $trackCount = scalar(@vfd_ratedtracks);
	if ($trackCount > 1) {
		my $listalltrackids = join (',', @alltrackids);
		unshift @vfd_ratedtracks, {
			type => 'redirect',
			name => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_ALLSONGS'),
			items => [
				{
					name => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNOW'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$listalltrackids, 'load', string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNOW_MSG_ALL')],
				},
				{
					name => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNEXT'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$listalltrackids, 'insert', string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNEXT_MSG_ALL')],
				},
				{
					name => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_APPEND'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$listalltrackids, 'add', string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_APPEND_MSG_ALL')],
				},
			]
		};
	}
	return \@vfd_ratedtracks;
}

sub VFD_execActions {
	my ($client, $callback, $params, $trackID, $action, $cbtext) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('action = '.$action);

	my @actionargs = ('playlistcontrol', 'cmd:'.$action, 'track_id:'.$trackID);
	$client->execute(\@actionargs);

	$callback->([{
		type => 'text',
		name => $cbtext,
		showBriefly => 1, popback => 2,
		favorites => 0, refresh => 1
	}]);
}


## import, export, adjust

sub importRatingsFromPlaylist {
	my $playlistimport_maxtracks = $prefs->get('playlistimport_maxtracks');
	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: access to rating values blocked until library scan is completed');
		return;
	}
	my $status_batchratingplaylisttracks = $prefs->get('status_batchratingplaylisttracks');
	if ($status_batchratingplaylisttracks == 1) {
		$log->warn('Import is already in progress, please wait for the previous import to finish');
		return;
	}
	$prefs->set('status_batchratingplaylisttracks', 1);
	my $started = time();

	my $playlistid = $prefs->get('ratethisplaylistid');
	my $rating100ScaleValue = $prefs->get('ratethisplaylistrating');
	my $queryresult = Slim::Control::Request::executeRequest(undef, ['playlists', 'tracks', '0', $playlistimport_maxtracks, 'playlist_id:'.$playlistid, 'tags:Eux']);
	my $statuscode = $queryresult->{'_status'};
	main::DEBUGLOG && $log->is_debug && $log->debug('Status of query result = '.$statuscode);
	if ($statuscode == 101) {
		$log->warn("Warning: Can't import ratings from this playlist. Please check playlist for invalid tracks (dead, moved...) or remote tracks that are not part of this library.");
		return;
	}

	my $playlisttrackcount = $queryresult->getResult('count');
	if ($playlisttrackcount > 0) {
		my $playlisttracksarray = $queryresult->getResult('playlisttracks_loop');
		my @ratableTracks = ();
		my $ignoredtracks = 0;

		foreach my $playlisttrack (@{$playlisttracksarray}) {
			my $trackURL = $playlisttrack->{'url'};
			my $trackID = $playlisttrack->{'id'};
			if (defined($playlisttrack->{'remote'}) && ($playlisttrack->{'remote'} == 1)) {
				if (!defined($playlisttrack->{'extid'})) {
					main::DEBUGLOG && $log->is_debug && $log->debug('Track is remote but not part of LMS library: '.$playlisttrack->{'title'});
					$playlisttrackcount--;
					$ignoredtracks++;
					next;
				}
				push @ratableTracks, $playlisttrack;
			} else {
				my $thistrack = Slim::Schema->resultset('Track')->objectForUrl($trackURL);
				if (!defined($thistrack->filesize)) {
					main::DEBUGLOG && $log->is_debug && $log->debug('Ignoring this track, track dead or moved??? Track URL: '.$trackURL);
					$playlisttrackcount--;
					$ignoredtracks++;
					next;
				}
				push @ratableTracks, $playlisttrack;
			}
		}

		if (scalar (@ratableTracks) > 0) {
			foreach my $thisTrack (@ratableTracks) {
				writeRatingToDB($thisTrack->{'id'}, $thisTrack->{'url'}, undef, undef, $rating100ScaleValue, 1);
			}
			main::INFOLOG && $log->is_info && $log->info('Playlist (ID: '.$playlistid.') contained '.(scalar (@ratableTracks)).(scalar (@ratableTracks) == 1 ? ' track' : ' tracks').' that could be rated.');
			refreshAll(1);
		} else {
			main::INFOLOG && $log->is_info && $log->info('Playlist (ID: '.$playlistid.') contained no tracks that could be rated.');
		}
		if ($ignoredtracks > 0) {
			$log->warn($ignoredtracks.($ignoredtracks == 1 ? ' track was' : ' tracks were')." ignored in total (couldn't be rated). Set log level to INFO for more details.");
		}
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('Rating playlist tracks completed after '.(time() - $started).' seconds.');
	$prefs->set('ratethisplaylistid', '');
	$prefs->set('ratethisplaylistrating', '');
	$prefs->set('status_batchratingplaylisttracks', 0);
}

sub exportRatingsToPlaylistFiles {
	my $status_exportingtoplaylistfiles = $prefs->get('status_exportingtoplaylistfiles');
	if ($status_exportingtoplaylistfiles == 1) {
		$log->warn('Export is already in progress, please wait for the previous export to finish');
		return;
	}
	$prefs->set('status_exportingtoplaylistfiles', 1);

	my $exportDir = $prefs->get('rlfolderpath');
	my $started = time();

	my $filetagtype = $prefs->get('filetagtype');
	my $onlyratingsnotmatchtags = $prefs->get('onlyratingsnotmatchtags');
	my $rating_keyword_prefix = $prefs->get('rating_keyword_prefix');
	my $rating_keyword_suffix = $prefs->get('rating_keyword_suffix');
	my ($sql, $sth) = undef;
	my $dbh = Slim::Schema->dbh;
	my $exporttimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;
	my $filename_timestamp = strftime "%Y%m%d-%H%M", localtime time;
	my $exportVL_id = $prefs->get('exportVL_id');
	main::DEBUGLOG && $log->is_debug && $log->debug('exportVL_id = '.$exportVL_id);
	my $totaltrackcount = 0;
	my $rating100ScaleValueCeil = 0;
	my $rating100ScaleValueFloor = 0;
	my $singleFile = $prefs->get('playlistexportsinglefile');

	for (my $rating100ScaleValue = 10; $rating100ScaleValue <= 100; $rating100ScaleValue = $rating100ScaleValue + 10) {
		$rating100ScaleValueFloor = $rating100ScaleValue - 5;
		$rating100ScaleValueCeil = $rating100ScaleValue + 4;
		if ($singleFile) {
			$rating100ScaleValueCeil = 100;
			$rating100ScaleValueFloor = 1;
		}
		if (defined $onlyratingsnotmatchtags) {
			# comments tags
			if ($filetagtype == 1) {
				if ((!defined $rating_keyword_prefix || $rating_keyword_prefix eq '') && (!defined $rating_keyword_suffix || $rating_keyword_suffix eq '')) {
					$log->warn('Error: no rating keywords found.');
					return
				} else {
					if ((defined $exportVL_id) && ($exportVL_id ne '')) {
							$sql = "select tracks.url, tracks.remote from tracks join tracks_persistent persistent on persistent.urlmd5 = tracks.urlmd5 and (persistent.rating >= $rating100ScaleValueFloor and persistent.rating <= $rating100ScaleValueCeil) join library_track on library_track.track = tracks.id and library_track.library = \"$exportVL_id\" where tracks.audio = 1 and persistent.urlmd5 in (select tracks.urlmd5 from tracks left join comments on comments.track = tracks.id where (comments.value not like ? or comments.value is null))";
					} else {
							$sql = "select tracks_persistent.url, tracks.remote from tracks_persistent join tracks on tracks.urlmd5 = tracks_persistent.urlmd5 where (tracks_persistent.rating >= $rating100ScaleValueFloor and tracks_persistent.rating <= $rating100ScaleValueCeil and tracks_persistent.urlmd5 in (select tracks.urlmd5 from tracks left join comments on comments.track = tracks.id where (comments.value not like ? or comments.value is null)))";
					}
					$sth = $dbh->prepare($sql);
					my $ratingkeyword = "%%".$rating_keyword_prefix.($rating100ScaleValue/20).$rating_keyword_suffix."%%";
					$sth->bind_param(1, $ratingkeyword);
				}
			# BPM tags
			} elsif ($filetagtype == 0) {
				if ((defined $exportVL_id) && ($exportVL_id ne '')) {
						$sql = "select tracks.url, tracks.remote from tracks join tracks_persistent persistent on persistent.urlmd5 = tracks.urlmd5 and (persistent.rating >= $rating100ScaleValueFloor and persistent.rating <= $rating100ScaleValueCeil) join library_track on library_track.track = tracks.id and library_track.library = \"$exportVL_id\" where tracks.audio = 1 and persistent.urlmd5 in (select tracks.urlmd5 from tracks where (tracks.bpm != $rating100ScaleValue or tracks.bpm is null))";
				} else {
						$sql = "select tracks_persistent.url, tracks.remote from tracks_persistent join tracks on tracks.urlmd5 = tracks_persistent.urlmd5 where (tracks_persistent.rating >= $rating100ScaleValueFloor and tracks_persistent.rating <= $rating100ScaleValueCeil and tracks_persistent.urlmd5 in (select tracks.urlmd5 from tracks where (tracks.bpm != $rating100ScaleValue or tracks.bpm is null)))";
				}
				$sth = $dbh->prepare($sql);
			}
		} else {
			if ((defined $exportVL_id) && ($exportVL_id ne '')) {
				$sql = "select tracks.url, tracks.remote from tracks join tracks_persistent persistent on persistent.urlmd5 = tracks.urlmd5 and (persistent.rating >= $rating100ScaleValueFloor and persistent.rating <= $rating100ScaleValueCeil) join library_track on library_track.track = tracks.id and library_track.library = \"$exportVL_id\" where tracks.audio = 1";
			} else {
				$sql = "select tracks_persistent.url, tracks.remote from tracks_persistent join tracks on tracks.urlmd5 = tracks_persistent.urlmd5 where (tracks_persistent.rating >= $rating100ScaleValueFloor and tracks_persistent.rating <= $rating100ScaleValueCeil)";
			}
			$sth = $dbh->prepare($sql);
		}
		$sth->execute();

		my ($trackURL, $trackRemote);
		$sth->bind_col(1,\$trackURL);
		$sth->bind_col(2,\$trackRemote);

		my @ratedTracks = ();
		while ($sth->fetch()) {
			push (@ratedTracks, {'url' => $trackURL, 'remote' => $trackRemote});
		}
		$sth->finish();

		my $trackcount = scalar(@ratedTracks);
		$totaltrackcount = $totaltrackcount + $trackcount;

		if ($trackcount > 0) {
			my $PLfilename = (($rating100ScaleValue/20) == 1 ? 'RL_Export_'.$filename_timestamp.'__Rated_'.($rating100ScaleValue/20).'_star.m3u.txt' : 'RL_Export_'.$filename_timestamp.'__Rated_'.($rating100ScaleValue/20).'_stars.m3u.txt');
			$PLfilename = 'RL_Export_'.$filename_timestamp.'__AllRatedTracks.m3u.txt' if $singleFile;
			my $filename = catfile($exportDir, $PLfilename);
			my $output = FileHandle->new($filename, '>:utf8') or do {
				$log->error('Could not open '.$filename.' for writing. Does the RatingsLight folder exist? Does LMS have read/write permissions (755) for the (parent) folder?');
				$prefs->set('status_exportingtoplaylistfiles', 0);
				return;
			};
			print $output '#EXTM3U'."\n";
			print $output '# exported with \'Ratings Light\' LMS plugin ('.$exporttimestamp.")\n";
			if ((defined $exportVL_id) && ($exportVL_id ne '')) {
				my $exportVL_name = Slim::Music::VirtualLibraries->getNameForId($exportVL_id);
				print $output '# tracks from library (view): '.$exportVL_name."\n";
			}
			if ($singleFile) {
				print $output '# contains '.$trackcount.($trackcount == 1 ? ' rated track' : ' rated tracks')."\n\n";
			} else {
				print $output '# contains '.$trackcount.($trackcount == 1 ? ' track' : ' tracks').' rated '.(($rating100ScaleValue/20) == 1 ? ($rating100ScaleValue/20).' star' : ($rating100ScaleValue/20).' stars')."\n\n";
			}
			if (defined $onlyratingsnotmatchtags) {
				print $output "# *** This export only contains rated tracks whose ratings differ from the rating value derived from their comments tag keywords. ***\n";
				print $output "# *** If you want to export ALL rated tracks change the preference on the Ratings Light settings page. ***\n\n";
			}
			for my $ratedTrack (@ratedTracks) {
				my $ratedTrackURL = $ratedTrack->{'url'};

				my $ratedTrackURL_extURL = changeExportFilePath($ratedTrackURL, 1) if ($ratedTrack->{'remote'} != 1);
				print $output '#EXTURL:'.$ratedTrackURL_extURL."\n" if $ratedTrackURL_extURL && $ratedTrackURL_extURL ne '';

				my $ratedTrackPath = pathForItem($ratedTrackURL);
				$ratedTrackPath = Slim::Utils::Unicode::utf8decode_locale(pathForItem($ratedTrackURL)); # diff
				$ratedTrackPath = changeExportFilePath($ratedTrackPath) if ($ratedTrack->{'remote'} != 1);

				print $output $ratedTrackPath."\n";
			}
			close $output;
		}
		last if $singleFile;
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('TOTAL number of tracks exported: '.$totaltrackcount);
	$prefs->set('status_exportingtoplaylistfiles', 0);
	$prefs->set('exportVL_id', '');
	main::DEBUGLOG && $log->is_debug && $log->debug('Export completed after '.(time() - $started).' seconds.');
}

sub changeExportFilePath {
	my $trackURL = shift;
	my $isEXTURL = shift;
	my $exportbasefilepathmatrix = $prefs->get('exportbasefilepathmatrix');

	if (scalar @{$exportbasefilepathmatrix} > 0) {
		my $oldtrackURL = $trackURL;
		my $escaped_trackURL = escape($trackURL);
		my $exportextension = $prefs->get('exportextension');
		my $exportExtensionExceptionsString = $prefs->get('exportextensionexceptions');

		foreach my $thispath (@{$exportbasefilepathmatrix}) {
			my $lmsbasepath = $thispath->{'lmsbasepath'};
			main::INFOLOG && $log->is_info && $log->info("\n\n\nisEXTURL = ".Data::Dump::dump($isEXTURL));
			main::INFOLOG && $log->is_info && $log->info('trackURL = '.Data::Dump::dump($oldtrackURL));
			main::INFOLOG && $log->is_info && $log->info('escaped_trackURL = '.$escaped_trackURL);
			if ($isEXTURL) {
				$lmsbasepath =~ s/\\/\//isg;
				$escaped_trackURL =~ s/%2520/%20/isg;
			}
			main::INFOLOG && $log->is_info && $log->info('escaped_trackURL after EXTURL regex = '.$escaped_trackURL);

			my $escaped_lmsbasepath = escape($lmsbasepath);
			main::INFOLOG && $log->is_info && $log->info('escaped_lmsbasepath = '.$escaped_lmsbasepath);

			if (($escaped_trackURL =~ $escaped_lmsbasepath) && (defined ($thispath->{'substitutebasepath'})) && (($thispath->{'substitutebasepath'}) ne '')) {
				my $substitutebasepath = $thispath->{'substitutebasepath'};
				main::INFOLOG && $log->is_info && $log->info('substitutebasepath = '.$substitutebasepath);
				if ($isEXTURL) {
					$substitutebasepath =~ s/\\/\//isg;
				}
				my $escaped_substitutebasepath = escape($substitutebasepath);
				main::INFOLOG && $log->is_info && $log->info('escaped_substitutebasepath = '.$escaped_substitutebasepath);

				if (defined $exportextension && $exportextension ne '') {
					my ($LMSfileExtension) = $escaped_trackURL =~ /(\.[^.]*)$/;
					$LMSfileExtension =~ s/\.//s;
					main::INFOLOG && $log->is_info && $log->info("LMS file extension is '$LMSfileExtension'");

					# file extension replacement - exceptions
					my %extensionExceptionsHash;
					if (defined $exportExtensionExceptionsString && $exportExtensionExceptionsString ne '') {
						$exportExtensionExceptionsString =~ s/ //g;
						%extensionExceptionsHash = map {$_ => 1} (split /,/, lc($exportExtensionExceptionsString));
						main::DEBUGLOG && $log->is_debug && $log->debug('extensionExceptionsHash = '.Data::Dump::dump(\%extensionExceptionsHash));
					}

					if ((scalar keys %extensionExceptionsHash > 0) && $extensionExceptionsHash{lc($LMSfileExtension)}) {
						main::INFOLOG && $log->is_info && $log->info("The file extension '$LMSfileExtension' is not replaced because it is included in the list of exceptions.");
					} else {
						$escaped_trackURL =~ s/\.[^.]*$/\.$exportextension/isg;
					}
				}

				$escaped_trackURL =~ s/$escaped_lmsbasepath/$escaped_substitutebasepath/isg;
				main::INFOLOG && $log->is_info && $log->info('escaped_trackURL AFTER regex replacing = '.$escaped_trackURL);

				$trackURL = Encode::decode('utf8', unescape($escaped_trackURL));
				main::INFOLOG && $log->is_info && $log->info('UNescaped trackURL = '.$trackURL);

				if ($isEXTURL) {
					$trackURL =~ s/ /%20/isg;
				} else {
					$trackURL = Slim::Utils::Unicode::utf8decode_locale($trackURL);
				}
				main::INFOLOG && $log->is_info && $log->info('old url: '.$oldtrackURL."\nlmsbasepath = ".$lmsbasepath."\nsubstitutebasepath = ".$substitutebasepath."\nnew url = ".$trackURL);
			}
		}
	}
	return $trackURL;
}

sub initExportBaseFilePathMatrix {
	# get LMS music dirs
	my $lmsmusicdirs = getMusicDirs();
	my $exportbasefilepathmatrix = $prefs->get('exportbasefilepathmatrix');
	if (!defined $exportbasefilepathmatrix) {
		my $n = 0;
		foreach my $musicdir (@{$lmsmusicdirs}) {
			push(@{$exportbasefilepathmatrix}, {lmsbasepath => $musicdir, substitutebasepath => ''});
			$n++;
		}
		$prefs->set('exportbasefilepathmatrix', $exportbasefilepathmatrix);
	} else {
		# add new music dirs as options if not in list
		my @currentlmsbasefilepaths;
		foreach my $thispath (@{$exportbasefilepathmatrix}) {
			push (@currentlmsbasefilepaths, $thispath->{'lmsbasepath'});
		}

		my %seen;
		@seen{@currentlmsbasefilepaths} = ();

		foreach my $newdir (@{$lmsmusicdirs}) {
			push (@{$exportbasefilepathmatrix}, {lmsbasepath => $newdir, substitutebasepath => ''}) unless exists $seen{$newdir};
		}
		$prefs->set('exportbasefilepathmatrix', \@{$exportbasefilepathmatrix});
	}
}

sub setRefreshTimer {
	main::DEBUGLOG && $log->is_debug && $log->debug('Killing existing timers for post-scan refresh to prevent multiple calls');
	Slim::Utils::Timers::killOneTimer(undef, \&delayedPostScanRefresh);
	main::DEBUGLOG && $log->is_debug && $log->debug('Scheduling a delayed post-scan refresh');
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $prefs->get('postscanscheduledelay'), \&delayedPostScanRefresh);
}

sub delayedPostScanRefresh {
	if (Slim::Music::Import->stillScanning) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Scan in progress. Waiting for current scan to finish.');
		setRefreshTimer();
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug('Starting post-scan refresh');
		refreshAll();
	}
}

sub adjustRatings {
	my $status_adjustingratings = $prefs->get('status_adjustingratings');
	if ($status_adjustingratings == 1) {
		$log->warn('RL is already adjusting ratings, please wait for the process to finish');
		return;
	}
	$prefs->set('status_adjustingratings', 1);
	my $started = time();
	my $dbh = Slim::Schema->dbh;

	my $rating100ScaleValueCeil = 0;
	my $rating100ScaleValueFloor = 0;
	my $singleFile = $prefs->get('playlistexportsinglefile');
	my @ratedTracks = ();

	my $sql = "select tracks.id, tracks_persistent.rating from tracks_persistent join tracks on tracks.urlmd5 = tracks_persistent.urlmd5 where ifnull(tracks_persistent.rating, 0) > 0";
	my $sth = $dbh->prepare($sql);
	$sth->execute();

	my ($trackID, $trackRating);
	$sth->bind_col(1,\$trackID);
	$sth->bind_col(2,\$trackRating);

	while ($sth->fetch()) {
		push (@ratedTracks, {'id' => $trackID, 'rating' => $trackRating});
	}
	$sth->finish();

	my $adjustedCount = 0;
	if (scalar (@ratedTracks) > 0) {
		foreach my $thisTrack (@ratedTracks) {
			my $thisRating = $thisTrack->{'rating'};
			if (($thisRating % 10 != 0) || $thisRating > 100) { # rating is not LMS standard
				$thisRating = ratingSanityCheck($thisRating);
				$thisRating = adjustRating($thisRating);
				writeRatingToDB($thisTrack->{'id'}, undef, undef, undef, $thisRating, 1);
				$adjustedCount++;
			}
		}
	}

	$prefs->set('status_adjustingratings', 0);
	main::INFOLOG && $log->is_info && $log->info('Adjusted ratings of '.$adjustedCount.($adjustedCount == 1 ? ' track.' : ' tracks.')) if $adjustedCount;
	main::DEBUGLOG && $log->is_debug && $log->debug('Adjusting ratings completed after '.(time() - $started).' seconds.');
}


## backup, restore

sub backupScheduler {
	my $scheduledbackups = $prefs->get('scheduledbackups');
	if (defined $scheduledbackups) {
		my $backuptime = $prefs->get('backuptime');
		my $day = $prefs->get('backup_lastday');
		if (!defined($day)) {
			$day = '';
		}

		if (defined($backuptime) && $backuptime ne '') {
			my $time = 0;
			$backuptime =~ s{
				^(0?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$
			}{
				if (defined $3) {
					$time = ($1 == 12?0:$1 * 60 * 60) + ($2 * 60) + ($3 =~ /P/?12 * 60 * 60:0);
				} else {
					$time = ($1 * 60 * 60) + ($2 * 60);
				}
			}iegsx;
			my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time);

			my $currenttime = $hour * 60 * 60 + $min * 60;

			if (($day ne $mday) && $currenttime>$time) {
				eval {
					createBackup();
				};
				if ($@) {
					$log->error("Scheduled backup failed: $@");
				}
				$prefs->set('backup_lastday',$mday);
			} else {
				my $timesleft = $time-$currenttime;
				if ($day eq $mday) {
					$timesleft = $timesleft + 60*60*24;
				}
				main::DEBUGLOG && $log->is_debug && $log->debug(parse_duration($timesleft)." ($timesleft seconds) left until next scheduled backup");
			}
		}
		Slim::Utils::Timers::setTimer(0, Time::HiRes::time() + 3600, \&backupScheduler);
	}
}

sub restoreFromBackup {
	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: access to rating values blocked until library scan is completed');
		return;
	}

	my $status_restoringfrombackup = $prefs->get('status_restoringfrombackup');
	my $clearallbeforerestore = $prefs->get('clearallbeforerestore');

	if ($status_restoringfrombackup == 1) {
		$log->warn('Restore is already in progress, please wait for the previous restore to finish');
		return;
	}

	$prefs->set('status_restoringfrombackup', 1);
	$restorestarted = time();
	my $restorefile = $prefs->get('restorefile');

	if ($restorefile) {
		if (defined $clearallbeforerestore) {
			clearAllRatings(1);
		}
		initRestore();
		Slim::Utils::Scheduler::add_task(\&restoreScanFunction);
	} else {
		$log->error('Error: No backup file specified');
		$prefs->set('status_restoringfrombackup', 0);
	}
}

sub initRestore {
	if (defined($backupParserNB)) {
		eval {$backupParserNB->parse_done};
		$backupParserNB = undef;
	}
	$backupParser = XML::Parser->new(
		'ErrorContext' => 2,
		'ProtocolEncoding' => 'UTF-8',
		'NoExpand' => 1,
		'NoLWP' => 1,
		'Handlers' => {
			'Start' => \&handleStartElement,
			'Char' => \&handleCharElement,
			'End' => \&handleEndElement,
		},
	);
}

sub restoreScanFunction {
	my $restorefile = $prefs->get('restorefile');
	if ($opened != 1) {
		open(BACKUPFILE, $restorefile) || do {
			$log->error('Couldn\'t open backup file: '.$restorefile);
			$prefs->set('status_restoringfrombackup', 0);
			return 0;
		};
		$opened = 1;
		$inTrack = 0;
		$inValue = 0;
		%restoreitem = ();
		$currentKey = undef;

		if (defined $backupParser) {
			$backupParserNB = $backupParser->parse_start();
		} else {
			$log->warn('No backupParser was defined!');
		}
	}

	if (defined $backupParserNB) {
		local $/ = '>';
		my $line;

		for (my $i = 0; $i < 25;) {
			my $singleLine = <BACKUPFILE>;
			if (defined($singleLine)) {
				$line .= $singleLine;
				if ($singleLine =~ /(<\/track>)$/) {
					$i++;
				}
			} else {
				last;
			}
		}
		$line =~ s/&#(\d*);/escape(chr($1))/ge;
		$backupParserNB->parse_more($line);
		return 1;
	}

	$log->warn('No backupParserNB defined!');
	$prefs->set('status_restoringfrombackup', 0);
	return 0;
}

sub doneScanning {
	if (defined $backupParserNB) {
		eval {$backupParserNB->parse_done};
	}

	$backupParserNB = undef;
	$backupParser = undef;
	$opened = 0;
	close(BACKUPFILE);

	main::DEBUGLOG && $log->is_debug && $log->debug('Restore completed after '.(time() - $restorestarted).' seconds.');
	sleep 1;
	refreshAll();

	$prefs->set('status_restoringfrombackup', 0);
	$prefs->set('isTSlegacyBackupFile', 0);
	Slim::Utils::Scheduler::remove_task(\&restoreScanFunction);
	#$prefs->set('restorefile', '');
}

sub handleStartElement {
	my ($p, $element) = @_;

	if ($inTrack) {
		$currentKey = $element;
		$inValue = 1;
	}
	if ($element eq 'track') {
		$inTrack = 1;
	}
	if ($element eq 'TrackStat') {
		$prefs->set('isTSlegacyBackupFile', 1);
	}
}

sub handleCharElement {
	my ($p, $value) = @_;

	if ($inValue && $currentKey) {
		$restoreitem{$currentKey} = $value;
	}
}

sub handleEndElement {
	my ($p, $element) = @_;
	$inValue = 0;
	my $isTSlegacyBackupFile = $prefs->get('isTSlegacyBackupFile');
	my $selectiverestore = $prefs->get('selectiverestore');

	if ($inTrack && $element eq 'track') {
		$inTrack = 0;

		my $curTrack = \%restoreitem;
		my $remote = $curTrack->{'remote'};

		if (($selectiverestore == 0 || $isTSlegacyBackupFile) || ($selectiverestore == 1 && $remote == 0) || ($selectiverestore == 2 && $remote == 1)) {
			my $trackURL = undef;
			my $fullTrackURL = $curTrack->{'url'};
			my $trackURLmd5 = $curTrack->{'urlmd5'} unless $isTSlegacyBackupFile;
			my $relTrackURL = $curTrack->{'relurl'} unless $isTSlegacyBackupFile;
			my $rating100ScaleValue = $curTrack->{'rating'};

			if ($rating100ScaleValue) {
				# check if FULL file url is valid
				# Otherwise, try RELATIVE file URL with current media dirs
				$fullTrackURL = Encode::decode('utf8', unescape($fullTrackURL));
				$relTrackURL = Encode::decode('utf8', unescape($relTrackURL)) unless $isTSlegacyBackupFile;

				my $fullTrackPath = pathForItem($fullTrackURL);
				if (-f $fullTrackPath) {
					main::DEBUGLOG && $log->is_debug && $log->debug("Found file at url \"$fullTrackPath\"");
					$trackURL = $fullTrackURL;
				} elsif (!$isTSlegacyBackupFile) {
					main::DEBUGLOG && $log->is_debug && $log->debug("** Couldn't find file for FULL file url. Will try with RELATIVE file url and current LMS media folders.");
					my $lmsmusicdirs = getMusicDirs();
					main::DEBUGLOG && $log->is_debug && $log->debug('Valid LMS music dirs = '.Data::Dump::dump($lmsmusicdirs));

					foreach (@{$lmsmusicdirs}) {
						my $dirSep = File::Spec->canonpath("/");
						my $mediaDirURL = Slim::Utils::Misc::fileURLFromPath($_.$dirSep);
						main::DEBUGLOG && $log->is_debug && $log->debug('Trying LMS music dir url: '.$mediaDirURL);

						my $newFullTrackURL = $mediaDirURL.$relTrackURL;
						my $newFullTrackPath = pathForItem($newFullTrackURL);
						main::DEBUGLOG && $log->is_debug && $log->debug('Trying with new full track path: '.$newFullTrackPath);

						if (-f $newFullTrackPath) {
							$trackURL = Slim::Utils::Misc::fileURLFromPath($newFullTrackURL);
							main::DEBUGLOG && $log->is_debug && $log->debug('Found file at new full file url: '.$trackURL);
							main::DEBUGLOG && $log->is_debug && $log->debug('OLD full file url was: '.$fullTrackURL);
							last;
						}
					}
				}
				if (!$trackURL && !$trackURLmd5) {
					$log->warn("Neither track urlmd5 nor valid track url. Can't restore values for file with restore url \"$fullTrackURL\"");
				} else {
					writeRatingToDB(undef, $trackURL, $trackURLmd5, undef, $rating100ScaleValue, 1);
				}
			}
		}
		%restoreitem = ();
	}

	if ($element eq 'RatingsLight' || $element eq 'TrackStat') {
		doneScanning();
		return 0;
	}
}


## virtual libraries

sub initVirtualLibraries {
	Slim::Music::VirtualLibraries->unregisterLibrary('RATINGSLIGHT_RATED');
	Slim::Music::VirtualLibraries->unregisterLibrary('RATINGSLIGHT_TOPRATED');
	for (my $i = 10; $i <= 100; $i+=10) {
		Slim::Music::VirtualLibraries->unregisterLibrary('RATINGSLIGHT_EXACTRATING'.$i);
	}
	Slim::Menu::BrowseLibrary->deregisterNode('RatingsLightRatedTracksMenuFolder');

	my $showratedtracksmenus = $prefs->get('showratedtracksmenus');
	if ($showratedtracksmenus > 0) {
		my $started = time();
		my $topratedminrating = $prefs->get('topratedminrating');

		# check if there's a valid virtual library filter, otherwise use complete library
		my $browsemenus_sourceVL_name = validateBrowsemenusSourceVL();
		my $browsemenus_sourceVL_id = $prefs->get('browsemenus_sourceVL_id');

		my $sqlVLstart = "insert or ignore into library_track (library, track) select '%s', tracks.id ";
		my $sqlVLquickCount = "select count(tracks.id) ";
		my $sqlVLcommon = "from tracks join tracks_persistent tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating ";
		my $sqlVLsourceVL = " join library_track on library_track.track = tracks.id and library_track.library = \"$browsemenus_sourceVL_id\" ";
		my $sqlVLend = " group by tracks.id";

		my @libraries = ();
		if ($showratedtracksmenus < 3) {
			push @libraries,{
				id => 'RATINGSLIGHT_RATED',
				name => string('PLUGIN_RATINGSLIGHT_VLNAME_RATEDTRACKS').((!defined($browsemenus_sourceVL_id) || $browsemenus_sourceVL_id eq '') ? '' : $browsemenus_sourceVL_name),
				sql => $sqlVLstart.$sqlVLcommon."> 0".((defined($browsemenus_sourceVL_id) && $browsemenus_sourceVL_id ne '') ? $sqlVLsourceVL : "").$sqlVLend,
				quickcount => $sqlVLquickCount.$sqlVLcommon."> 0".((defined($browsemenus_sourceVL_id) && $browsemenus_sourceVL_id ne '') ? $sqlVLsourceVL : "").$sqlVLend,
			};

			if ($showratedtracksmenus == 2) {
				push @libraries,{
					id => 'RATINGSLIGHT_TOPRATED',
					name => string('PLUGIN_RATINGSLIGHT_VLNAME_TOPRATEDTRACKS').((!defined($browsemenus_sourceVL_id) || $browsemenus_sourceVL_id eq '') ? '' : $browsemenus_sourceVL_name),
					sql => $sqlVLstart.$sqlVLcommon.">= $topratedminrating".((defined($browsemenus_sourceVL_id) && $browsemenus_sourceVL_id ne '') ? $sqlVLsourceVL : "").$sqlVLend,
					quickcount => $sqlVLquickCount.$sqlVLcommon.">= $topratedminrating".((defined($browsemenus_sourceVL_id) && $browsemenus_sourceVL_id ne '') ? $sqlVLsourceVL : "").$sqlVLend,
				};
			}
		}

		# create VLs for exact rating values
		if ($showratedtracksmenus >= 3) {
			for (my $i = 10; $i <= 100; $i += 10) {
				next if ($showratedtracksmenus < 4 && $i % 20);
				my $ratingMin = $i - ($showratedtracksmenus == 4 ? 5 : 10);
				my $ratingMax = $i + ($showratedtracksmenus == 4 ? 5 : 10);
				push @libraries,{
						id => 'RATINGSLIGHT_EXACTRATING'.$i,
						name => string('PLUGIN_RATINGSLIGHT_VLNAME_TRACKSRATED').' '.($i/20).' '.($i == 20 ? string('PLUGIN_RATINGSLIGHT_STAR') : string('PLUGIN_RATINGSLIGHT_STARS')).((!defined($browsemenus_sourceVL_id) || $browsemenus_sourceVL_id eq '') ? '' : $browsemenus_sourceVL_name),
						sql => $sqlVLstart.$sqlVLcommon.">= $ratingMin and tracks_persistent.rating < $ratingMax".((defined($browsemenus_sourceVL_id) && $browsemenus_sourceVL_id ne '') ? $sqlVLsourceVL : "").$sqlVLend,
						quickcount => $sqlVLquickCount.$sqlVLcommon.">= $ratingMin and tracks_persistent.rating < $ratingMax".((defined($browsemenus_sourceVL_id) && $browsemenus_sourceVL_id ne '') ? $sqlVLsourceVL : "").$sqlVLend,
				};
			}
		}

		foreach my $library (@libraries) {
			Slim::Music::VirtualLibraries->unregisterLibrary($library->{id});
			unless (quickCountSQL($library->{quickcount}) == 0) {
				Slim::Music::VirtualLibraries->registerLibrary($library);
				Slim::Music::VirtualLibraries->rebuild($library->{id});
			}
		}

	main::INFOLOG && $log->is_info && $log->info('Init of virtual libraries completed after '.(time() - $started).' seconds.');
	initVLmenus();
	}
}

sub validateBrowsemenusSourceVL {
	my $browsemenus_sourceVL_id = $prefs->get('browsemenus_sourceVL_id');
	main::DEBUGLOG && $log->is_debug && $log->debug('browsemenus_sourceVL_id = '.Data::Dump::dump($browsemenus_sourceVL_id));

	my $libraries = Slim::Music::VirtualLibraries->getLibraries();
	# check if source virtual library still exists, otherwise use complete library
	if ((defined $browsemenus_sourceVL_id) && ($browsemenus_sourceVL_id ne '')) {
		my $VLstillexists = 0;
		foreach my $thisVLid (keys %{$libraries}) {
			if ($thisVLid eq $browsemenus_sourceVL_id) {
				$VLstillexists = 1;
				main::DEBUGLOG && $log->is_debug && $log->debug('VL $browsemenus_sourceVL_id exists!');
			}
		}
		if ($VLstillexists == 0) {
			$prefs->set('browsemenus_sourceVL_id', undef);
			$browsemenus_sourceVL_id = undef;
		}
	}
	my $browsemenus_sourceVL_name = '';
	if ((defined $browsemenus_sourceVL_id) && ($browsemenus_sourceVL_id ne '')) {
		$browsemenus_sourceVL_name = Slim::Music::VirtualLibraries->getNameForId($browsemenus_sourceVL_id);
		$browsemenus_sourceVL_name = ' ('.string('PLUGIN_RATINGSLIGHT_LIBVIEW').': '.$browsemenus_sourceVL_name.')';
	}
	return $browsemenus_sourceVL_name;
}

sub initVLibsTimer {
	main::DEBUGLOG && $log->is_debug && $log->debug('Killing existing timers to prevent multiple calls');
	Slim::Utils::Timers::killTimers(undef, \&initVirtualLibraries);
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 0.5, \&initVirtualLibraries);
}

sub initVLmenus {
	my $started = time();
	my $showratedtracksmenus = $prefs->get('showratedtracksmenus');
	my $browsemenus_sourceVL_name = validateBrowsemenusSourceVL();
	my $browsemenus_sourceVL_id = $prefs->get('browsemenus_sourceVL_id');
	my $browsemenu_artists = $prefs->get('browsemenus_artists');
	my $browsemenus_genres = $prefs->get('browsemenus_genres');
	my $browsemenus_tracks = $prefs->get('browsemenus_tracks');

	Slim::Menu::BrowseLibrary->deregisterNode('RatingsLightRatedTracksMenuFolder');

	if ($showratedtracksmenus && ($browsemenu_artists || $browsemenus_genres || $browsemenus_tracks)) {

		my $menuGenerator = sub {
			my ($menuType, $extact100ScaleRating, $menuToken, $id, $offset, $params) = @_;

			my $menuIcon = $menuType eq 'tracks' ? 'playlists' : $menuType;

			return {
					type => 'link',
					name => ($extact100ScaleRating ? $menuToken : string($menuToken)).$browsemenus_sourceVL_name,
					icon => 'html/images/'.$menuIcon.'.png',
					jiveIcon => 'html/images/'.$menuIcon.'.png',
					id => $id,
					condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
					weight => 209 + $offset,
					cache => 1,
					url => sub {
						my ($client, $callback, $args, $pt) = @_;
						if ($menuType eq 'artists') {
							Slim::Menu::BrowseLibrary::_artists($client,
								sub {
										my $items = shift;
										main::DEBUGLOG && $log->is_debug && $log->debug("Browsing artists");
										if (defined($MAIprefs) && $MAIprefs->get('browseArtistPictures')) {
											$items->{items} = [ map {
													$_->{image} ||= 'imageproxy/mai/artist/' . ($_->{id} || 0) . '/image.png';
													$_;
											} @{$items->{items}} ];
										}
									$callback->($items);
								}, $args, $pt);
						} elsif ($menuType eq 'genres') {
							Slim::Menu::BrowseLibrary::_genres($client, $callback, $args, $pt);
						} elsif ($menuType eq 'tracks') {
							Slim::Menu::BrowseLibrary::_tracks($client, $callback, $args, $pt);
						}
					},
					passthrough => [ $params ],
			};
		};

		Slim::Menu::BrowseLibrary->registerNode({
			type => 'link',
			name => 'PLUGIN_RATINGSLIGHT_MENUS_RATED_TRACKS_MENU_FOLDER',
			id => 'RatingsLightRatedTracksMenuFolder',
			feed => sub {
				my ($client, $cb, $args, $pt) = @_;
				my @items = ();

				if ($showratedtracksmenus < 3) {
					my $library_id_rated = Slim::Music::VirtualLibraries->getRealId('RATINGSLIGHT_RATED');
					if ($library_id_rated) {
						# Artists with rated tracks
						$pt = {library_id => $library_id_rated};
						if ($prefs->get('browsemenus_artists')) {
							push @items, $menuGenerator->(
								'artists',
								undef,
								'PLUGIN_RATINGSLIGHT_MENUS_ARTISTMENU_RATED',
								'RL_RATED_BROWSEMENU_ARTISTS',
								0,
								{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
									],
								}
							);
						}

						# Genres with rated tracks
						if ($prefs->get('browsemenus_genres')) {
							push @items, $menuGenerator->(
								'genres',
								undef,
								'PLUGIN_RATINGSLIGHT_MENUS_GENREMENU_RATED',
								'RL_RATED_BROWSEMENU_GENRES',
								1,
								{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
									],
								}
							);
						}

						# Rated tracks
						if ($prefs->get('browsemenus_tracks')) {
							$pt->{'sort'} = 'track';
							$pt->{'menuStyle'} = 'menuStyle:album';
							push @items, $menuGenerator->(
								'tracks',
								undef,
								'PLUGIN_RATINGSLIGHT_MENUS_TRACKSMENU_RATED',
								'RL_RATED_BROWSEMENU_TRACKS',
								2,
								{
									library_id => $pt->{'library_id'},
									searchTags => [
										'library_id:'.$pt->{'library_id'},
									],
								}
							);
						}
					}

					if ($showratedtracksmenus == 2) {
						my $library_id_toprated = Slim::Music::VirtualLibraries->getRealId('RATINGSLIGHT_TOPRATED');
						if ($library_id_toprated) {
							# Artists with top rated tracks
							$pt = {library_id => $library_id_toprated};
							if ($prefs->get('browsemenus_artists')) {
								push @items, $menuGenerator->(
									'artists',
									undef,
									'PLUGIN_RATINGSLIGHT_MENUS_ARTISTMENU_TOPRATED',
									'RL_TOPRATED_BROWSEMENU_ARTISTS',
									3,
									{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'},
										],
									}
								);
							}

							# Genres with top rated tracks
							if ($prefs->get('browsemenus_genres')) {
								push @items, $menuGenerator->(
									'genres',
									undef,
									'PLUGIN_RATINGSLIGHT_MENUS_GENREMENU_TOPRATED',
									'RL_TOPRATED_BROWSEMENU_GENRES',
									4,
									{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'},
										],
									}
								);
							}

							# Top rated tracks
							if ($prefs->get('browsemenus_tracks')) {
								$pt->{'sort'} = 'track';
								$pt->{'menuStyle'} = 'menuStyle:album';
								push @items, $menuGenerator->(
									'tracks',
									undef,
									'PLUGIN_RATINGSLIGHT_MENUS_TRACKSMENU_TOPRATED',
									'RL_TOPRATED_BROWSEMENU_TRACKS',
									5,
									{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'},
										],
									}
								);
							}
						}
					}
				}

				if ($showratedtracksmenus >= 3) {
					for (my $i = 10; $i <= 100; $i += 10) {
						my $library_id_exactratingID = Slim::Music::VirtualLibraries->getRealId('RATINGSLIGHT_EXACTRATING'.$i);
						if ($library_id_exactratingID) {
							# Artists with tracks rated $i/20
							$pt = {library_id => $library_id_exactratingID};
							if ($prefs->get('browsemenus_artists')) {
								push @items, $menuGenerator->(
									'artists',
									$i,
									($i/20).' '.($i == 20 ? string('PLUGIN_RATINGSLIGHT_STAR') : string('PLUGIN_RATINGSLIGHT_STARS')).' '.string('PLUGIN_RATINGSLIGHT_MENUS_ARTISTMENU_SUFFIX'),
									'RL_EXACTRATING_BROWSEMENU_ARTISTS'.$i,
									$i,
									{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'},
										],
									}
								);
							}

							# Genres with tracks rated $i/20
							if ($prefs->get('browsemenus_genres')) {
								push @items, $menuGenerator->(
									'genres',
									$i,
									($i/20).' '.($i == 20 ? string('PLUGIN_RATINGSLIGHT_STAR') : string('PLUGIN_RATINGSLIGHT_STARS')).' '.string('PLUGIN_RATINGSLIGHT_MENUS_GENREMENU_SUFFIX'),
									'RL_EXACTRATING_BROWSEMENU_GENRES'.$i,
									$i,
									{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'},
										],
									}
								);
							}

							# Tracks rated $i/20
							if ($prefs->get('browsemenus_tracks')) {
								$pt->{'sort'} = 'track';
								$pt->{'menuStyle'} = 'menuStyle:album';
								push @items, $menuGenerator->(
									'tracks',
									$i,
									($i/20).' '.($i == 20 ? string('PLUGIN_RATINGSLIGHT_STAR') : string('PLUGIN_RATINGSLIGHT_STARS')).' '.string('PLUGIN_RATINGSLIGHT_MENUS_TRACKSMENU_SUFFIX'),
									'RL_EXACTRATING_BROWSEMENU_TRACKS'.$i,
									$i,
									{
										library_id => $pt->{'library_id'},
										searchTags => [
											'library_id:'.$pt->{'library_id'},
										],
									}
								);
							}
						}
					}
				}
				$cb->({
					items => \@items,
				});
			},
			weight => 88,
			cache => 0,
			icon => 'plugins/RatingsLight/html/images/ratedtracksmenuicon_svg.png',
			jiveIcon => 'plugins/RatingsLight/html/images/ratedtracksmenuicon_svg.png',
		});
		main::INFOLOG && $log->is_info && $log->info('Init of VL browse menus completed after '.(time() - $started).' seconds.');
	} else {
		main::INFOLOG && $log->is_info && $log->info('No VL browse menus for artists, genres or tracks enabled in RL menu settings.');
	}
}

sub refreshVirtualLibraries {
	my $showratedtracksmenus = $prefs->get('showratedtracksmenus');
	if ($showratedtracksmenus > 0) {
		my $started = time();
		if ($showratedtracksmenus < 3) {
			my $library_id = Slim::Music::VirtualLibraries->getRealId('RATINGSLIGHT_RATED');
			if ($library_id) {
				Slim::Music::VirtualLibraries->rebuild($library_id);
			}
		}
		if ($showratedtracksmenus == 2) {
			my $library_id = Slim::Music::VirtualLibraries->getRealId('RATINGSLIGHT_TOPRATED');
			if ($library_id) {
				Slim::Music::VirtualLibraries->rebuild($library_id);
			}
		}
		if ($showratedtracksmenus >= 3) {
			for (my $i = 10; $i <= 100; $i += 10) {
				my $library_id = Slim::Music::VirtualLibraries->getRealId('RATINGSLIGHT_EXACTRATING'.$i);
				if ($library_id) {
					Slim::Music::VirtualLibraries->rebuild($library_id) unless ($showratedtracksmenus < 4 && $i % 20);
					my $trackCount = Slim::Music::VirtualLibraries->getTrackCount($library_id) || 0;
					main::DEBUGLOG && $log->is_debug && $log->debug("Track count for library '".$library_id."' = ".$trackCount);
					if ($trackCount == 0 || ($showratedtracksmenus < 4 && $i % 20)) {
						Slim::Music::VirtualLibraries->unregisterLibrary($library_id);
						main::DEBUGLOG && $log->is_debug && $log->debug("Unregistering vlib '".$library_id.($trackCount == 0 ? "' because it has 0 tracks." : ""));
					}
				} else {
					next if ($showratedtracksmenus < 4 && $i % 20);

					# VL does not exist, create unless track count = 0
					my $browsemenus_sourceVL_name = validateBrowsemenusSourceVL();
					my $browsemenus_sourceVL_id = $prefs->get('browsemenus_sourceVL_id');
					my $ratingMin = $i - ($showratedtracksmenus == 4 ? 5 : 10);
					my $ratingMax = $i + ($showratedtracksmenus == 4 ? 5 : 10);
					my $thisVL = {
						id => 'RATINGSLIGHT_EXACTRATING'.$i,
						name => string('PLUGIN_RATINGSLIGHT_VLNAME_TRACKSRATED').' '.($i/20).' '.($i == 20 ? string('PLUGIN_RATINGSLIGHT_STAR') : string('PLUGIN_RATINGSLIGHT_STARS')).((!defined($browsemenus_sourceVL_id) || $browsemenus_sourceVL_id eq '') ? '' : $browsemenus_sourceVL_name),
						sql => ((!defined($browsemenus_sourceVL_id) || $browsemenus_sourceVL_id eq '') ? qq{insert or ignore into library_track (library, track) select '%s', tracks.id from tracks join tracks_persistent tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating >= $ratingMin and tracks_persistent.rating < $ratingMax group by tracks.id} : qq{insert or ignore into library_track (library, track) select '%s', tracks.id from tracks join tracks_persistent tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating >= $ratingMin and tracks_persistent.rating < $ratingMax join library_track on library_track.track = tracks.id and library_track.library = "$browsemenus_sourceVL_id" group by tracks.id}),
						quickcount => ((!defined($browsemenus_sourceVL_id) || $browsemenus_sourceVL_id eq '') ? qq{select count(tracks.id) from tracks join tracks_persistent tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating >= $ratingMin and tracks_persistent.rating < $ratingMax group by tracks.id} : qq{select count(tracks.id) from tracks join tracks_persistent tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating >= $ratingMin and tracks_persistent.rating < $ratingMax join library_track on library_track.track = tracks.id and library_track.library = "$browsemenus_sourceVL_id" group by tracks.id})
					};
					unless (quickCountSQL($thisVL->{quickcount}) == 0) {
						Slim::Music::VirtualLibraries->registerLibrary($thisVL);
						Slim::Music::VirtualLibraries->rebuild($thisVL->{id});
					}
				}
			}

		main::INFOLOG && $log->is_info && $log->info('Refreshing virtual libraries completed after '.(time() - $started).' seconds.');
		initVLmenus();
		}
	}
}

sub refreshVLtimer {
	main::DEBUGLOG && $log->is_debug && $log->debug('Killing existing timers for VL refresh to prevent multiple calls');
	Slim::Utils::Timers::killOneTimer(undef, \&refreshVirtualLibraries);
	main::DEBUGLOG && $log->is_debug && $log->debug('Scheduling a delayed VL refresh');
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 3, \&refreshVirtualLibraries);
}

sub getVirtualLibraries {
	my $libraries = Slim::Music::VirtualLibraries->getLibraries();
	my %libraries = map {
		$_ => $libraries->{$_}->{name}
	} keys %{$libraries} if keys %{$libraries};

	return \%libraries;
}


## IR remote rating

sub initIR {
	my $enableIRremotebuttons = $prefs->get('enableIRremotebuttons');

	if (defined $enableIRremotebuttons) {
		Slim::Control::Request::subscribe(\&newPlayerCheck, [['client']],[['new']]);
		Slim::Buttons::Common::addMode('PLUGIN.RatingsLight::Plugin', getFunctions(),\&Slim::Buttons::Input::Choice::setMode);
	} else {
		Slim::Control::Request::unsubscribe(\&newPlayerCheck, [['client']],[['new']]);
	}
}

sub getFunctions {
	our %menuFunctions = (
		'saveremoteratings' => sub {
			my $rating100ScaleValue = undef;
			my $client = shift;
			my $button = shift;
			my $digit = shift;

			if (Slim::Music::Import->stillScanning) {
				$log->warn('Warning: access to rating values blocked until library scan is completed');
				$client->showBriefly({'line' => [$client->string('PLUGIN_RATINGSLIGHT'),$client->string('PLUGIN_RATINGSLIGHT_BLOCKED')]}, 3);
				return;
			}
			return unless $digit >= '0' && $digit <= '9';

			my $curTrack = $::VERSION lt '8.2' ? Slim::Player::Playlist::song($client) : Slim::Player::Playlist::track($client);
			if ($digit >= 0 && $digit <=5) {
				$rating100ScaleValue = $digit * 20;
			}

			if ($digit >= 6 && $digit <= 9) {
				my $currentRating = $curTrack->rating || 0;
				if ($digit == 6) {
					$rating100ScaleValue = $currentRating - 20;
				}
				if ($digit == 7) {
					$rating100ScaleValue = $currentRating + 20;
				}
				if ($digit == 8) {
					$rating100ScaleValue = $currentRating - 10;
				}
				if ($digit == 9) {
					$rating100ScaleValue = $currentRating + 10;
				}
				$rating100ScaleValue = ratingSanityCheck($rating100ScaleValue);
			}
			main::DEBUGLOG && $log->is_debug && $log->debug('IR command: button = '.$button.' ## digit = '.$digit.' ## trackURL = '.$curTrack->url.' ## track ID = '.$curTrack->id.' ## rating = '.$rating100ScaleValue);
			VFD_deviceRating($client, undef, undef, $curTrack->id, $curTrack->url, $curTrack, $rating100ScaleValue);
		},
	);
	return \%menuFunctions;
}

sub newPlayerCheck {
	my ($request) = @_;
	my $client = $request->client();
	my $model = getClientModel($client);

	if ((defined $client) && ($request->{_requeststr} eq 'client,new')) {
		foreach my $button (0..9) {
			Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, $button, "modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_$button");
		}
		if ($model eq 'boom') {
			Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, 'arrow_down', "modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_6");
			Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 2, \&mapKeyHold, 'arrow_up', "modefunction_PLUGIN.RatingsLight::Plugin->saveremoteratings_7");
		}
	}
}

sub mapKeyHold {
	# from Peter Watkins' plugin AllQuiet
	my $client = shift;
	my $baseKeyName = shift;
	my $function = shift;
	my $logless = 1;
	if (defined($client)) {
		my $mapsAltered = 0;
		my @maps = @{$client->irmaps};
		for (my $i = 0; $i < scalar(@maps) ; ++$i) {
			if (ref($maps[$i]) eq 'HASH') {
				my %mHash = %{$maps[$i]};
				foreach my $key (keys %mHash) {
					if (ref($mHash{$key}) eq 'HASH') {
						my %mHash2 = %{$mHash{$key}};
						# if no $baseKeyName.hold
						if ((!defined($mHash2{$baseKeyName.'.hold'})) || ($mHash2{$baseKeyName.'.hold'} eq 'dead')) {
							unless (defined $logless) {
								main::DEBUGLOG && $log->is_debug && $log->debug("Mapping $function to ${baseKeyName}.hold for $i-$key");
							}
							if ((defined($mHash2{$baseKeyName}) || (defined($mHash2{$baseKeyName.'.*'}))) && (!defined($mHash2{$baseKeyName.'.single'}))) {
								# make baseKeyName.single = baseKeyName
								$mHash2{$baseKeyName.'.single'} = $mHash2{$baseKeyName};
							}
							# make baseKeyName.hold = $function
							$mHash2{$baseKeyName.'.hold'} = $function;
							# make baseKeyName.repeat = 'dead'
							$mHash2{$baseKeyName.'.repeat'} = 'dead';
							# make baseKeyName.release = 'dead'
							$mHash2{$baseKeyName.'.hold_release'} = 'dead';
							# delete unqualified baseKeyName
							$mHash2{$baseKeyName} = undef;
							# delete baseKeyName.*
							$mHash2{$baseKeyName.'.*'} = undef;
							++$mapsAltered;
						} else {
							unless (defined $logless) {
								main::DEBUGLOG && $log->is_debug && $log->debug("${baseKeyName}.hold mapping already exists for $i-$key");
							}
						}
						$mHash{$key} = \%mHash2;
					}
				}
				$maps[$i] = \%mHash;
			}
		}
		if ($mapsAltered > 0) {
			unless (defined $logless) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Mapping ${baseKeyName}.hold to $function for \"'.$client->name().'\" in $mapsAltered modes");
			}
			$client->irmaps(\@maps);
		}
	}
}


## rating log, playlist

sub addToRecentlyRatedPlaylist {
	my $track = shift;
	my $playlistname = 'Recently Rated Tracks (Ratings Light)';
	my $recentlymaxcount = $prefs->get('recentlymaxcount');
	my $trackAlreadyInPL;

	my $playlist = Slim::Schema->rs('Playlist')->single({'title' => $playlistname});
	if (!$playlist) {
		Slim::Control::Request::executeRequest(undef, ['playlists', 'new', 'name:'.$playlistname]);
		$playlist = Slim::Schema->rs('Playlist')->single({'title' => $playlistname});
	}

	my @PLtracks = $playlist->tracks;
	if (scalar @PLtracks > 0) {
		for my $PLtrack (@PLtracks) {
			if ($PLtrack->id eq $track->id) {
				$trackAlreadyInPL = 1;
				main::DEBUGLOG && $log->is_debug && $log->debug('Track "'.$track->title.'" is already in "Recently Rated Tracks" playlist. Won\'t add duplicate.');
				last;
			}
		}
	}

	unless ($trackAlreadyInPL) {
		my $PLtrackCount = $playlist->tracks->count;
		if (($PLtrackCount > 1) && (($PLtrackCount + 1) > $recentlymaxcount)) {
			my $deleteTrackCount = $PLtrackCount + 1 - $recentlymaxcount;
			$deleteTrackCount = 1 if $deleteTrackCount < 1;
			splice(@PLtracks, 0, $deleteTrackCount);
			main::DEBUGLOG && $log->is_debug && $log->debug("Current playlist track count = $PLtrackCount. Max. allowed playlist track count = $recentlymaxcount. Will remove $deleteTrackCount track(s) from the start of the playlist *before* adding new recently rated track.");
		}

		push @PLtracks, $track;
		$playlist->setTracks(\@PLtracks);
		$playlist->update;
		main::idleStreams();
		Slim::Player::Playlist::scheduleWriteOfPlaylist(undef, $playlist);
		main::DEBUGLOG && $log->is_debug && $log->debug('Added track "'.$track->title.'" to "Recently Rated Tracks" playlist');
	}
}

sub logRatedTrack {
	my ($track, $rating100ScaleValue, $previousRating100ScaleValue) = @_;
	my $ratingtimestamp = strftime "%Y-%m-%d -- %H:%M:%S", localtime time;
	my $logFileName = 'RL_Rating-Log.txt';
	my $logDir = $prefs->get('rlfolderpath');

	# log rotation
	my $fullfilepath = catfile($logDir, $logFileName);
	if (-f $fullfilepath) {
		my $logfilesize = stat($fullfilepath)->size;
		if ($logfilesize > 102400) {
			my $filename_oldlogfile = 'RL_Rating-Log.1.txt';
			my $fullpath_oldlogfile = catfile($logDir, $filename_oldlogfile);
				if (-f $fullpath_oldlogfile) {
					unlink $fullpath_oldlogfile;
				}
			move $fullfilepath, $fullpath_oldlogfile;
		}
	}

	my $title = $track->title;
	my $artist = $track->artist->name;
	my $album = $track->album->title;

	my $previousRating = $previousRating100ScaleValue/20;
	my $newRating = $rating100ScaleValue/20;

	# write log info to file
	my $filename = catfile($logDir, $logFileName);
	my $output = FileHandle->new($filename, '>>:utf8') or do {
		$log->error('Could not open '.$filename.' for writing. Does the RatingsLight folder exist? Does LMS have read/write permissions (755) for the (parent) folder?');
		return;
	};
	print $output $ratingtimestamp."\n";
	print $output "Title:\t ".$title."\nArtist:\t ".$artist."\nAlbum:\t ".$album."\n";
	print $output 'Previous Rating: '.$previousRating.' --> New Rating: '.$newRating."\n\n";
	close $output;
}

sub clearAllRatings {
	my $dontRefresh = shift;
	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: access to rating values blocked until library scan is completed');
		return;
	}

	my $status_clearingallratings = $prefs->get('status_clearingallratings');
	if ($status_clearingallratings == 1) {
		$log->warn('Clearing ratings is already in progress, please wait for the previous action to finish');
		return;
	}
	$prefs->set('status_clearingallratings', 1);
	my $started = time();

	my $status_restoringfrombackup = $prefs->get('status_restoringfrombackup');
	my $sqlunrateall = "update tracks_persistent set rating = null where tracks_persistent.rating >= 0;";
	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare($sqlunrateall);
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

	main::DEBUGLOG && $log->is_debug && $log->debug('Clearing all ratings completed after '.(time() - $started).' seconds.');
	$prefs->set('status_clearingallratings', 0);

	refreshAll() unless $dontRefresh;
}


###### set/get rating ######

sub writeRatingToDB {
	my ($trackID, $trackURL, $trackURLmd5, $track, $rating100ScaleValue, $dontlogthis) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("trackID = ".Data::Dump::dump($trackID)."\ntrackURL = ".Data::Dump::dump($trackURL)."\ntrackURLmd5 = ".Data::Dump::dump($trackURLmd5)."\ntrack obj = ".($track ? 1 : 0)."\nrating = ".Data::Dump::dump($rating100ScaleValue)."\ndontlogthis = ".Data::Dump::dump($dontlogthis));

	if (($rating100ScaleValue < 0) || ($rating100ScaleValue > 100)) {
		$rating100ScaleValue = ratingSanityCheck($rating100ScaleValue);
	}

	# use trackID, trackURLmd5 or trackURL to find track obj
	if (!$track && defined($trackID)) {
		$track = Slim::Schema->rs('Track')->find($trackID);
		main::DEBUGLOG && $log->is_debug && $log->debug('Found track obj using trackID');
	}
	if (!$track && defined($trackURLmd5)) {
		$track = Slim::Schema->rs('Track')->single({'urlmd5' => $trackURLmd5});
		main::DEBUGLOG && $log->is_debug && $log->debug('Found track obj using trackURLmd5');
	}
	if (!$track && defined($trackURL)) {
		$track = Slim::Schema->rs('Track')->objectForUrl($trackURL);
		main::DEBUGLOG && $log->is_debug && $log->debug('Found track obj using trackURL');
	}

	if ($track && blessed $track && (UNIVERSAL::isa($track, 'Slim::Schema::Track') || UNIVERSAL::isa($track, 'Slim::Schema::RemoteTrack'))) {
		my $previousRating100ScaleValue = $track->rating || 0;
		$track->rating($rating100ScaleValue);

		# confirm and log new rating value
		my $newTrackRating = $track->rating;
		if ($newTrackRating == $rating100ScaleValue) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Rating successful. Track title: '.$track->title.' ## New rating = '.$rating100ScaleValue/20);
			unless (defined($dontlogthis)) {
				my $userecentlyratedplaylist = $prefs->get('userecentlyratedplaylist');
				my $uselogfile = $prefs->get('uselogfile');
				if (defined $uselogfile) {
					logRatedTrack($track, $rating100ScaleValue, $previousRating100ScaleValue);
				}
				if (defined $userecentlyratedplaylist) {
					addToRecentlyRatedPlaylist($track);
				}
			}
		} else {
			main::DEBUGLOG && $log->is_debug && $log->debug("Couldn't confirm that the track was successfully rated. Won't add track to rating log file or recently rated playlist. Please check manually if the new track rating has been set.");
		}
	} else {
		$log->error("Couldn't find blessed track (local or remote). Rating failed.");
	}
}

sub getRatingFromDB {
	my $track = shift;
	my $rating100ScaleValue = 0;

	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: access to rating values blocked until library scan is completed');
		return $rating100ScaleValue;
	}

	if ($track && !blessed($track)) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Track is not blessed');
		$track = Slim::Schema->find('Track', $track->{id});
		if (!blessed($track)) {
			main::DEBUGLOG && $log->is_debug && $log->debug('No blessed track object found');
			return $rating100ScaleValue;
		}
	}

	# check if remote track is part of LMS library
	if ((Slim::Music::Info::isRemoteURL($track->url) == 1) && (!defined($track->extid))) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Track is remote but has no extid, probably not part of LMS library. Trying to get rating with url: '.$track->url);
		my $url = $track->url;
		my $urlmd5 = $track->urlmd5 || md5_hex($url);

		my $dbh = Slim::Schema->dbh;
		my $sqlstatement = "select tracks_persistent.rating from tracks_persistent where tracks_persistent.urlmd5 = \"$urlmd5\"";
		eval{
			my $sth = $dbh->prepare($sqlstatement);
			$sth->execute() or do {$sqlstatement = undef;};
			$rating100ScaleValue = $sth->fetchrow || 0;
			$sth->finish();
		};
		if ($@) { main::DEBUGLOG && $log->is_debug && $log->debug("error: $@"); }
		main::DEBUGLOG && $log->is_debug && $log->debug("Found rating $rating100ScaleValue for url: ".$url);
		return adjustRating($rating100ScaleValue);
	}

	# check for dead/moved local tracks
	if ((Slim::Music::Info::isRemoteURL($track->url) != 1) && (!defined($track->filesize))) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Local track with zero filesize in db - track dead or moved??? Track URL: '.$track->url);
		return $rating100ScaleValue;
	}

	my $thisrating = $track->rating;
	$rating100ScaleValue = $thisrating if $thisrating;
	return adjustRating($rating100ScaleValue);
}

sub getRatingTSLegacy {
	my $request = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug('Used TS Legacy dispatch to get rating.');
	main::DEBUGLOG && $log->is_debug && $log->debug('request params = '.Data::Dump::dump($request->getParamsCopy()));
	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: access to rating values blocked until library scan is completed');
		return;
	}

	if ($request->isNotQuery([['trackstat'],['getrating']])) {
		$log->error('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}

	if ($request->isQuery([['trackstat'],['getrating']]) && $request->source !~ /iPeng/) {
		$request->setStatusBadDispatch();
		$log->warn('TS legacy rating is only available for iPeng clients as a temp. workaround. Please use the correct ratingslight dispatch instead.');
		return;
	}

	my $trackID = $request->getParam('_trackid');
	if (defined($trackID) && $trackID =~ /^track_id:(.*)$/) {
		$trackID = $1;
	} elsif (defined($request->getParam('_trackid'))) {
		$trackID = $request->getParam('_trackid');
	} else {
		$request->setStatusBadDispatch();
		$log->error("Can't set rating. No (valid) track ID found. Provided track ID was ".Data::Dump::dump($trackID));
		return;
	}

	my $track = Slim::Schema->find('Track', $trackID);
	my $rating100ScaleValue = getRatingFromDB($track);

	$request->addResult('rating', $rating100ScaleValue/20);
	$request->addResult('ratingpercentage', $rating100ScaleValue);
	$request->setStatusDone();
}

sub getRatingTextLine {
	my $rating100ScaleValue = shift;
	my $appended = shift;
	my $nobreakspace = HTML::Entities::decode_entities('&#xa0;'); # "NO-BREAK SPACE" - HTML Entity (hex): &#xa0;
	my $displayratingchar = $prefs->get('displayratingchar'); # 0 = common text star *, 1 = blackstar 2605
	my $ratingchar = ' *';
	my $fractionchar = HTML::Entities::decode_entities('&#xbd;'); # "vulgar fraction one half" - HTML Entity (hex): &#xbd;

	if ($displayratingchar == 1) {
		$ratingchar = HTML::Entities::decode_entities('&#x2605;'); # "blackstar" - HTML Entity (hex): &#x2605;
	}
	my $text = string('PLUGIN_RATINGSLIGHT_LANGSTRING_UNRATED');

	if ($rating100ScaleValue > 0) {
		my $detecthalfstars = ($rating100ScaleValue/2)%2;
		my $ratingstars = $rating100ScaleValue/20;
		my $spacechar = ' ';
		my $maxlength = 22;
		my $spacescount = 0;

		if ($detecthalfstars == 1) {
			$ratingstars = floor($ratingstars);
			if ($displayratingchar == 1) {
				$text = ($ratingchar x $ratingstars).$fractionchar;
			} else {
				$text = ($ratingchar x $ratingstars).' '.$fractionchar;
			}
		} else {
			$text = ($ratingchar x $ratingstars);
		}
	}

	if (defined $appended) {
		if ($displayratingchar == 1) {
			my $sepchar = HTML::Entities::decode_entities('&#x2022;'); # "bullet" - HTML Entity (hex): &#x2022;
			$text = $nobreakspace.$sepchar.$nobreakspace.$text;
		} else {
			$text = $nobreakspace.'('.$text.$nobreakspace.')';
		}
	}

	return $text;
}

sub adjustRating {
	my $rating100ScaleValue = shift;
	$rating100ScaleValue = int(($rating100ScaleValue + 5)/10) * 10;
	return $rating100ScaleValue;
}

sub ratingValidator {
	my ($rating, $ratingScale) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('rating = '.$rating.' -- ratingScale = '.Data::Dump::dump($ratingScale));
	$rating =~ s/\s+//g; # remove all whitespace characters

	if ($ratingScale && $ratingScale eq 'percent' && (($rating !~ /^\d+\z/) || ($rating < 0 || $rating > 100))) {
		$log->error("Can't set rating. Invalid rating value! Rating values for 'setratingpercent' have to be on a scale from 0 to 100. The provided rating value was ".Data::Dump::dump($rating));
		return undef;
	}

	if (!defined($ratingScale) && (($rating !~ /^\d+(\.5)?\z/) || ($rating < 0 || $rating > 5))) {
		$log->error("Can't set rating. Invalid rating value! Rating values for 'setrating' have to be on a scale from 0 to 5. The provided rating value was ".Data::Dump::dump($rating));
		return undef;
	}
	return $rating;
}

sub ratingSanityCheck {
	my $rating100ScaleValue = shift;
	if ((!defined $rating100ScaleValue) || ($rating100ScaleValue < 0)) {
		return 0;
	}
	if ($rating100ScaleValue > 100) {
		return 100;
	}
	return $rating100ScaleValue;
}



# title formats

sub getTitleFormat_Rating {
	my $track = shift;
	my $appended = shift;
	my $ratingtext = HTML::Entities::decode_entities('&#xa0;'); # "NO-BREAK SPACE" - HTML Entity (hex): &#xa0;

	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: access to rating values blocked until library scan is completed');
		return $ratingtext;
	}

	# get local track if unblessed
	if ($track && !blessed($track)) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Track is not blessed');
		my $trackObj = Slim::Schema->find('Track', $track->{id});
		if (blessed($trackObj)) {
			$track = $trackObj;
		} else {
			my $trackURL = $track->{'url'};
			main::DEBUGLOG && $log->is_debug && $log->debug('Slim::Schema->find found no blessed track object for id. Trying to retrieve track object with url: '.Data::Dump::dump($trackURL));
			if (defined ($trackURL)) {
				if (Slim::Music::Info::isRemoteURL($trackURL) == 1) {
					$track = Slim::Schema->_retrieveTrack($trackURL);
					main::DEBUGLOG && $log->is_debug && $log->debug('Track is remote. Retrieved trackObj = '.Data::Dump::dump($track));
				} else {
					$track = Slim::Schema->rs('Track')->single({'url' => $trackURL});
					main::DEBUGLOG && $log->is_debug && $log->debug('Track is not remote. TrackObj for url = '.Data::Dump::dump($track));
				}
			} else {
				return '';
			}
		}
	}

	if ($track) {
		my $rating100ScaleValue = 0;
		$rating100ScaleValue = getRatingFromDB($track);
		if ($rating100ScaleValue > 0) {
			if (defined $appended) {
				$ratingtext = getRatingTextLine($rating100ScaleValue, 'appended');
			} else {
				$ratingtext = getRatingTextLine($rating100ScaleValue);
			}
		}
	}
	return $ratingtext;
}

sub getTitleFormat_Rating_AppendedStars {
	my $track = shift;
	my $ratingtext = getTitleFormat_Rating($track, 'appended');
	return $ratingtext;
}

sub addTitleFormat {
	my $titleformat = shift;
	my $titleFormats = $serverPrefs->get('titleFormat');
	foreach my $format (@{$titleFormats}) {
		if ($titleformat eq $format) {
			return;
		}
	}
	push @{$titleFormats},$titleformat;
	$serverPrefs->set('titleFormat',$titleFormats);
}

sub refreshTitleFormats {
	for my $client (Slim::Player::Client::clients()) {
		next unless $client && $client->controller();
		main::DEBUGLOG && $log->is_debug && $log->debug("Refreshing title formats on client '".$client->name."'");
		$client->currentPlaylistUpdateTime(Time::HiRes::time());
	}
}



# misc

sub refreshAll {
	Slim::Music::Info::clearFormatDisplayCache();
	refreshTitleFormats();
	refreshVLtimer();
}

sub quickCountSQL {
	my $sqlstatement = shift;

	my $dbh = Slim::Schema->dbh;
	my $trackCount = 0;
	my $sth = $dbh->prepare($sqlstatement);
	$sth->execute();
	$trackCount = $sth->fetchrow || 0;
	$sth->finish();
	main::DEBUGLOG && $log->is_debug && $log->debug('Track count = '.$trackCount);
	return $trackCount;
}

sub createRLfolder {
	my $rlParentFolderPath = $prefs->get('rlparentfolderpath') || Slim::Utils::OSDetect::dirsFor('prefs');
	my $rlFolderPath = catdir($rlParentFolderPath, 'RatingsLight');
	eval {
		mkdir($rlFolderPath, 0755) unless (-d $rlFolderPath);
	} or do {
		$log->error("Could not create RatingsLight folder in parent folder '$rlParentFolderPath'! Please make sure that LMS has read/write permissions (755) for the parent folder.");
		return;
	};
	$prefs->set('rlfolderpath', $rlFolderPath);
}

sub trimStringLength {
	my ($thisString, $maxlength) = @_;
	if (defined $thisString && (length($thisString) > $maxlength)) {
		$thisString = substr($thisString, 0, $maxlength).'...';
	}
	return $thisString;
}

sub getClientModel {
	my $client = shift;
	unless (!defined($client)) {
		my $model = Slim::Player::Client::getClient($client->id)->model;
		return $model;
	}
	return '';
}

*escape = \&URI::Escape::uri_escape_utf8;
*unescape = \&URI::Escape::uri_unescape;

1;
