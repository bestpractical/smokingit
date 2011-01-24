use strict;
use warnings;

package Smokingit;
use Gearman::Client;

our $GEARMAN;

sub start {
    $GEARMAN = Gearman::Client->new;
    $GEARMAN->job_servers( Jifty->config->app('job_servers') );
}

sub gearman { $GEARMAN }

1;
