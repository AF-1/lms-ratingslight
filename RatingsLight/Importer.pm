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
my $serverPrefs = preferences('server');

sub initPlugin {
	$log->debug('importer module init');
	my $preScanBackup = $prefs->get('prescanbackup');
	if ($preScanBackup) {
		$log->debug('creating pre-scan backup before scan process starts');
		createBackup();
	}
	toggleUseImporter();
}

sub toggleUseImporter {
	my $enableautoscan = $prefs->get('autoscan');
	if (defined $enableautoscan) {
		$log->debug('enabling importer');
		Slim::Music::Import->addImporter('Plugins::RatingsLight::Importer', {
			'type' => 'post',
			'weight' => 199,
			'use' => 1,
		});
	} else {
		$log->debug('disabling importer');
		Slim::Music::Import->useImporter('Plugins::RatingsLight::Importer',0);
	}
}

sub startScan {
	$log->debug('starting importer');
	my $filetagtype = $prefs->get('filetagtype');
	if ($filetagtype == 1) {
		importRatingsFromCommentsTags();
	} elsif ($filetagtype == 0) {
		importRatingsFromBPMTags();
	}
	Slim::Music::Import->endImporter(__PACKAGE__);
}

1;
