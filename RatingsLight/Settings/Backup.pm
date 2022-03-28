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

package Plugins::RatingsLight::Settings::Backup;

use strict;
use warnings;
use utf8;

use base qw(Plugins::RatingsLight::Settings::BaseSettings);
use Plugins::RatingsLight::Common ':all';

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;

my $prefs = preferences('plugin.ratingslight');
my $log = logger('plugin.ratingslight');

my $plugin;

sub new {
	my $class = shift;
	$plugin = shift;
	$class->SUPER::new($plugin);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RATINGSLIGHT_SETTINGS_BACKUP');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/RatingsLight/settings/backup.html');
}

sub currentPage {
	return name();
}

sub pages {
	my %page = (
		'name' => name(),
		'page' => page(),
	);
	my @pages = (\%page);
	return \@pages;
}

sub prefs {
	return ($prefs, qw(autodeletebackups scheduledbackups backuptime prescanbackup backupsdaystokeep backupfilesmin restorefile selectiverestore clearallbeforerestore));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $callHandler = 1;
	if ($paramRef->{'saveSettings'}) {
		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	}
	if ($paramRef->{'backup'}) {
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		}
		createBackup();
	} elsif ($paramRef->{'restore'}) {
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		}
		my $selectedfile = $paramRef->{'pref_restorefile'};
		$log->debug("restorefile = ".$selectedfile);
		if ((!defined ($paramRef->{'pref_restorefile'})) || ($paramRef->{'pref_restorefile'} eq '')) {
			$paramRef->{'restoremissingfile'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		} elsif ($selectedfile !~ /\.xml/i) {
			$paramRef->{'restoremissingfile'} = 2;
			$result = $class->SUPER::handler($client, $paramRef);
		} else {
			Plugins::RatingsLight::Plugin::restoreFromBackup();
		}
	} elsif ($paramRef->{'pref_scheduledbackups'}) {
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;

			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::RatingsLight::Plugin::backupScheduler();
	} elsif ($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
	}

	my $RLfolderpath = ($prefs->get('rlparentfolderpath')).'/Ratingslight';
	$prefs->set('restorefile', $RLfolderpath);
	$result = $class->SUPER::handler($client, $paramRef);
	return $result;
}

1;
