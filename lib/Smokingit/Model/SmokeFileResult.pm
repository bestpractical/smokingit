use strict;
use warnings;

package Smokingit::Model::SmokeFileResult;
use Jifty::DBI::Schema;
use Smokingit::Status;

use Smokingit::Record schema {
    column smoke_result_id =>
        is mandatory,
        references Smokingit::Model::SmokeResult,
        is indexed;

    column filename  => type is 'text';
    column elapsed   => type is 'float';
    column is_ok     => is boolean;
    column raw_tap   => type is 'text';
    column tests_run => type is 'integer';
};

sub since { '0.0.8' }

sub is_protected {1}

sub current_user_can {
    my $self  = shift;
    my $right = shift;
    my %args  = (@_);

    return 1 if $right eq 'read';

    return $self->SUPER::current_user_can($right => %args);
}

1;
