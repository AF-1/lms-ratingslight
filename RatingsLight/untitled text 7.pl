sub getRatedTracks {
	my ($countOnly, $client, $objectType, $objectID, $currentTrackID, $listlimit) = @_;
	$log->debug('objectType = '.$objectType.' ## countOnly = '.$countOnly.' ## trackID = '.$currentTrackID.' ## thisID = '.$objectID);

	%validObjectTypes = map {$_ => 1} qw(artist, album, genre, year, decade, playlist);

	unless ($validObjectTypes{$objectType}) {
		$log->warn('No valid objectType');
		return 0;
	}

	my $ratedtrackscontextmenulimit = $prefs->get('ratedtrackscontextmenulimit');
	my $currentLibrary = Slim::Music::VirtualLibraries->getLibraryIdForClient($client);
	my $sqlstatement = ($countOnly == 1 ? "select count(*)" : "select tracks.id")."from tracks";

	if ((defined $currentLibrary) && ($currentLibrary ne '')) {
		$sqlstatement .= " join library_track on library_track.track = tracks.id and library_track.library = \"$currentLibrary\"";
	}

	$sqlstatement .= " join genre_track on genre_track.track = tracks.id and genre_track.genre = $objectID" if ($objectType eq 'genre');

	$sqlstatement .= " join playlist_track on playlist_track.track = tracks.url and playlist_track.playlist = $objectID" if ($objectType eq 'playlist');

	$sqlstatement .= " join tracks_persistent on tracks_persistent.urlmd5 = tracks.urlmd5 and tracks_persistent.rating > 0 where tracks.audio = 1 and tracks.id != $currentTrackID";

	$sqlstatement .= " and tracks.primary_artist = $objectID" if ($objectType eq 'artist');

	$sqlstatement .= " and tracks.album = $objectID" if ($objectType eq 'album');

	$sqlstatement .= " and tracks.year >= $objectID and tracks.year < ($objectID + 10)" if ($objectType eq 'decade');

	$sqlstatement .= "tracks.year = $objectID" if ($objectType eq 'year');

	if ($countOnly == 0) {
		$sqlstatement .= " limit $listlimit" if ($objectType eq 'artist' || $objectType eq 'album' || $objectType eq 'playlist');
	
		$sqlstatement .= " order by random() limit $listlimit" if ($objectType eq 'genre' || $objectType eq 'year' || $objectType eq 'decade');
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
		$log->debug('Pre-check found '.$trackCount.($trackCount == 1 ? ' rated track' : ' rated tracks')." for $objectType with ID: $objectID");
		return $trackCount;
	} else {
		$log->debug('Fetched '.scalar (@ratedtracks).(scalar (@ratedtracks) == 1 ? ' rated track' : ' rated tracks')." for $objectType with ID: $objectID");
		return \@ratedtracks;
	}
}
