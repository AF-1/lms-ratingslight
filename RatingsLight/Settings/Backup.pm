package Plugins::RatingsLight::Settings::Backup;

use strict;
use base qw(Plugins::RatingsLight::Settings::BaseSettings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;

my $prefs = preferences('plugin.ratingslight');
my $log   = logger('plugin.ratingslight');

my $plugin;

sub new {
	my $class = shift;
	$plugin   = shift;

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
    return ($prefs, qw(scheduledbackups backuptime backupsdaystokeep restorefile clearallbeforerestore));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $callHandler = 1;
	if ($paramRef->{'saveSettings'}) {
		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	}
	if($paramRef->{'backup'}) {
		if($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::RatingsLight::Plugin::createBackup();
	}elsif($paramRef->{'restore'}) {
		if($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::RatingsLight::Plugin::restoreFromBackup();
	}elsif($paramRef->{'pref_scheduledbackups'}) {
		if($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::RatingsLight::Plugin::backupScheduler();
	}elsif($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
	}
	return $result;
}

1;
