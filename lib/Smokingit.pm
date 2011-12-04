use strict;
use warnings;

package Smokingit;
use Gearman::Client;
use Cache::Memcached;

our( $GEARMAN, $MEMCACHED );

sub start {
    $GEARMAN = Gearman::Client->new;
    $GEARMAN->job_servers( Jifty->config->app('job_servers') );

    $MEMCACHED = Cache::Memcached->new(
        { servers => Jifty->config->app( 'memcached_servers' ) } );
}

sub gearman   { $GEARMAN   }
sub memcached { $MEMCACHED }
1;
