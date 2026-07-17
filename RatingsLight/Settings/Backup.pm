#
# Ratings Light
# (c) 2020 AF
# Licensed under the GPLv3 - see LICENSE file
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

sub new {
	my ($class, $plugin) = @_;
	$class->SUPER::new($plugin);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RATINGSLIGHT_SETTINGS_BACKUP_RESTORE');
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
	my $result;
	my $callHandler = 1;
	$paramRef->{'pref_backuptime'} = trim($paramRef->{'pref_backuptime'} // '');

	if ($paramRef->{'saveSettings'}) {
		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	}
	if ($paramRef->{'backup'}) {
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
			$callHandler = 0;
		}
		if (Slim::Music::Import->stillScanning) {
			$log->warn('Cannot start a backup while an LMS scan is in progress');
		} else {
			createBackup();
		}
	} elsif ($paramRef->{'restore'}) {
		my $selectedfile = $paramRef->{'pref_restorefile'};
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
			$callHandler = 0;
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('restorefile = '.Data::Dump::dump($selectedfile));
		if (!defined($selectedfile) || $selectedfile eq '') {
			$paramRef->{'restoremissingfile'} = 1;
		} elsif ($selectedfile !~ /\.xml/i) {
			$paramRef->{'restoremissingfile'} = 2;
		} elsif (Slim::Music::Import->stillScanning) {
			$log->warn('Cannot start a restore while an LMS scan is in progress');
		} else {
			$prefs->set('restorefile', $selectedfile);
			Plugins::RatingsLight::Plugin::restoreFromBackup();
		}
	}

	$result = $class->SUPER::handler($client, $paramRef);
	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	$paramRef->{'restorefilefolder'} = $prefs->get('rlfolderpath');
	$paramRef->{lastsuccessfulbackup} = Slim::Utils::DateTime::longDateF($prefs->get('lastbackup')).", ".Slim::Utils::DateTime::timeF($prefs->get('lastbackup')) if $prefs->get('lastbackup');
	$paramRef->{'squeezebox_server_jsondatareq'} = '/jsonrpc.js';
	$paramRef->{'activebackuprestore'} = 1 if $prefs->get('status_backuprestore');
	$paramRef->{'activelmsscan'} = 1 if (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning);
}

sub trim {
	my $str = shift;
	$str =~ s{^\s+}{};
	$str =~ s{\s+$}{};
	return $str;
}

1;
