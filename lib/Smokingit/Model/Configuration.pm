use strict;
use warnings;

package Smokingit::Model::Configuration;
use Jifty::DBI::Schema;

use Smokingit::Record schema {
    column project_id =>
        references Smokingit::Model::Project;

    column name =>
        is mandatory,
        label is "Name",
        type is "text";

    column configure_cmd =>
        type is 'text',
        label is "Configuration commands",
        default is 'perl Makefile.PL && make',
        render_as 'Textarea';

    column env =>
        type is 'text',
        label is "Environment variables",
        render_as 'Textarea';

    column test_glob =>
        type is 'text',
        label is 'Glob of test files',
        default is "t/*.t";

    column parallel =>
        is boolean,
        label is 'Parallel testing?',
        default is 't';
};

sub create {
    my $self = shift;
    my %args = (
        @_,
    );

    # Lock on the project
    Jifty->handle->begin_transaction;
    my $project = Smokingit::Model::Project->new;
    $project->row_lock(1);
    $project->load( $args{project_id} );

    my ($ok, $msg) = $self->SUPER::create(%args);
    unless ($ok) {
        Jifty->handle->rollback;
        return ($ok, $msg);
    }

    # Find the distinct set of branch tips
    my %commits;
    my $branches = $project->branches;
    while (my $b = $branches->next) {
        warn "Current head @{[$b->name]} is @{[$b->current_commit->short_sha]}\n";
        $commits{$b->current_commit->id}++;
    }

    # Add a TestedHead for each of the above
    for my $commit_id (keys %commits) {
        my $head = Smokingit::Model::TestedHead->new;
        $head->create(
            project_id       => $project->id,
            configuration_id => $self->id,
            commit_id        => $commit_id,
        );
    }

    # Schedule tests
    $project->schedule_tests;

    Jifty->handle->commit;
}

1;

