use strict;
use warnings;

package Smokingit::Model::SmokeResult;
use Jifty::DBI::Schema;
use Smokingit::Status;

use Smokingit::Record schema {
    column project_id =>
        is mandatory,
        references Smokingit::Model::Project;

    column configuration_id =>
        is mandatory,
        references Smokingit::Model::Configuration;

    column commit_id =>
        is mandatory,
        is indexed,
        references Smokingit::Model::Commit;

    column from_branch_id =>
        references Smokingit::Model::Branch,
        till '0.0.4';

    column branch_name =>
        type is 'text',
        since '0.0.4';

    column gearman_process =>
        type is 'text',
        till '0.0.7';

    column queue_status =>
        type is 'text',
        since '0.0.7';

    column queued_at =>
        is timestamp,
        since '0.0.5';

    column submitted_at =>
        is timestamp;

    column error =>
        type is 'text';

    column aggregator =>
        type is 'blob',
        filters are 'Jifty::DBI::Filter::Storable',
        till '0.0.8';

    column is_ok        => is boolean;

    column failed       => type is 'integer';
    column parse_errors => type is 'integer';
    column passed       => type is 'integer';
    column planned      => type is 'integer';
    column skipped      => type is 'integer';
    column todo         => type is 'integer';
    column todo_passed  => type is 'integer';
    column total        => type is 'integer',
        since '0.0.8';

    column wait         => type is 'integer';
    column exit         => type is 'integer';

    column elapsed      => type is 'float';
};
sub is_protected {1}

sub short_error {
    my $self = shift;
    my $msg = ($self->error || "");
    $msg =~ s/\n.*//s;
    return $msg;
}

sub run_smoke {
    my $self = shift;

    if ($self->queue_status) {
        warn join( ":",
              $self->project->name,
              $self->configuration->name,
              $self->commit->short_sha
          )." is already in the queue\n";
        return 0;
    }

    warn "Smoking ".
        join( ":",
              $self->project->name,
              $self->configuration->name,
              $self->commit->short_sha
          )."\n";

    my $status = Smokingit::Status->new( $self );
    Jifty->rpc->call(
        name => "run_tests",
        args => {
            smoke_id       => $self->id,

            project        => $self->project->name,
            repository_url => $self->project->repository_url,
            sha            => $self->commit->sha,
            configure_cmd  => $self->configuration->configure_cmd,
            env            => $self->configuration->env,
            parallel       => ($self->configuration->parallel ? 1 : 0),
            test_glob      => $self->configuration->test_glob,
        },
        on_sent => sub {
            my $ok = shift;
            $self->as_superuser->set_queue_status($ok ? "queued" : "broken");
            # Use SQL so we get millisecond accuracy in the DB.  Otherwise rows
            # inserted during the same second may not sort the same as they show
            # up in the worker's queue.
            $self->__set( column => 'queued_at', value => 'now()', is_sql_function => 1 );
            $self->load($self->id);

            # If we had a result for this already, we need to clean its status
            # out of the memcached cache.  Remove both the cache on the commit,
            # as well as this smoke.
            Smokingit->memcached->delete( $self->commit->status_cache_key );
            Smokingit->memcached->delete( $self->status_cache_key );

            $status->publish;
        },
    );

    return 1;
}

sub status_cache_key {
    my $self = shift;
    return "status-" . $self->commit->sha . "-" . $self->configuration->id;
}

sub post_result {
    my $self = shift;
    my ($arg) = @_;

    my %result = %{ $arg };
    delete $result{start};
    delete $result{end};

    my %tests = %{ delete $result{test} };

    my $status = Smokingit::Status->new( $self );

    # Find the smoke
    Jifty->handle->begin_transaction;
    my $smokeid = delete $result{smoke_id};
    $self->load( $smokeid );
    if (not $self->id) {
        Jifty->handle->rollback;
        return (0, "Invalid smoke ID: $smokeid");
    } elsif (not $self->queue_status) {
        Jifty->handle->rollback;
        return (0, "Smoke report on $smokeid which wasn't being smoked? (last report at @{[$self->submitted_at]})");
    }

    # Use SQL so we get millisecond accuracy in the DB.  This is not as
    # necessary as for queued_at (above), but is useful nonetheless.
    $self->__set( column => 'submitted_at', value => 'now()', is_sql_function => 1 );

    # Update with the new data
    for my $key (keys %result) {
        my $method = "set_$key";
        $self->$method($result{$key});
    }
    # Mark as no longer smoking
    $self->set_queue_status(undef);

    # Delete all previous test file results
    my $testfiles = Smokingit::Model::SmokeFileResultCollection->new(
        current_user => Smokingit::CurrentUser->superuser,
    );
    $testfiles->limit( column => "smoke_result_id", value => $self->id );
    while (my $fileresult = $testfiles->next) {
        $fileresult->delete;
    }

    # Create rows for all test files
    for my $filename (sort keys %tests) {
        my $fileresult = Smokingit::Model::SmokeFileResult->new(
            current_user => Smokingit::CurrentUser->superuser,
        );
        my ($ok, $msg) = $fileresult->create(
            %{$tests{$filename}},
            filename => $filename,
            smoke_result_id => $self->id,
        );
        warn "Failed to create entry for $filename: $msg"
            unless $ok;
    }

    # And commit all of that
    Jifty->handle->commit;

    $status->publish;

    return (1, "Test result for "
             . $self->project->name
             ." ". $self->commit->short_sha
             ." using ". $self->configuration->name
             ." on ". $self->branch_name
             .": ".($self->is_ok ? "OK" : "NOT OK"));
}


sub current_user_can {
    my $self  = shift;
    my $right = shift;
    my %args  = (@_);

    return 1 if $right eq 'read';

    return $self->SUPER::current_user_can($right => %args);
}

1;

