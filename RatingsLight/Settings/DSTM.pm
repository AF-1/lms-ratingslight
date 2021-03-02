package Plugins::RatingsLight::Settings::DSTM;

use strict;
use warnings;
use utf8;

use base qw(Plugins::RatingsLight::Settings::BaseSettings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;

use Data::Dumper;

my $prefs = preferences('plugin.ratingslight');
my $log = logger('plugin.ratingslight');

my $plugin;

sub new {
	my $class = shift;
	$plugin = shift;
	$class->SUPER::new($plugin);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_RATINGSLIGHT_SETTINGS_DSTM');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/RatingsLight/settings/dstm.html');
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
	return ($prefs, qw(dstm_minTrackDuration dstm_percentagerated dstm_percentageratedhigh num_seedtracks));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $callHandler = 1;
	if ($paramRef->{'saveSettings'}) {
 		my $excludegenres;
 		my $excludegenres_namelist;
		my $dbh = Slim::Schema->storage->dbh();
		my $sqlstatement = "select id,name from genres";
		my $sth = $dbh->prepare( $sqlstatement );
		$sth->execute();
		my ($excludedgenre_id, $excludedgenre_name);
		$sth->bind_col(1,\$excludedgenre_id);
		$sth->bind_col(2,\$excludedgenre_name);

		while( $sth->fetch()) {
 			my $excludedgenre_value = $paramRef->{"pref_excludedgenre_$excludedgenre_id"};
 			if ((defined $excludedgenre_value) && ($excludedgenre_value == 1)) {
				push (@$excludegenres, {id => $excludedgenre_id, name => $excludedgenre_name, chosen => 'yes'});
  				push(@$excludegenres_namelist, $excludedgenre_name);
 			} else {
 				push (@$excludegenres, {id => $excludedgenre_id, name => $excludedgenre_name, chosen => ''});
 			}
		}
		$sth->finish();

 		$prefs->set('excludegenres_namelist', $excludegenres_namelist);
 		$log->debug('*** saved *** excludegenres_namelist = '.Dumper($excludegenres_namelist));
 		$paramRef->{@$excludegenres} = $excludegenres;
 		#$log->debug('*** saved *** excludegenres = '.Dumper(@$excludegenres));

		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	}elsif($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
	}

	# push to settings page

	$paramRef->{excludedgenrelist} = [];

	my $excludegenres;
	my $excludegenres_namelist = $prefs->get('excludegenres_namelist');
	$log->debug('*** loaded *** excludegenres_namelist = '.Dumper($excludegenres_namelist));

	my $dbh = Slim::Schema->storage->dbh();
	my $sqlstatement = "select id,name from genres order by namesort asc";

	my $sth = $dbh->prepare( $sqlstatement );
	$sth->execute();

	my ($excludedgenre_id, $excludedgenre_name);
	$sth->bind_col(1,\$excludedgenre_id);
	$sth->bind_col(2,\$excludedgenre_name);

	while( $sth->fetch()) {
		my %excludedgenres_chosen = map { $_ => 1 } @$excludegenres_namelist;
		if(exists($excludedgenres_chosen{$excludedgenre_name})) {
			push (@$excludegenres, {id => $excludedgenre_id, name => smartdecode($excludedgenre_name), chosen => 'yes'});
		} else {
			push (@$excludegenres, {id => $excludedgenre_id, name => smartdecode($excludedgenre_name), chosen => ''});
		}
	}
	$sth->finish();

	foreach my $thisgenre (@$excludegenres) {
			push( @{$paramRef->{excludedgenrelist}}, $thisgenre);
	}

	$result = $class->SUPER::handler($client, $paramRef);

	return $result;
}

sub smartdecode {
    use URI::Escape qw( uri_unescape );
    use utf8;
    my $x = my $y = uri_unescape($_[0]);
    return $x if utf8::decode($x);
    return $y;
}

1;
