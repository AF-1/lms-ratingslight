#
# Ratings Light
# (c) 2020 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::RatingsLight::Importer;

use strict;
use warnings;
use utf8;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Schema;
use Plugins::RatingsLight::Common ':all';

my $log = logger('plugin.ratingslight');
my $prefs = preferences('plugin.ratingslight');

sub initPlugin {
	main::DEBUGLOG && $log->is_debug && $log->debug('importer module init');
	if ($prefs->get('prescanbackup')) {
		main::DEBUGLOG && $log->is_debug && $log->debug('creating pre-scan backup before scan process starts');
		createBackup(1);
	}
	toggleUseImporter();
}

sub toggleUseImporter {
	if ($prefs->get('autoscan')) {
		main::DEBUGLOG && $log->is_debug && $log->debug('enabling importer');
		Slim::Music::Import->addImporter('Plugins::RatingsLight::Importer', {
			'type' => 'post',
			'weight' => 199,
			'use' => 1,
		});
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug('disabling importer');
		Slim::Music::Import->useImporter('Plugins::RatingsLight::Importer',0);
	}
}

sub startScan {
	main::DEBUGLOG && $log->is_debug && $log->debug('starting importer');
	if ($prefs->get('filetagtype')) {
		importRatingsFromCommentTags();
	} else {
		importRatingsFromBPMTags();
	}
	Slim::Music::Import->endImporter(__PACKAGE__);
}

1;
