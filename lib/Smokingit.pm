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

sub test {
    my $self = shift;

    my $arg = shift;
    my $action = Smokingit::Action::Test->new(
        current_user => Smokingit::CurrentUser->superuser,
        arguments    => { commit => $arg },
    );
    $action->validate;
    return $action->result->field_error("commit") . "\n"
        unless $action->result->success;
    $action->run;
    return ($action->result->message || $action->result->error);
}

1;
