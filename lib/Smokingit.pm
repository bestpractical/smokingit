use strict;
use warnings;

package Smokingit;
use Cache::Memcached;

our( $MEMCACHED );

sub start {
    $MEMCACHED = Cache::Memcached->new(
        { servers => Jifty->config->app( 'memcached_servers' ) } );
}

sub memcached { $MEMCACHED }

1;
