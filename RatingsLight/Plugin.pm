#
# Ratings Light
#
# (c) 2020-2022 AF-1
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
use Data::Dumper;
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
use URI::Escape qw(uri_escape_utf8 uri_unescape);
use XML::Parser;

use Plugins::RatingsLight::Common ':all';
use Plugins::RatingsLight::Importer;
use Plugins::RatingsLight::Settings::Basic;
use Plugins::RatingsLight::Settings::Backup;
use Plugins::RatingsLight::Settings::Import;
use Plugins::RatingsLight::Settings::Export;
use Plugins::RatingsLight::Settings::Menus;
use Plugins::RatingsLight::Settings::DSTM;

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.ratingslight',
	'defaultLevel' => 'WARN',
	'description' => 'PLUGIN_RATINGSLIGHT',
});

my $prefs = preferences('plugin.ratingslight');
my $serverPrefs = preferences('server');

my (%restoreitem, $currentKey, $inTrack, $inValue, $backupParser, $backupParserNB, $restorestarted);
my $opened = 0;

sub initPlugin {
	my $class = shift;

	initPrefs();
	initIR();

	Slim::Control::Request::addDispatch(['ratingslight', 'setrating', '_trackid', '_rating', '_incremental'], [1, 0, 1, \&setRating]);
	Slim::Control::Request::addDispatch(['ratingslight', 'setratingpercent', '_trackid', '_rating', '_incremental'], [1, 0, 1, \&setRating]);
	Slim::Control::Request::addDispatch(['ratingslight', 'ratingmenu', '_trackid'], [0, 1, 1, \&getRatingMenu]);
	Slim::Control::Request::addDispatch(['ratingslight', 'ratedtracksmenu', '_trackid', '_thisid', '_objecttype'], [0, 1, 1, \&getRatedTracksMenu]);
	Slim::Control::Request::addDispatch(['ratingslight', 'actionsmenu'], [0, 1, 1, \&getActionsMenu]);
	Slim::Control::Request::addDispatch(['ratingslight', 'changedrating', '_url', '_trackid', '_rating', '_ratingpercent'], [0, 0, 0, undef]);
	Slim::Control::Request::addDispatch(['ratingslightchangedratingupdate'], [0, 1, 0, undef]);

	Slim::Control::Request::subscribe(\&setRefreshCBTimer,[['rescan'],['done']]);

	Slim::Web::HTTP::CSRF->protectCommand('ratingslight');

	addTitleFormat('RL_RATING_STARS');
	Slim::Music::TitleFormatter::addFormat('RL_RATING_STARS',\&getTitleFormat_Rating);

	addTitleFormat('RL_RATING_STARS_APPENDED');
	Slim::Music::TitleFormatter::addFormat('RL_RATING_STARS_APPENDED',\&getTitleFormat_Rating_AppendedStars);

	if (main::WEBUI) {
		Plugins::RatingsLight::Settings::Basic->new($class);
		Plugins::RatingsLight::Settings::Backup->new($class);
		Plugins::RatingsLight::Settings::Import->new($class);
		Plugins::RatingsLight::Settings::Export->new($class);
		Plugins::RatingsLight::Settings::Menus->new($class);
		Plugins::RatingsLight::Settings::DSTM->new($class);

		Slim::Web::Pages->addPageFunction('showratedtrackslist', \&handleRatedWebTrackList);
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

	if (Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin')) {
		require Slim::Plugin::DontStopTheMusic::Plugin;

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

	initExportBaseFilePathMatrix();
	$class->SUPER::initPlugin(@_);
}

sub initPrefs {
	$prefs->init({
		rlparentfolderpath => $serverPrefs->get('playlistdir'),
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
		ratedtracksweblimit => 60,
		ratedtrackscontextmenulimit => 60,
		dstm_minTrackDuration => 90,
		dstm_percentagerated => 30,
		dstm_percentagetoprated => 30,
		dstm_num_seedtracks => 10,
		dstm_playedtrackstokeep => 5,
		dstm_batchsizenewtracks => 20
	});

	createRLfolder();

	$prefs->setValidate(sub {
		return if (!$_[1] || !(-d $_[1]) || (main::ISWINDOWS && !(-d Win32::GetANSIPathName($_[1]))) || !(-d Slim::Utils::Unicode::encode_locale($_[1])));
		my $rlFolderPath = catdir($_[1], 'RatingsLight');
		eval {
			mkdir($rlFolderPath, 0755) unless (-d $rlFolderPath);
			chdir($rlFolderPath);
		} or do {
			$log->warn("Could not create or access RatingsLight folder in parent folder '$_[1]'!");
			return;
		};
		$prefs->set('rlfolderpath', $rlFolderPath);
		return 1;
	}, 'rlparentfolderpath');

	$prefs->set('ratethisplaylistid', '');
	$prefs->set('ratethisplaylistrating', '');
	$prefs->set('exportVL_id', '');
	$prefs->set('status_exportingtoplaylistfiles', '0');
	$prefs->set('status_importingfromcommentstags', '0');
	$prefs->set('status_importingfromBPMtags', '0');
	$prefs->set('status_batchratingplaylisttracks', '0');
	$prefs->set('status_creatingbackup', '0');
	$prefs->set('status_restoringfrombackup', '0');
	$prefs->set('status_clearingallratings', '0');
	$prefs->set('postScanScheduleDelay', '5');

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
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 5, 'high' => 100}, 'ratedtrackscontextmenulimit');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 0, 'high' => 1800}, 'dstm_minTrackDuration');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 0, 'high' => 100}, 'dstm_percentagerated');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 0, 'high' => 100}, 'dstm_percentagetoprated');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 1, 'high' => 20}, 'dstm_num_seedtracks');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 1, 'high' => 200}, 'dstm_playedtrackstokeep');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 5, 'high' => 50}, 'dstm_batchsizenewtracks');
	$prefs->setValidate('file', 'restorefile');

	$prefs->setChange(\&Plugins::RatingsLight::Importer::toggleUseImporter, 'autoscan');
	$prefs->setChange(\&initVirtualLibraries, 'browsemenus_sourceVL_id', 'showratedtracksmenus');
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

	# temp. workaround to allow legacy TS rating in iPeng until iPeng supports RL or is discontinued
	if ($prefs->get('enableipengtslegacyrating') && !Slim::Utils::PluginManager->isEnabled('Plugins::TrackStat::Plugin')) {
		Slim::Control::Request::addDispatch(['trackstat', 'getrating', '_trackid'], [0, 1, 0, \&getRatingTSLegacy]);
		Slim::Control::Request::addDispatch(['trackstat', 'setrating', '_trackid', '_rating', '_incremental'], [1, 0, 1, \&setRating]);
		Slim::Control::Request::addDispatch(['trackstat', 'setratingpercent', '_trackid', '_rating', '_incremental'], [1, 0, 1, \&setRating]);
		Slim::Control::Request::addDispatch(['trackstat', 'changedrating', '_url', '_trackid', '_rating', '_ratingpercent'],[0, 0, 0, undef]);
	}
}


## set ratings

