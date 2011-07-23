use strict;
use warnings;

=head1 NAME

Smokingit::Action::UpdateBranch

=cut

package Smokingit::Action::UpdateBranch;
use base qw/Smokingit::Action Smokingit::Action::Record::Update/;

sub arguments {
    my $self = shift;
    return $self->{__cached_arguments}
        if ( exists $self->{__cached_arguments} );

    my $args = $self->SUPER::arguments;

    my $branches = $self->record->project->trunk_or_relengs;

    $args->{to_merge_into}{valid_values} = [
        {
            display => 'None',
            value   => '',
        },
        {
            display_from => 'name',
            value_from   => 'id',
            collection   => $branches,
        },
    ];

    $args->{owner}{ajax_autocompletes} = 1;
    $args->{owner}{autocompleter} = $self->autocompleter("owner");
    $args->{review_by}{ajax_autocompletes} = 1;
    $args->{review_by}{autocompleter} = $self->autocompleter("review_by");

    return $self->{__cached_arguments} = $args;
}

sub autocompleter {
    my $self = shift;
    my $skip = shift eq "owner" ? "review_by" : "owner";
    return sub {
        my $self = shift;
        my $current = shift;
        my %results;

        my $commits = Smokingit::Model::CommitCollection->new;
        $commits->limit( column => 'project_id', value => $self->record->project->id );
        $commits->limit( column => 'author', operator => 'MATCHES', value => $current );
        $results{$_}++ for $commits->distinct_column_values("author");

        for my $column (qw/owner review_by/) {
            my $branches = Smokingit::Model::BranchCollection->new;
            $branches->limit(
                column => $column,
                operator => 'MATCHES',
                value => $current,
            );
            $results{$_}++ for $branches->distinct_column_values($column);
        }
        delete $results{$self->record->$skip};

        my @results = sort keys %results;
        return if @results == 1 and $results[0] eq $current;
        return sort @results;
    };
}


sub report_success {
    my $self = shift;
    $self->record->set_last_status_update($self->record->current_commit->id);
    $self->SUPER::report_success;
}

1;

