use strict;
use warnings;

package Smokingit;
use Cache::Memcached;

our $VERSION = '1.00';

our( $MEMCACHED );

sub start {
    $MEMCACHED = Cache::Memcached->new(
        { servers => Jifty->config->app( 'memcached_servers' ) } );
    Jifty->web->add_javascript( "app-late.js" );
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
