use strict;
use warnings;

package Smokingit::Model::User;
use Jifty::DBI::Schema;

use Smokingit::Record schema {};

use Jifty::Plugin::User::Mixin::Model::User;
use Jifty::Plugin::Authentication::Password::Mixin::Model::User;

sub is_protected {1}

sub since { '0.0.6' }

sub create {
    my $self = shift;
    my (%args) = @_;
    $args{email} ||= $args{name} . '@bestpractical.com';
    $args{email_confirmed} = 1;
    $self->SUPER::create(%args);
}

sub current_user_can {
    my $self  = shift;
    my $right = shift;
    my %args  = (@_);

    return 1 if $right eq "read";
    return 1 if $right eq "update"
        and $self->current_user->id == $self->id;

    return $self->SUPER::current_user_can( $right, %args );
}

1;
