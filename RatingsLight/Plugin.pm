package Plugins::RatingsLight::Plugin;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Scanner::API;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Digest::MD5 qw(md5_hex);
use Slim::Utils::Text;
use POSIX qw(floor);
use base qw(FileHandle);
use File::Spec::Functions qw(:ALL);
use File::Basename;
use URI::Escape;

use Slim::Schema;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.ratingslight',
	'defaultLevel' => 'DEBUG',
	'description'  => 'PLUGIN_RATINGSLIGHT',
});

my $RATING_CHARACTER = " *";

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

$prefs->init({
	rating_keyword_prefix => $rating_keyword_prefix,
	rating_keyword_suffix => $rating_keyword_suffix,
	autoscan => $autoscan,
	onlyratingnotmatchcommenttag => $onlyratingnotmatchcommenttag,
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

		Slim::Control::Request::addDispatch(['ratingslight','setrating', '_trackid', '_rating'], [1, 0, 1, \&setRating]);

		# faking of TrackStat API is required for compatibility with Material Skin ◔_◔
		Slim::Control::Request::addDispatch(['trackstat','getrating', '_trackid'], [0, 1, 0, \&getRating]);
		Slim::Control::Request::addDispatch(['trackstat','setrating', '_trackid', '_rating'], [1, 0, 1, \&setRating]);

		Slim::Control::Request::addDispatch(['ratingslight','manualimport'], [0, 0, 0, \&importRatingsFromCommentTags]);

		Slim::Control::Request::addDispatch(['ratingslight','exportplayliststofiles'], [0, 0, 0, \&exportRatingsToPlaylistFiles]);

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

# 	foreach ( {
#
#     	id => 'RATED_HIGH',
#     	name => 'Rated - 3 stars+',
#      	sql => qq{
#     		INSERT OR IGNORE INTO library_track (library, track)
#     		SELECT '%s', tracks.id
#     		FROM tracks
# 				LEFT JOIN tracks_persistent tracks_persistent ON tracks_persistent.urlmd5 = tracks.urlmd5
# 					WHERE tracks_persistent.rating >= 60
# 			GROUP by tracks.id
#       },
#
#      	id => 'RATED',
#     	name => 'Rated',
#      	sql => qq{
#     		INSERT OR IGNORE INTO library_track (library, track)
#     		SELECT '%s', tracks.id
#     		FROM tracks
# 				LEFT JOIN tracks_persistent tracks_persistent ON tracks_persistent.urlmd5 = tracks.urlmd5
# 					WHERE tracks_persistent.rating > 0
# 			GROUP by tracks.id
#       },
#
#     } ) {
# 		Slim::Music::VirtualLibraries->unregisterLibrary($_);
# 		Slim::Music::VirtualLibraries->registerLibrary($_);
# 		Slim::Music::VirtualLibraries->rebuild($_->{id});
# 	};
#
# 		Slim::Menu::BrowseLibrary->deregisterNode('MyTopLevelMenu');
#
# 		Slim::Menu::BrowseLibrary->registerNode({
#                         type         => 'link',
#                         name         => 'MY_TEST_MENUS',
#                         id           => 'MyTopLevelMenu',
#                         feed         => sub {
#                         	my ($client, $cb, $args, $pt) = @_;
#                         	my @items = ();
#
# 							# Artists with tracks rated 3 stars+
#                         	$pt = { library_id => Slim::Music::VirtualLibraries->getRealId('RATED_HIGH') };
#                         	push @items,{
#
#                         		type => 'link',
#                         		name => 'TOP RATED ARTISTS',
#                         		url => \&Slim::Menu::BrowseLibrary::_artists,
#                         		icon => 'html/images/artists.png',
#                         		jiveIcon => 'html/images/artists.png',
# 								id => string('myMusicArtists_RATED_HIGH_TracksByArtist'),
#                          		condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
#                          		weight => 210,
#                          		cache => 1,
#                          		passthrough => [{
#                          			library_id => $pt->{'library_id'},
#                          			searchTags => [
#                          				'library_id:'.$pt->{'library_id'}
#                          			],
#                          		}],
#                         	};
#
# 							# Genres with tracks rated 3 stars+
#                         	$pt = { library_id => Slim::Music::VirtualLibraries->getRealId('RATED_HIGH') };
#                         	push @items,{
#
#                         		type => 'link',
#                         		name => 'TOP RATED GENRES',
#                         		url => \&Slim::Menu::BrowseLibrary::_genres,
#                         		icon => 'html/images/genres.png',
#                         		jiveIcon => 'html/images/genres.png',
# 								id => string('myMusicGenres_RATED_HIGH_TracksByGenres'),
#                          		condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
#                          		weight => 211,
#                          		cache => 1,
#                          		passthrough => [{
#                          			library_id => $pt->{'library_id'},
#                          			searchTags => [
#                          				'library_id:'.$pt->{'library_id'}
#                          			],
#                          		}],
#                         	};
#
# 							# Artists with rated tracks
#                         	$pt = { library_id => Slim::Music::VirtualLibraries->getRealId('RATED') };
#                         	push @items,{
#
#                         		type => 'link',
#                         		name => 'TOP RATED ARTISTS',
#                         		url => \&Slim::Menu::BrowseLibrary::_artists,
#                         		icon => 'html/images/artists.png',
#                         		jiveIcon => 'html/images/artists.png',
# 								id => string('myMusicArtists_RATED_TracksByArtist'),
#                          		condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
#                          		weight => 210,
#                          		cache => 1,
#                          		passthrough => [{
#                          			library_id => $pt->{'library_id'},
#                          			searchTags => [
#                          				'library_id:'.$pt->{'library_id'}
#                          			],
#                          		}],
#                         	};
#
# 							# Genres with rated tracks
#                         	$pt = { library_id => Slim::Music::VirtualLibraries->getRealId('RATED') };
#                         	push @items,{
#
#                         		type => 'link',
#                         		name => 'TOP RATED GENRES',
#                         		url => \&Slim::Menu::BrowseLibrary::_genres,
#                         		icon => 'html/images/genres.png',
#                         		jiveIcon => 'html/images/genres.png',
# 								id => string('myMusicGenres_RATED_TracksByGenres'),
#                          		condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
#                          		weight => 211,
#                          		cache => 1,
#                          		passthrough => [{
#                          			library_id => $pt->{'library_id'},
#                          			searchTags => [
#                          				'library_id:'.$pt->{'library_id'}
#                          			],
#                          		}],
#                         	};
#
#  							$cb->({
#  								items => \@items,
#  							});
#                          },
#
#                         weight       => 87,
#                         cache        => 1,
#                 });

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
	my $class = shift;
	my $dbh = getCurrentDBH();

	my $rating_keyword_prefix = $prefs->get('rating_keyword_prefix');
	my $rating_keyword_suffix = $prefs->get('rating_keyword_suffix');

	if ((!defined $rating_keyword_prefix || $rating_keyword_prefix eq '') && (!defined $rating_keyword_suffix || $rating_keyword_suffix eq '')) {
		$log->error('Error: no rating keywords found.');
		return
	} else {
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
	}
}

sub exportRatingsToPlaylistFiles {
	my $playlistDir = $serverPrefs->get('playlistdir');
	my $onlyratingnotmatchcommenttag = $prefs->get('onlyratingnotmatchcommenttag');
	my $rating_keyword_prefix = $prefs->get('rating_keyword_prefix');
	my $rating_keyword_suffix = $prefs->get('rating_keyword_suffix');
	my $sql = undef;
	my $dbh = getCurrentDBH();
	my $sth = undef;
	my $rating5starScaleValue = 0;
	my $rating100ScaleValue = 10;

	until ($rating100ScaleValue > 100) {
		if ($onlyratingnotmatchcommenttag == 1) {
			if ((!defined $rating_keyword_prefix || $rating_keyword_prefix eq '') && (!defined $rating_keyword_suffix || $rating_keyword_suffix eq '')) {
				$log->error('Error: no rating keywords found.');
				return
			} else {
				$sql = "SELECT tracks_persistent.url FROM tracks_persistent
				WHERE (tracks_persistent.rating = $rating100ScaleValue
						AND tracks_persistent.urlmd5 IN (
						   SELECT tracks.urlmd5
							 FROM tracks
								  LEFT JOIN comments ON comments.track = tracks.id
							WHERE (comments.value NOT LIKE ? OR comments.value IS NULL) )
						);";
				$sth = $dbh->prepare($sql);
				$rating5starScaleValue = floor(($rating100ScaleValue + 10) / 20); # round up half-stars
				#$rating5starScaleValue = floor($rating100ScaleValue/20); # round down half-stars
				my $ratingkeyword = "%%".$rating_keyword_prefix.$rating5starScaleValue.$rating_keyword_suffix."%%";
				$sth->bind_param(1, $ratingkeyword);
			}
		} else {
			$sql = "SELECT tracks_persistent.url FROM tracks_persistent WHERE tracks_persistent.rating = $rating100ScaleValue";
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
			my $PLfilename = ($rating5starScaleValue == 1 ? 'Rated_'.$rating5starScaleValue.'_star.m3u.txt' : 'Rated_'.$rating5starScaleValue.'_stars.m3u.txt');

			my $filename = catfile($playlistDir,$PLfilename);
			my $output = FileHandle->new($filename, ">") or do {
				$log->warn("Could not open $filename for writing.\n");
				return;
			};
			print $output '#EXTM3U'."\n";

			for my $PLtrackURL (@trackURLs) {
				print $output "#EXTURL:".$PLtrackURL."\n";
				my $unescapedURL = uri_unescape($PLtrackURL);
				print $output $unescapedURL."\n";
			}
			close $output;
		}
		$rating100ScaleValue = $rating100ScaleValue + 10;
	}
}

sub setRating {
	my $request = shift;
	my $client = $request->client();

	if ($request->isNotCommand([['ratingslight'],['setrating']])) {
		$request->setStatusBadDispatch();
		return;
	}
	if(!defined $client) {
		$request->setStatusNeedsClient();
		return;
	}

  	my $trackId    = $request->getParam('_trackid');
  	if(defined($request->getParam('trackid'))) {
  		$trackId = $request->getParam('trackid');
  	}
  	my $rating    = $request->getParam('_rating');
	if(defined($rating) && $rating =~ /^rating:(.*)$/) {
		$rating = $1;
	}elsif(defined($request->getParam('rating'))) {
		$rating = $request->getParam('rating');
	}
  	if(!defined $trackId || $trackId eq '' || !defined $rating || $rating eq '') {
		$request->setStatusBadParams();
		return;
  	}

	# write rating to LMS persistent database
	my $track = Slim::Schema->resultset("Track")->find($trackId);
	my $trackURL = $track->url;
	my $urlmd5 = md5_hex($trackURL);

	my $rating100ScaleValue = ($rating * 20);
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

	# refresh virtual libraries
	#my $library_id_rated_all = Slim::Music::VirtualLibraries->getRealId('RATED');
	#Slim::Music::VirtualLibraries->rebuild($library_id_rated_all);

	#if ($rating100ScaleValue >= 60) {
	#	my $library_id_rated_high = Slim::Music::VirtualLibraries->getRealId('RATED_HIGH');
	#	Slim::Music::VirtualLibraries->rebuild($library_id_rated_high);
	#}

	$request->setStatusDone();
}

sub getRating {
	my $request = shift;

	if ($request->isNotQuery([['trackstat'],['getrating']])) {
		$request->setStatusBadDispatch();
		return;
	}

  	my $trackId = $request->getParam('_trackid');
  	if(defined($request->getParam('_trackid'))) {
  		$trackId = $request->getParam('_trackid');
  	}
  	if(!defined $trackId || $trackId eq '') {
		$request->setStatusBadParams();
		return;
  	}

	my $rating100ScaleValue = 0;
	my $rating5starScaleValue = 0;

	my $track = Slim::Schema->resultset("Track")->find($trackId);
	$rating100ScaleValue = getRatingFromDB($track);
	if ($rating100ScaleValue > 0) {
		$rating5starScaleValue = floor(($rating100ScaleValue + 10) / 20);
	}

	$request->addResult('rating', $rating5starScaleValue);
	$request->addResult('ratingpercentage', $rating100ScaleValue);
	$request->setStatusDone();
}

sub trackInfoHandlerRating {
    my ( $client, $url, $track ) = @_;
	my ($rating100ScaleValue, $rating5starScaleValue, $rating5starScaleValueExact) = 0;
	my $text = string('PLUGIN_RATINGSLIGHT_RATING');

	$rating100ScaleValue = getRatingFromDB($track);

	# round down half-stars
	# my $rating100ScaleValueFloored = floor((floor($rating100ScaleValue/20))*20);

	if ($rating100ScaleValue > 0) {
		$rating5starScaleValueExact = $rating100ScaleValue/20;
		$rating5starScaleValue = floor(($rating100ScaleValue + 10) / 20); # round up half-stars
		#$rating5starScaleValue = floor($rating100ScaleValue/20); # round down half-stars
		$text = string('PLUGIN_RATINGSLIGHT_RATING').($RATING_CHARACTER x $rating5starScaleValue)." (".$rating5starScaleValueExact.")";
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

sub getTitleFormat_Rating {
	my $track = shift;
	my $string = HTML::Entities::decode_entities('&nbsp;');
	my $rating100ScaleValue = 0;
	my $rating5starScaleValue = 0;

	$rating100ScaleValue = getRatingFromDB($track);
	if ($rating100ScaleValue > 0) {
		$rating5starScaleValue = floor(($rating100ScaleValue + 10) / 20); # round up half-stars
		#$rating5starScaleValue = floor($rating100ScaleValue/20); # round down half-stars
	}

	if ($rating5starScaleValue > 0) {
		$string = ($RATING_CHARACTER x $rating5starScaleValue);
	}
	return $string;
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