sub setRating {
	my $request = shift;
	$log->debug('request params = '.Dumper($request->getParamsCopy()));
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

	my $trackId = $request->getParam('_trackid');
	if (defined($trackId) && $trackId =~ /^track_id:(.*)$/) {
		$trackId = $1;
	} elsif (defined($request->getParam('_trackid'))) {
		$trackId = $request->getParam('_trackid');
	} else {
		$log->error("Can't set rating. No (valid) track ID found. Provided track ID was ".Dumper($trackId));
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

	if (!defined $trackId || $trackId eq '' || !defined $rating || $rating eq '') {
		$request->setStatusBadParams();
		return;
	}

	my $track = Slim::Schema->resultset('Track')->find($trackId);
	my $trackURL = $track->url;

	# check if remote track is part of online library
	if ((Slim::Music::Info::isRemoteURL($trackURL) == 1) && (!defined($track->extid))) {
		$log->debug('track is remote but not part of online library');
		return;
	}

	# check for dead/moved local tracks
	if ((Slim::Music::Info::isRemoteURL($trackURL) != 1) && (!defined($track->filesize))) {
		$log->debug('track dead or moved??? Track URL: '.$trackURL);
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

	writeRatingToDB($trackURL, $rating100ScaleValue);

	Slim::Control::Request::notifyFromArray($client, ['ratingslight', 'changedrating', $trackURL, $trackId, $rating100ScaleValue/20, $rating100ScaleValue]);
	Slim::Control::Request::notifyFromArray(undef, ['ratingslightchangedratingupdate', $trackURL, $trackId, $rating100ScaleValue/20, $rating100ScaleValue]);

	$request->addResult('rating', $rating100ScaleValue/20);
	$request->addResult('ratingpercentage', $rating100ScaleValue);
	$request->setStatusDone();
	refreshAll();
}

sub VFD_deviceRating {
	my ($client, $callback, $params, $trackURL, $trackID, $rating) = @_;

	$log->debug('VFD_deviceRating - trackURL = '.$trackURL);
	$log->debug('VFD_deviceRating - trackID = '.$trackID);
	$log->debug('VFD_deviceRating - rating = '.$rating);
	my $track = Slim::Schema->resultset('Track')->find($trackID);

	# check if remote track is part of online library
	if ((Slim::Music::Info::isRemoteURL($trackURL) == 1) && (!defined($track->extid))) {
		$log->debug('track is remote but not part of online library');
		return;
	}

	# check for dead/moved local tracks
	if ((Slim::Music::Info::isRemoteURL($trackURL) != 1) && (!defined($track->filesize))) {
		$log->debug('track dead or moved??? Track URL: '.$trackURL);
		return;
	}
	writeRatingToDB($trackURL, $rating);

	my $cbtext = string('PLUGIN_RATINGSLIGHT_RATING').' '.(getRatingTextLine($rating));
	$callback->([{
		type => 'text',
		name => $cbtext,
		showBriefly => 1, popback => 3,
		favorites => 0, refresh => 1,
	}]);

	Slim::Control::Request::notifyFromArray($client, ['ratingslight', 'changedrating', $trackURL, $trackID, $rating/20, $rating]);
	Slim::Control::Request::notifyFromArray(undef, ['ratingslightchangedratingupdate', $trackURL, $trackID, $rating/20, $rating]);
	refreshAll();
}


### infohandlers, context menus

## rating menu
sub trackInfoHandlerRating {
	my $rating100ScaleValue = 0;
	my $ratingcontextmenusethalfstars = $prefs->get('ratingcontextmenusethalfstars');
	my $text = string('PLUGIN_RATINGSLIGHT_RATING');

	my ($client, $url, $track, $remoteMeta, $tags) = @_;
	$tags ||= {};

	if (Slim::Music::Import->stillScanning) {
		if ($tags->{menuMode}) {
			my $jive = {};
			return {
				type => '',
				name => $text.' '.string('PLUGIN_RATINGSLIGHT_BLOCKED'),
				jive => $jive,
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
		$log->debug('track is remote but not part of online library');
		return;
	}

	# check for dead/moved local tracks
	if ((Slim::Music::Info::isRemoteURL($url) != 1) && (!defined($track->filesize))) {
		$log->debug('track dead or moved??? Track URL: '.$url);
		return;
	}

	$rating100ScaleValue = getRatingFromDB($track);
	$text = string('PLUGIN_RATINGSLIGHT_RATING').' '.(getRatingTextLine($rating100ScaleValue));

	if ($tags->{menuMode}) {
		my $jive = {};
		my $actions = {
			go => {
				player => 0,
				cmd => ['ratingslight', 'ratingmenu', $track->id],
			},
		};
		$jive->{actions} = $actions;

		return {
			type => 'redirect',
			name => $text,
			jive => $jive,
		};
	} else {
		my $item = {
			type => 'text',
			name => $text,
			itemvalue => $rating100ScaleValue,
			itemvalue5starexact => $rating100ScaleValue/20,
			itemid => $track->id,
			web => {
				'type' => 'htmltemplate',
				'value' => 'plugins/RatingsLight/html/trackratinginfo.html'
			},
		};

		delete $item->{type};
		my @ratingValues = ();
		if (defined $ratingcontextmenusethalfstars) {
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
				passthrough => [$url, $track->id, $ratingValue],
			});
		}
		$item->{items} = \@items;
		return $item;
	}
}

sub getRatingMenu {
	my $request = shift;
	my $client = $request->client();
	my $ratingcontextmenusethalfstars = $prefs->get('ratingcontextmenusethalfstars');

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
	my $cnt = 0;

	my @ratingValues = ();
	if (defined $ratingcontextmenusethalfstars) {
		@ratingValues = qw(100 90 80 70 60 50 40 30 20 10 0);
	} else {
		@ratingValues = qw(100 80 60 40 20 0);
	}

	foreach my $rating (@ratingValues) {
		my $actions = {
			'do' => {
				'cmd' => ['ratingslight', 'setratingpercent', $track_id, $rating]
			},
			'play' => {
				'cmd' => ['ratingslight', 'setratingpercent', $track_id, $rating]
			},
		};

		my $text = getRatingTextLine($rating);
		$request->addResultLoop('item_loop', $cnt, 'text', $text);
		$request->addResultLoop('item_loop', $cnt, 'actions', $actions);
		$request->addResultLoop('item_loop', $cnt, 'nextWindow', 'parent');
		$cnt++;
	}

	$request->addResult('offset', 0);
	$request->addResult('count', $cnt);
	$request->setStatusDone();
}

## show rated tracks menus (web & jive)
# web
sub handleRatedWebTrackList {
	my $ratedtracksweblimit = $prefs->get('ratedtracksweblimit');
	my ($client, $params, $callback, $httpClient, $response) = @_;

	my $trackID = $params->{trackid} || 0;
	my $objectType = $params->{objecttype};
	my $objectID = $params->{objectid};
	my $objectName = $params->{objectname};
	$log->debug('objectType = '.$objectType.' ## objectID = '.$objectID.' ## trackID = '.$trackID);

	my $ratedtracks = getRatedTracks(0, $client, $objectType, $objectID, $trackID, $ratedtracksweblimit);

	my @ratedtracks_webpage = ();
	my @alltrackids = ();

	foreach my $ratedtrack (@{$ratedtracks}) {
		my $track_id = $ratedtrack->id;
		my $tracktitle = trimStringLength($ratedtrack->title, 70);
		my $rating = getRatingFromDB($ratedtrack);
		my $ratingtext = getRatingTextLine($rating, 'appended');
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

# jive
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
	$log->debug('objectType = '.$objectType.' ## thisID = '.$thisID.' ## trackID = '.$trackID);

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
		my $rating = getRatingFromDB($ratedtrack);
		$ratingtext = getRatingTextLine($rating, 'appended');
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
			itemcmd2 => 'items',
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
			$cnt++;
		}
	}
	$request->addResult('offset',0);
	$request->addResult('count',$cnt);
	$request->setStatusDone();
}

# VF devices (only objectType trackArtist + trackAlbum)
sub VFD_ratedtracks {
	my ($client, $objectType, $thisID, $trackID) = @_;
	my $ratedtrackscontextmenulimit = $prefs->get('ratedtrackscontextmenulimit');
	$log->debug('objectType = '.$objectType.' ## thisID = '.$thisID.' ## trackID = '.$trackID);

	my $ratedtracks = getRatedTracks(0, $client, $objectType, $thisID, $trackID, $ratedtrackscontextmenulimit);
	my @vfd_ratedtracks = ();
	my @alltrackids = ();

	foreach my $ratedtrack (@{$ratedtracks}) {
		my $track_id = $ratedtrack->id;
		push @alltrackids, $track_id;
		my $tracktitle = $ratedtrack->title;
		$tracktitle = trimStringLength($tracktitle, 70);

		my $rating = getRatingFromDB($ratedtrack);
		my $ratingtext = getRatingTextLine($rating, 'appended');
		$tracktitle = $tracktitle.$ratingtext;
		push (@vfd_ratedtracks, {
			type => 'redirect',
			name => $tracktitle,
			items => [
				{	name => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNOW'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$track_id, 'load', string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNOW_MSG')],
				},
				{	name => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNEXT'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$track_id, 'insert', string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNEXT_MSG')],
				},
				{	name => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_APPEND'),
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
				{	name => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNOW'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$listalltrackids, 'load', string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNOW_MSG_ALL')],
				},
				{	name => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNEXT'),
					type => 'redirect',
					url => \&VFD_execActions,
					passthrough => [$listalltrackids, 'insert', string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_PLAYNEXT_MSG_ALL')],
				},
				{	name => string('PLUGIN_RATINGSLIGHT_MENUS_RATEDTRACKS_MENU_APPEND'),
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
	$log->debug('action = '.$action);

	my @actionargs = ('playlistcontrol', 'cmd:'.$action, 'track_id:'.$trackID);
	$client->execute(\@actionargs);

	$callback->([{
		type => 'text',
		name => $cbtext,
		showBriefly => 1, popback => 2,
		favorites => 0, refresh => 1
	}]);
}

# common subs
sub getRatedTracks {
	my ($countOnly, $client, $objectType, $thisID, $trackID, $listlimit) = @_;
	$log->debug('objectType = '.$objectType.' ## countOnly = '.$countOnly.' ## trackID = '.$trackID.' ## thisID = '.$thisID);

	if (($objectType ne 'artist') && ($objectType ne 'album') && ($objectType ne 'genre') && ($objectType ne 'year') && ($objectType ne 'decade') && ($objectType ne 'playlist')) {
		$log->warn('No valid objectType');
		return 0;
	}

	my $ratedtrackscontextmenulimit = $prefs->get('ratedtrackscontextmenulimit');
	my $currentLibrary = Slim::Music::VirtualLibraries->getLibraryIdForClient($client);
	my $sqlstatement;

	if ($objectType eq 'artist'){
		$sqlstatement = $countOnly == 1 ? "select count(*)" : "select tracks.url";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= " from tracks join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 join library_track on library_track.track = tracks.id and library_track.library = \"$currentLibrary\" where tracks.primary_artist = $thisID and tracks.id != $trackID";
		} else {
			$sqlstatement .= " from tracks join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 where tracks.primary_artist = $thisID and tracks.id != $trackID";
		}
		$sqlstatement .= " limit $listlimit" if ($countOnly == 0);
	}

	if ($objectType eq 'album') {
		$sqlstatement = $countOnly == 1 ? "select count(*)" : "select tracks.url";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= " from tracks join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 join library_track on library_track.track = tracks.id and library_track.library = \"$currentLibrary\" where tracks.album = $thisID and tracks.id != $trackID";
		} else {
			$sqlstatement .= " from tracks join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 where tracks.album = $thisID and tracks.id != $trackID";
		}
		$sqlstatement .= " limit $listlimit" if ($countOnly == 0);
	}

	if ($objectType eq 'genre') {
		$sqlstatement = $countOnly == 1 ? "select count(*)" : "select tracks.url";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= " from tracks join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 join genre_track on genre_track.track = tracks.id and genre_track.genre = $thisID join library_track on library_track.track = tracks.id and library_track.library = \"$currentLibrary\" where tracks.id != $trackID";
		} else {
			$sqlstatement .= " from tracks join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 join genre_track on genre_track.track = tracks.id and genre_track.genre = $thisID where tracks.id != $trackID";
		}
		$sqlstatement .= " order by random() limit $listlimit" if ($countOnly == 0);
	}

	if (($objectType eq 'year') || ($objectType eq 'decade')) {
		$sqlstatement = $countOnly == 1 ? "select count(*)" : "select tracks.url";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= " from tracks join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 join library_track on library_track.track = tracks.id and library_track.library = \"$currentLibrary\" where tracks.id != $trackID and ";
			if ($objectType eq 'decade') {
				$sqlstatement .= "tracks.year >= $thisID and tracks.year < ($thisID + 10)";
			} else {
				$sqlstatement .= "tracks.year = $thisID";
			}
		} else {
			$sqlstatement .= " from tracks join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 where tracks.id != $trackID and ";
			if ($objectType eq 'decade') {
				$sqlstatement .= "tracks.year >= $thisID and tracks.year < ($thisID + 10)";
			} else {
				$sqlstatement .= "tracks.year = $thisID";
			}
		}
		$sqlstatement .= " order by random() limit $listlimit" if ($countOnly == 0);
	}

	if ($objectType eq 'playlist'){
		$sqlstatement = $countOnly == 1 ? "select count(*)" : "select tracks.url";
		if ((defined $currentLibrary) && ($currentLibrary ne '')) {
			$sqlstatement .= " from tracks join playlist_track on playlist_track.track = tracks.url and playlist_track.playlist = $thisID join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 join library_track on library_track.track = tracks.id and library_track.library = \"$currentLibrary\" where tracks.id != $trackID";
		} else {
			$sqlstatement .= " from tracks join playlist_track on playlist_track.track = tracks.url and playlist_track.playlist = $thisID join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 where tracks.id != $trackID";
		}
		$sqlstatement .= " limit $listlimit" if ($countOnly == 0);
	}

	my @ratedtracks = ();
	my $trackCount = 0;
	my $dbh = getCurrentDBH();
	eval{
		my $sth = $dbh->prepare($sqlstatement);
		$sth->execute() or do {$sqlstatement = undef;};

		if ($countOnly == 1) {
			$trackCount = $sth->fetchrow;
		} else {
			my ($trackURL, $track);
			$sth->bind_col(1,\$trackURL);

			while ($sth->fetch()) {
				$track = Slim::Schema->resultset('Track')->objectForUrl($trackURL);
				push @ratedtracks, $track;
			}
		}
		$sth->finish();
	};
	if ($@) {$log->debug("error: $@");}

	if ($countOnly == 1) {
		$log->debug('Pre-check found '.$trackCount.($trackCount == 1 ? ' rated track' : ' rated tracks')." for $objectType with ID: $thisID");
		return $trackCount;
	} else {
		$log->debug('Fetched '.scalar (@ratedtracks).(scalar (@ratedtracks) == 1 ? ' rated track' : ' rated tracks')." for $objectType with ID: $thisID");
		return \@ratedtracks;
	}
}

