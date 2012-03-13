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

sub check_queue {
    my $job = shift;
    my $queued = Smokingit::Model::SmokeResultCollection->new;
    $queued->limit(
        column => "submitted_at",
        operator => "IS",
        value => "NULL",
    );
    my $restarted = 0;
    while (my $smoke = $queued->next) {
        next if $smoke->gearman_status->known;
        $restarted += $smoke->run_smoke;
    }
    return $restarted;
}

1;
