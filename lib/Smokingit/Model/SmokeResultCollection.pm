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

sub queued {
    my $class = shift;
       $class = ref($class) if ref($class);

    my $queued = $class->new;
    $queued->limit_to_queued;
    $queued->prefetch( name => "project" );
    $queued->prefetch( name => "commit" );
    return $queued;
}

sub limit_to_queued {
    my $self = shift;
    $self->limit(
        column => "queue_status",
        operator => "IS NOT",
        value => "NULL"
    );
    $self->order_by(
        { column => "queued_at", order  => "asc" },
        { column => "id",        order  => "asc" },
    );
}

1;