sub objectInfoHandler {
	my ($objectType, $client, $url, $obj, $remoteMeta, $tags) = @_;
	$tags ||= {};
	$log->debug('objectType = '.$objectType.' ## url = '.Dumper($url));
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
			$log->debug('track is remote but not part of online library: '.$url);
			return;
		}

		# check for dead/moved local tracks
		if ((Slim::Music::Info::isRemoteURL($url) != 1) && (!defined($obj->filesize))) {
			$log->debug('track dead or moved??? Track URL: '.$url);
			return;
		}
	}
	my $menuItemTitlePrefixString;

	if ($objectType eq 'trackAlbum') {
		$objectType = 'album';
		$trackID = $objectID;
		$objectID = $obj->album->id;
		$objectName = $obj->album->name;
		$curTrackRating = getRatingFromDB($obj);
		$vfd = 1;
	}

	if ($objectType eq 'trackArtist') {
		$objectType = 'artist';
		$trackID = $objectID;
		$objectID = $obj->artist->id;
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


## import, export

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
	my $rating = $prefs->get('ratethisplaylistrating');
	my $queryresult = Slim::Control::Request::executeRequest(undef, ['playlists', 'tracks', '0', $playlistimport_maxtracks, 'playlist_id:'.$playlistid, 'tags:Eux']);
	my $statuscode = $queryresult->{'_status'};
	$log->debug('status of query result = '.$statuscode);
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
			my $trackURL = $playlisttrack->{url};
			if (defined($playlisttrack->{'remote'}) && ($playlisttrack->{'remote'} == 1)) {
				if (!defined($playlisttrack->{'extid'})) {
					$log->debug('track is remote but not part of online library: '.$trackURL);
					$playlisttrackcount--;
					$ignoredtracks++;
					next;
				}
				push @ratableTracks, $trackURL;
			} else {
				my $thistrack = Slim::Schema->resultset('Track')->objectForUrl($trackURL);
				if (!defined($thistrack->filesize)) {
					$log->debug('ignoring this track, track dead or moved??? Track URL: '.$trackURL);
					$playlisttrackcount--;
					$ignoredtracks++;
					next;
				}
				push @ratableTracks, $trackURL;
			}
		}

		if (scalar (@ratableTracks) > 0) {
			foreach my $thisTrackURL (@ratableTracks) {
				writeRatingToDB($thisTrackURL, $rating, 0);
			}
			$log->info('Playlist (ID: '.$playlistid.') contained '.(scalar (@ratableTracks)).(scalar (@ratableTracks) == 1 ? ' track' : ' tracks').' that could be rated.');
			refreshAll();
		} else {
			$log->info('Playlist (ID: '.$playlistid.') contained no tracks that could be rated.');
		}
		if ($ignoredtracks > 0) {
			$log->warn($ignoredtracks.($ignoredtracks == 1 ? ' track was' : ' tracks were')." ignored in total (couldn't be rated). Set log level to INFO for more details.");
		}
	}
	my $ended = time() - $started;

	$log->debug('Rating playlist tracks completed after '.$ended.' seconds.');
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
	my $dbh = getCurrentDBH();
	my $exporttimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;
	my $filename_timestamp = strftime "%Y%m%d-%H%M", localtime time;
	my $exportVL_id = $prefs->get('exportVL_id');
	$log->debug('exportVL_id = '.$exportVL_id);
	my $totaltrackcount = 0;
	my $rating100ScaleValueCeil = 0;

	for (my $rating100ScaleValue = 10; $rating100ScaleValue <= 100; $rating100ScaleValue = $rating100ScaleValue + 10) {
		$rating100ScaleValueCeil = $rating100ScaleValue + 9;
		if (defined $onlyratingsnotmatchtags) {
			# comments tags
			if ($filetagtype == 1) {
				if ((!defined $rating_keyword_prefix || $rating_keyword_prefix eq '') && (!defined $rating_keyword_suffix || $rating_keyword_suffix eq '')) {
					$log->warn('Error: no rating keywords found.');
					return
				} else {
					if ((defined $exportVL_id) && ($exportVL_id ne '')) {
							$sql = "select tracks.url, tracks.remote from tracks join tracks_persistent persistent on persistent.urlmd5 = tracks.urlmd5 and (persistent.rating >= $rating100ScaleValue and persistent.rating <= $rating100ScaleValueCeil) join library_track on library_track.track = tracks.id and library_track.library = \"$exportVL_id\" where tracks.audio = 1 and persistent.urlmd5 in (select tracks.urlmd5 from tracks left join comments on comments.track = tracks.id where (comments.value not like ? or comments.value is null))";
					} else {
							$sql = "select tracks_persistent.url, tracks.remote from tracks_persistent join tracks on tracks.urlmd5 = tracks_persistent.urlmd5 where (tracks_persistent.rating >= $rating100ScaleValue and tracks_persistent.rating <= $rating100ScaleValueCeil and tracks_persistent.urlmd5 in (select tracks.urlmd5 from tracks left join comments on comments.track = tracks.id where (comments.value not like ? or comments.value is null)))";
					}
					$sth = $dbh->prepare($sql);
					my $ratingkeyword = "%%".$rating_keyword_prefix.($rating100ScaleValue/20).$rating_keyword_suffix."%%";
					$sth->bind_param(1, $ratingkeyword);
				}
			# BPM tags
			} elsif ($filetagtype == 0) {
				if ((defined $exportVL_id) && ($exportVL_id ne '')) {
						$sql = "select tracks.url, tracks.remote from tracks join tracks_persistent persistent on persistent.urlmd5 = tracks.urlmd5 and (persistent.rating >= $rating100ScaleValue and persistent.rating <= $rating100ScaleValueCeil) join library_track on library_track.track = tracks.id and library_track.library = \"$exportVL_id\" where tracks.audio = 1 and persistent.urlmd5 in (select tracks.urlmd5 from tracks where (tracks.bpm != $rating100ScaleValue or tracks.bpm is null))";
				} else {
						$sql = "select tracks_persistent.url, tracks.remote from tracks_persistent join tracks on tracks.urlmd5 = tracks_persistent.urlmd5 where (tracks_persistent.rating >= $rating100ScaleValue and tracks_persistent.rating <= $rating100ScaleValueCeil and tracks_persistent.urlmd5 in (select tracks.urlmd5 from tracks where (tracks.bpm != $rating100ScaleValue or tracks.bpm is null)))";
				}
				$sth = $dbh->prepare($sql);
			}
		} else {
			if ((defined $exportVL_id) && ($exportVL_id ne '')) {
				$sql = "select tracks.url, tracks.remote from tracks join tracks_persistent persistent on persistent.urlmd5 = tracks.urlmd5 and (persistent.rating >= $rating100ScaleValue and persistent.rating <= $rating100ScaleValueCeil) join library_track on library_track.track = tracks.id and library_track.library = \"$exportVL_id\" where tracks.audio = 1";
			} else {
				$sql = "select tracks_persistent.url, tracks.remote from tracks_persistent join tracks on tracks.urlmd5 = tracks_persistent.urlmd5 where (tracks_persistent.rating >= $rating100ScaleValue and tracks_persistent.rating <= $rating100ScaleValueCeil)";
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

			my $filename = catfile($exportDir, $PLfilename);
			my $output = FileHandle->new($filename, '>:utf8') or do {
				$log->warn('could not open '.$filename.' for writing.');
				$prefs->set('status_exportingtoplaylistfiles', 0);
				return;
			};
			print $output '#EXTM3U'."\n";
			print $output '# exported with \'Ratings Light\' LMS plugin ('.$exporttimestamp.")\n";
			if ((defined $exportVL_id) && ($exportVL_id ne '')) {
				my $exportVL_name = Slim::Music::VirtualLibraries->getNameForId($exportVL_id);
				print $output '# tracks from library (view): '.$exportVL_name."\n";
			}
			print $output '# contains '.$trackcount.($trackcount == 1 ? ' track' : ' tracks').' rated '.(($rating100ScaleValue/20) == 1 ? ($rating100ScaleValue/20).' star' : ($rating100ScaleValue/20).' stars')."\n\n";
			if (defined $onlyratingsnotmatchtags) {
				print $output "# *** This export only contains rated tracks whose ratings differ from the rating value derived from their comments tag keywords. ***\n";
				print $output "# *** If you want to export ALL rated tracks change the preference on the Ratings Light settings page. ***\n\n";
			}
			for my $ratedTrack (@ratedTracks) {
				my $ratedTrackURL = $ratedTrack->{'url'};
				my $ratedTrackURL_extURL = changeExportFilePath($ratedTrackURL, 1) if ($ratedTrack->{'remote'} != 1);

				print $output '#EXTURL:'.$ratedTrackURL_extURL."\n" if $ratedTrackURL_extURL && $ratedTrackURL_extURL ne '';
				my $ratedTrackPath = Slim::Utils::Unicode::utf8decode_locale(pathForItem($ratedTrackURL));
				$ratedTrackPath = changeExportFilePath($ratedTrackPath) if ($ratedTrack->{'remote'} != 1);
				print $output $ratedTrackPath."\n";
			}
			close $output;
		}
	}

	$log->debug('TOTAL number of tracks exported: '.$totaltrackcount);
	$prefs->set('status_exportingtoplaylistfiles', 0);
	my $ended = time() - $started;
	$prefs->set('exportVL_id', '');
	$log->debug('Export completed after '.$ended.' seconds.');
}

