package Plugins::RatingsLight::Settings::BaseSettings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;

my $prefs = preferences('plugin.ratingslight');
my $log   = logger('plugin.ratingslight');

my $plugin;
my %subPages = ();

sub new {
	my $class = shift;
	$plugin   = shift;
	my $default = shift;

	if(!defined($default) || !$default) {
		if ($class->can('page') && $class->can('handler')) {
			if(UNIVERSAL::can("Slim::Web::Pages","addPageFunction")) {
				Slim::Web::Pages->addPageFunction($class->page, $class);
			}else {
				Slim::Web::HTTP::addPageFunction($class->page, $class);
			}
		}
	}else {
		$class->SUPER::new();
	}
	$subPages{$class->name()} = $class;
	return $class;
}

sub handler {
	my ($class, $client, $params) = @_;

	my %currentSubPages = ();
	for my $key (keys %subPages) {
		my $pages = $subPages{$key}->pages($client,$params);
		for my $page (@$pages) {
			$currentSubPages{$page->{'name'}} = $page->{'page'};
		}
	}
	$params->{'subpages'} = \%currentSubPages;
	$params->{'subpage'} = $class->currentPage($client,$params);
	return $class->SUPER::handler($client, $params);
}

1;
