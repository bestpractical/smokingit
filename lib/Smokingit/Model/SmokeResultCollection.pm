use strict;
use warnings;

package Smokingit::Model::SmokeResultCollection;
use base qw/Smokingit::Collection/;

sub implicit_clauses {
    my $self = shift;
    my @cols = map {$_->name}
      grep {!$_->virtual and !$_->computed and $_->type ne "blob"}
	$self->record_class->columns;
    $self->columns(@cols);
}

1;