sub changeExportFilePath {
	my $trackURL = shift;
	my $isEXTURL = shift;
	my $exportbasefilepathmatrix = $prefs->get('exportbasefilepathmatrix');

	if (scalar @{$exportbasefilepathmatrix} > 0) {
		my $oldtrackURL = $trackURL;
		my $escaped_trackURL = uri_escape_utf8($trackURL);
		my $exportextension = $prefs->get('exportextension');
		my $exportExtensionExceptionsString = $prefs->get('exportextensionexceptions');

		foreach my $thispath (@{$exportbasefilepathmatrix}) {
			my $lmsbasepath = $thispath->{'lmsbasepath'};
			if ($isEXTURL) {
				$lmsbasepath =~ s/\\/\//isg;
			}
			my $escaped_lmsbasepath = uri_escape_utf8($lmsbasepath);

			if (($escaped_trackURL =~ $escaped_lmsbasepath) && (defined ($thispath->{'substitutebasepath'})) && (($thispath->{'substitutebasepath'}) ne '')) {
				my $substitutebasepath = $thispath->{'substitutebasepath'};
				if ($isEXTURL) {
					$substitutebasepath =~ s/\\/\//isg;
				}
				my $escaped_substitutebasepath = uri_escape_utf8($substitutebasepath);

				if (defined $exportextension && $exportextension ne '') {
					my ($LMSfileExtension) = $escaped_trackURL =~ /(\.[^.]*)$/;
					$LMSfileExtension =~ s/\.//s;
					$log->debug("LMS file extension is '$LMSfileExtension'");

					# file extension replacement - exceptions
					my %extensionExceptionsHash;
					if (defined $exportExtensionExceptionsString && $exportExtensionExceptionsString ne '') {
						$exportExtensionExceptionsString =~ s/ //g;
						%extensionExceptionsHash = map {$_ => 1} (split /,/, lc($exportExtensionExceptionsString));
						$log->debug('extensionExceptionsHash = '.Dumper(\%extensionExceptionsHash));
					}

					if ((scalar keys %extensionExceptionsHash > 0) && $extensionExceptionsHash{lc($LMSfileExtension)}) {
						$log->debug("The file extension '$LMSfileExtension' is not replaced because it is included in the list of exceptions.");
					} else {
						$escaped_trackURL =~ s/\.[^.]*$/\.$exportextension/isg;
					}
				}
				$escaped_trackURL =~ s/$escaped_lmsbasepath/$escaped_substitutebasepath/isg;
				$trackURL = Encode::decode('utf8', uri_unescape($escaped_trackURL));

				if ($isEXTURL) {
					$trackURL =~ s/ /%20/isg;
				} else {
					$trackURL = Slim::Utils::Unicode::utf8decode_locale($trackURL);
				}
				$log->debug('old url: '.$oldtrackURL."\nlmsbasepath = ".$lmsbasepath."\nsubstitutebasepath = ".$substitutebasepath."\nnew url = ".$trackURL);
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

sub setRefreshCBTimer {
	$log->debug('Killing existing timers for post-scan refresh to prevent multiple calls');
	Slim::Utils::Timers::killOneTimer(undef, \&delayedPostScanRefresh);
	$log->debug('Scheduling a delayed post-scan refresh');
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $prefs->get('postScanScheduleDelay'), \&delayedPostScanRefresh);
}

sub delayedPostScanRefresh {
	if (Slim::Music::Import->stillScanning) {
		$log->debug('Scan in progress. Waiting for current scan to finish.');
		setRefreshCBTimer();
	} else {
		$log->debug('Starting post-scan refresh after ratings import from comments tags');
		refreshAll();
	}
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
				$log->debug(parse_duration($timesleft)." ($timesleft seconds) left until next scheduled backup");
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
			clearAllRatings();
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
			$log->warn('Couldn\'t open backup file: '.$restorefile);
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
		$line =~ s/&#(\d*);/uri_escape_utf8(chr($1))/ge;
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

	my $ended = time() - $restorestarted;
	$log->debug('Restore completed after '.$ended.' seconds.');
	sleep 0.5;
	refreshAll();

	$prefs->set('status_restoringfrombackup', 0);
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
	my $selectiverestore = $prefs->get('selectiverestore');

	if ($inTrack && $element eq 'track') {
		$inTrack = 0;

		my $curTrack = \%restoreitem;
		my $remote = $curTrack->{'remote'};

		if (($selectiverestore == 0) || ($selectiverestore == 1 && $remote == 0) || ($selectiverestore == 2 && $remote == 1)) {
			my $trackURL = undef;
			my $fullTrackURL = $curTrack->{'url'};
			my $relTrackURL = $curTrack->{'relurl'};
			my $rating = $curTrack->{'rating'};

			# check if FULL file url is valid
			# Otherwise, try RELATIVE file URL with current media dirs
			$fullTrackURL = Encode::decode('utf8', uri_unescape($fullTrackURL));
			$relTrackURL = Encode::decode('utf8', uri_unescape($relTrackURL));

			my $fullTrackPath = pathForItem($fullTrackURL);
			if (-f $fullTrackPath) {
				#$log->debug("found file at url \"$fullTrackPath\"");
				$trackURL = $fullTrackURL;
			} else {
				$log->debug("** Couldn't find file for FULL file url. Will try with RELATIVE file url and current LMS media folders.");
				my $lmsmusicdirs = getMusicDirs();
				$log->debug('Valid LMS music dirs = '.Dumper($lmsmusicdirs));

				foreach (@{$lmsmusicdirs}) {
					my $dirSep = File::Spec->canonpath("/");
					my $mediaDirURL = Slim::Utils::Misc::fileURLFromPath($_.$dirSep);
					$log->debug('Trying LMS music dir url: '.$mediaDirURL);

					my $newFullTrackURL = $mediaDirURL.$relTrackURL;
					my $newFullTrackPath = pathForItem($newFullTrackURL);
					$log->debug('Trying with new full track path: '.$newFullTrackPath);

					if (-f $newFullTrackPath) {
						$trackURL = Slim::Utils::Misc::fileURLFromPath($newFullTrackURL);
						$log->debug('Found file at new full file url: '.$trackURL);
						$log->debug('OLD full file url was: '.$fullTrackURL);

						last;
					}
				}
			}
			if (!$trackURL) {
				$log->warn("Couldn't find file for url \"$fullTrackURL\".");
			} else {
				writeRatingToDB($trackURL, $rating, 0);
			}
		}
		%restoreitem = ();
	}

	if ($element eq 'RatingsLight') {
		doneScanning();
		return 0;
	}
}


## virtual libraries

sub initVirtualLibraries {
	Slim::Music::VirtualLibraries->unregisterLibrary('RL_RATED');
	Slim::Music::VirtualLibraries->unregisterLibrary('RL_TOPRATED');
	Slim::Menu::BrowseLibrary->deregisterNode('RatingsLightRatedTracksMenuFolder');

	my $showratedtracksmenus = $prefs->get('showratedtracksmenus');
	if ($showratedtracksmenus > 0) {
		my $browsemenus_sourceVL_id = $prefs->get('browsemenus_sourceVL_id');
		$log->debug('browsemenus_sourceVL_id = '.Dumper($browsemenus_sourceVL_id));
		my $topratedminrating = $prefs->get('topratedminrating');

		my $libraries = Slim::Music::VirtualLibraries->getLibraries();
		# check if source virtual library still exists, otherwise use complete library
		if ((defined $browsemenus_sourceVL_id) && ($browsemenus_sourceVL_id ne '')) {
			my $VLstillexists = 0;
			foreach my $thisVLid (keys %{$libraries}) {
				if ($thisVLid eq $browsemenus_sourceVL_id) {
					$VLstillexists = 1;
					$log->debug('VL $browsemenus_sourceVL_id exists!');
				}
			}
			if ($VLstillexists == 0) {
				$prefs->set('browsemenus_sourceVL_id', undef);
				$browsemenus_sourceVL_id = undef;
			}
		}

		$browsemenus_sourceVL_id = $prefs->get('browsemenus_sourceVL_id');
		my @libraries = ();
		if ((!defined $browsemenus_sourceVL_id) || ($browsemenus_sourceVL_id eq '')) {
			push @libraries,{
				id => 'RL_RATED',
				name => string('PLUGIN_RATINGSLIGHT_VLNAME_RATEDTRACKS'),
				sql => qq{insert or ignore into library_track (library, track) select '%s', tracks.id from tracks join tracks_persistent tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 group by tracks.id},
			};
		} else {
			push @libraries,{
				id => 'RL_RATED',
				name => string('PLUGIN_RATINGSLIGHT_VLNAME_RATEDTRACKS'),
				sql => qq{insert or ignore into library_track (library, track) select '%s', tracks.id from tracks join tracks_persistent tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 join library_track on library_track.track = tracks.id and library_track.library = "$browsemenus_sourceVL_id" group by tracks.id},
			};
		}

		if ($showratedtracksmenus == 2) {
			if ((!defined $browsemenus_sourceVL_id) || ($browsemenus_sourceVL_id eq '')) {
				push @libraries,{
					id => 'RL_TOPRATED',
					name => string('PLUGIN_RATINGSLIGHT_VLNAME_TOPRATEDTRACKS'),
					sql => qq{insert or ignore into library_track (library, track) select '%s', tracks.id from tracks join tracks_persistent tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating >= $topratedminrating group by tracks.id}
				};
			} else {
				push @libraries,{
					id => 'RL_TOPRATED',
					name => string('PLUGIN_RATINGSLIGHT_VLNAME_TOPRATEDTRACKS'),
					sql => qq{insert or ignore into library_track (library, track) select '%s', tracks.id from tracks join tracks_persistent tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating >= $topratedminrating join library_track on library_track.track = tracks.id and library_track.library = "$browsemenus_sourceVL_id" group by tracks.id}
				};
			}
		}
		foreach my $library (@libraries) {
			Slim::Music::VirtualLibraries->unregisterLibrary($library);
			Slim::Music::VirtualLibraries->registerLibrary($library);
			Slim::Music::VirtualLibraries->rebuild($library->{id});
		}

		Slim::Menu::BrowseLibrary->deregisterNode('RatingsLightRatedTracksMenuFolder');
		my $browsemenus_sourceVL_name = '';
		if ((defined $browsemenus_sourceVL_id) && ($browsemenus_sourceVL_id ne '')) {
			$browsemenus_sourceVL_name = Slim::Music::VirtualLibraries->getNameForId($browsemenus_sourceVL_id);
			$browsemenus_sourceVL_name = ' ('.string('PLUGIN_RATINGSLIGHT_LIBVIEW').': '.$browsemenus_sourceVL_name.')';
		}
		Slim::Menu::BrowseLibrary->registerNode({
			type => 'link',
			name => 'PLUGIN_RATINGSLIGHT_MENUS_RATED_TRACKS_MENU_FOLDER',
			id => 'RatingsLightRatedTracksMenuFolder',
			feed => sub {
				my ($client, $cb, $args, $pt) = @_;
				my @items = ();

				# Artists with rated tracks
				$pt = {library_id => Slim::Music::VirtualLibraries->getRealId('RL_RATED')};
				push @items,{
					type => 'link',
					name => string('PLUGIN_RATINGSLIGHT_MENUS_ARTISTMENU_RATED').$browsemenus_sourceVL_name,
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
				$pt = {library_id => Slim::Music::VirtualLibraries->getRealId('RL_RATED')};
				push @items,{
					type => 'link',
					name => string('PLUGIN_RATINGSLIGHT_MENUS_GENREMENU_RATED').$browsemenus_sourceVL_name,
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

				if ($showratedtracksmenus == 2) {
					# Artists with top rated tracks
					$pt = {library_id => Slim::Music::VirtualLibraries->getRealId('RL_TOPRATED')};
					push @items,{
						type => 'link',
						name => string('PLUGIN_RATINGSLIGHT_MENUS_ARTISTMENU_TOPRATED').$browsemenus_sourceVL_name,
						url => \&Slim::Menu::BrowseLibrary::_artists,
						icon => 'html/images/artists.png',
						jiveIcon => 'html/images/artists.png',
						id => string('myMusicArtists_RATED_TOPRATED_TracksByArtist'),
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

					# Genres with top rated tracks
					$pt = {library_id => Slim::Music::VirtualLibraries->getRealId('RL_TOPRATED')};
					push @items,{
						type => 'link',
						name => string('PLUGIN_RATINGSLIGHT_MENUS_GENREMENU_TOPRATED').$browsemenus_sourceVL_name,
						url => \&Slim::Menu::BrowseLibrary::_genres,
						icon => 'html/images/genres.png',
						jiveIcon => 'html/images/genres.png',
						id => string('myMusicGenres_RATED_TOPRATED_TracksByGenres'),
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
				$cb->({
					items => \@items,
				});
			},
			weight => 88,
			cache => 0,
			icon => 'plugins/RatingsLight/html/images/ratedtracksmenuicon_svg.png',
			jiveIcon => 'plugins/RatingsLight/html/images/ratedtracksmenuicon_svg.png',
		});
	}
}

sub refreshVirtualLibraries {
	my $showratedtracksmenus = $prefs->get('showratedtracksmenus');
	if ($showratedtracksmenus > 0) {
		my $started = time();
		my $library_RealID_rated_all = Slim::Music::VirtualLibraries->getRealId('RL_RATED');
		Slim::Music::VirtualLibraries->rebuild($library_RealID_rated_all);

		if ($showratedtracksmenus == 2) {
			my $library_RealID_toprated = Slim::Music::VirtualLibraries->getRealId('RL_TOPRATED');
			Slim::Music::VirtualLibraries->rebuild($library_RealID_toprated);
		}
		my $ended = time() - $started;
		$log->debug('Refreshing virtual libraries completed after '.$ended.' seconds.');
	}
}

sub getVirtualLibraries {
	my $libraries = Slim::Music::VirtualLibraries->getLibraries();
	my %libraries;

	%libraries = map {
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
			my $rating = undef;
			my $client = shift;
			my $button = shift;
			my $digit = shift;
			$log->debug('IR command - button: '.$button);
			$log->debug('IR command - digit: '.$digit);

			if (Slim::Music::Import->stillScanning) {
				$log->warn('Warning: access to rating values blocked until library scan is completed');
				$client->showBriefly({
					'line' => [$client->string('PLUGIN_RATINGSLIGHT'),$client->string('PLUGIN_RATINGSLIGHT_BLOCKED')]},
					3);
				return;
			}

			return unless $digit>='0' && $digit<='9';

			my $song = Slim::Player::Playlist::song($client);
			my $curtrackinfo = $song->{_column_data};
			my $curtrackURL = @{$curtrackinfo}{url};
			my $curtrackid = @{$curtrackinfo}{id};
			if ($digit >= 0 && $digit <=5) {
				$rating = $digit*20;
			}

			if ($digit >= 6 && $digit <= 9) {
				my $track = Slim::Schema->resultset('Track')->find($curtrackid);
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
				$rating = ratingSanityCheck($rating);
			}
			$log->debug('IR command - current track URL = '.$curtrackURL);
			$log->debug('IR command - current track ID = '.$curtrackid);
			$log->debug('IR command - rating = '.$rating);
			VFD_deviceRating($client, undef, undef, $curtrackURL, $curtrackid, $rating);
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
								$log->debug("mapping $function to ${baseKeyName}.hold for $i-$key");
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
								$log->debug("${baseKeyName}.hold mapping already exists for $i-$key");
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
				$log->debug("mapping ${baseKeyName}.hold to $function for \"'.$client->name().'\" in $mapsAltered modes");
			}
			$client->irmaps(\@maps);
		}
	}
}


## rating log, playlist

sub addToRecentlyRatedPlaylist {
	my $trackURL = shift;
	my $playlistname = 'Recently Rated Tracks (Ratings Light)';
	my $recentlymaxcount = $prefs->get('recentlymaxcount');

	my $createplaylistrequest = Slim::Control::Request::executeRequest(undef, ['playlists', 'new', 'name:'.$playlistname]);
	my $playlistid = $createplaylistrequest->getResult('playlist_id') || $createplaylistrequest->getResult('overwritten_playlist_id');
	$log->debug('playlistid = '.Dumper($playlistid));
	if (!$playlistid) {
		$log->info("No playlist id. Couldn't create or write to playlist 'Recently rated tracks'");
		return;
	}
	my $trackcountRequest = Slim::Control::Request::executeRequest(undef, ['playlists', 'tracks', '0', '1000', 'playlist_id:'.$playlistid, 'tags:count']);
	my $trackcount = $trackcountRequest->getResult('count');
	if ($trackcount > ($recentlymaxcount - 1)) {
		Slim::Control::Request::executeRequest(undef, ['playlists', 'edit', 'cmd:delete', 'playlist_id:'.$playlistid, 'index:0']);
	}

	Slim::Control::Request::executeRequest(undef, ['playlists', 'edit', 'cmd:add', 'playlist_id:'.$playlistid, 'url:'.$trackURL]);
}

sub logRatedTrack {
	my ($trackURL, $rating100ScaleValue) = @_;

	my ($previousRating, $newRatring) = 0;
	my $ratingtimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;

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

	my ($title, $artist, $album, $previousRating100ScaleValue);
	my $query = Slim::Control::Request::executeRequest(undef, ['songinfo', '0', '100', 'url:'.$trackURL, 'tags:alR']);
	my $songinfohash = $query->getResult('songinfo_loop');

	foreach my $elem (@{$songinfohash}) {
		foreach my $key (keys %{$elem}) {
			if ($key eq 'title') {
				$title = $elem->{$key};
			}
			if ($key eq 'artist') {
				$artist = $elem->{$key};
			}
			if ($key eq 'album') {
				$album = $elem->{$key};
			}
			if ($key eq 'rating') {
				$previousRating100ScaleValue = $elem->{$key};
			}
		}
	}

	if (defined $previousRating100ScaleValue) {
		$previousRating = $previousRating100ScaleValue/20;
	}
	my $newRating = $rating100ScaleValue/20;

	my $filename = catfile($logDir, $logFileName);
	my $output = FileHandle->new($filename, '>>:utf8') or do {
		$log->warn('Could not open '.$filename.' for writing.');
		return;
	};

	print $output $ratingtimestamp."\n";
	print $output 'Artist: '.$artist.' ## Title: '.$title.' ## Album: '.$album."\n";
	print $output 'Previous Rating: '.$previousRating.' --> New Rating: '.$newRating."\n\n";

	close $output;
}

sub clearAllRatings {
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
	my $sqlunrateall = "update tracks_persistent set rating = null where tracks_persistent.rating > 0;";
	my $dbh = getCurrentDBH();
	my $sth = $dbh->prepare($sqlunrateall);
	eval {
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

	my $ended = time() - $started;
	$log->debug('Clearing all ratings completed after '.$ended.' seconds.');
	$prefs->set('status_clearingallratings', 0);

	refreshAll();
}


## DSTM

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


###### helpers ######

sub writeRatingToDB {
	my ($trackURL, $rating100ScaleValue, $logthis) = @_;

	if (($rating100ScaleValue < 0) || ($rating100ScaleValue > 100)) {
		$rating100ScaleValue = ratingSanityCheck($rating100ScaleValue);
	}

	unless (defined $logthis) {
		my $userecentlyaddedplaylist = $prefs->get('userecentlyaddedplaylist');
		my $uselogfile = $prefs->get('uselogfile');
		if (defined $userecentlyaddedplaylist) {
			addToRecentlyRatedPlaylist($trackURL);
		}
		if (defined $uselogfile) {
			logRatedTrack($trackURL, $rating100ScaleValue);
		}
	}

	my $urlmd5 = md5_hex($trackURL);
	my $sql = "update tracks_persistent set rating=$rating100ScaleValue where urlmd5 = ?";
	my $dbh = getCurrentDBH();
	my $sth = $dbh->prepare($sql);
	eval {
		$sth->bind_param(1, $urlmd5);
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

sub getRatingFromDB {
	my $track = shift;
	my $rating = 0;

	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: access to rating values blocked until library scan is completed');
		return $rating;
	}

	if ($track && !blessed($track)) {
		$log->debug('track is not blessed');
		$track = Slim::Schema->find('Track', $track->{id});
		if (!blessed($track)) {
			$log->debug('No track object found');
			return $rating;
		}
	}

	# check if remote track is part of online library
	if (Slim::Music::Info::isRemoteURL($track->url) == 1) {
		if (!defined($track->extid)) {
			$log->debug('track is remote but has no extid. Trying to get rating with url: '.$track->url);
			my $url = $track->url;

			my $urlmd5 = $track->urlmd5 || md5_hex($url);
			my $dbh = getCurrentDBH();
			my $sqlstatement = "select tracks_persistent.rating from tracks_persistent where tracks_persistent.urlmd5 = \"$urlmd5\"";
			eval{
				my $sth = $dbh->prepare($sqlstatement);
				$sth->execute() or do {$sqlstatement = undef;};
				$rating = $sth->fetchrow || 0;
				$sth->finish();
			};
			if ($@) { $log->debug("error: $@"); }
			$log->debug("Found rating $rating for url: ".$url);
			return adjustDisplayedRating($rating);
		}
	}

	# check for dead/moved local tracks
	if ((Slim::Music::Info::isRemoteURL($track->url) != 1) && (!defined($track->filesize))) {
		$log->debug('track dead or moved??? Track URL: '.$track->url);
		return $rating;
	}

	my $thisrating = $track->rating;
	$rating = $thisrating if $thisrating;
	return adjustDisplayedRating($rating);
}

sub getRatingTextLine {
	my $rating = shift;
	my $appended = shift;
	my $nobreakspace = HTML::Entities::decode_entities('&#xa0;'); # "NO-BREAK SPACE" - HTML Entity (hex): &#xa0;
	my $displayratingchar = $prefs->get('displayratingchar'); # 0 = common text star *, 1 = blackstar 2605
	my $ratingchar = ' *';
	my $fractionchar = HTML::Entities::decode_entities('&#xbd;'); # "vulgar fraction one half" - HTML Entity (hex): &#xbd;

	if ($displayratingchar == 1) {
		$ratingchar = HTML::Entities::decode_entities('&#x2605;'); # "blackstar" - HTML Entity (hex): &#x2605;
	}
	my $text = string('PLUGIN_RATINGSLIGHT_LANGSTRING_UNRATED');

	if ($rating > 0) {
		my $detecthalfstars = ($rating/2)%2;
		my $ratingstars = $rating/20;
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

sub getExcludedGenreList {
	my $excludegenres_namelist = $prefs->get('excludegenres_namelist');
	my $excludedgenreString = '';
	if ((defined $excludegenres_namelist) && (scalar @{$excludegenres_namelist} > 0)) {
		$excludedgenreString = join ',', map qq/'$_'/, @{$excludegenres_namelist};
	}
	return $excludedgenreString;
}

sub refreshAll {
	Slim::Music::Info::clearFormatDisplayCache();
	refreshTitleFormats();
	refreshVirtualLibraries();
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
		$log->debug('track is not blessed');
		my $trackObj = Slim::Schema->find('Track', $track->{id});
		if (blessed($trackObj)) {
			$track = $trackObj;
		} else {
			my $trackURL = $track->{'url'};
			$log->debug('Slim::Schema->find found no blessed track object for id. Trying to retrieve track object with url: '.Dumper($trackURL));
			if (defined ($trackURL)) {
				if (Slim::Music::Info::isRemoteURL($trackURL) == 1) {
					$track = Slim::Schema->_retrieveTrack($trackURL);
					$log->debug('Track is remote. Retrieved trackObj = '.Dumper($track));
				} else {
					$track = Slim::Schema->objectForUrl({
												'url' => $trackURL,
											});
					$log->debug('Track is not remote. Track objectForUrl = '.Dumper($track));
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
	$log->debug('refreshing title formats');
	for my $client (Slim::Player::Client::clients()) {
		next unless $client && $client->controller();
		$client->currentPlaylistUpdateTime(Time::HiRes::time());
	}
}



# misc

sub getRatingTSLegacy {
	my $request = shift;
	$log->debug('Used TS Legacy dispatch to get rating.');
	$log->debug('request params = '.Dumper($request->getParamsCopy()));
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

	my $trackId = $request->getParam('_trackid');
	if (defined($trackId) && $trackId =~ /^track_id:(.*)$/) {
		$trackId = $1;
	} elsif (defined($request->getParam('_trackid'))) {
		$trackId = $request->getParam('_trackid');
	} else {
		$log->error("Can't set rating. No (valid) track ID found. Provided track ID was ".Dumper($trackId));
		return;
	}

	my $track = Slim::Schema->find('Track', $trackId);
	my $rating100ScaleValue = getRatingFromDB($track);

	$request->addResult('rating', $rating100ScaleValue/20);
	$request->addResult('ratingpercentage', $rating100ScaleValue);
	$request->setStatusDone();
}

sub adjustDisplayedRating {
	my $rating = shift;
	$rating = int(($rating + 5)/10)*10;
	return $rating;
}

sub ratingValidator {
	my ($rating, $ratingScale) = @_;
	$log->debug('rating = '.$rating.' -- ratingScale = '.Dumper($ratingScale));
	$rating =~ s/\s+//g; # remove all whitespace characters

	if ($ratingScale && $ratingScale eq 'percent' && (($rating !~ /^\d+\z/) || ($rating < 0 || $rating > 100))) {
		$log->error("Can't set rating. Invalid rating value! Rating values for 'setratingpercent' have to be on a scale from 0 to 100. The provided rating value was ".Dumper($rating));
		return undef;
	}

	if (!defined($ratingScale) && (($rating !~ /^\d+(\.5)?\z/) || ($rating < 0 || $rating > 5))) {
		$log->error("Can't set rating. Invalid rating value! Rating values for 'setrating' have to be on a scale from 0 to 5. The provided rating value was ".Dumper($rating));
		return undef;
	}
	return $rating;
}

sub ratingSanityCheck {
	my $rating = shift;
	if ((!defined $rating) || ($rating < 0)) {
		return 0;
	}
	if ($rating > 100) {
		return 100;
	}
	return $rating;
}

sub createRLfolder {
	my $rlParentFolderPath = $prefs->get('rlparentfolderpath') || $serverPrefs->get('playlistdir');
	my $rlFolderPath = catdir($rlParentFolderPath, 'RatingsLight');
	eval {
		mkdir($rlFolderPath, 0755) unless (-d $rlFolderPath);
		chdir($rlFolderPath);
	} or do {
		$log->error("Could not create or access RatingsLight folder in parent folder '$rlParentFolderPath'!");
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

sub uniq {
	my %seen;
	grep !$seen{$_}++, @_;
}

1;
