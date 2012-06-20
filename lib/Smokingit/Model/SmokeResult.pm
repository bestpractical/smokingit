use strict;
use warnings;

package Smokingit::Model::SmokeResult;
use Jifty::DBI::Schema;

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
        filters are 'Jifty::DBI::Filter::Storable';

    column is_ok        => is boolean;

    column failed       => type is 'integer';
    column parse_errors => type is 'integer';
    column passed       => type is 'integer';
    column planned      => type is 'integer';
    column skipped      => type is 'integer';
    column todo         => type is 'integer';
    column todo_passed  => type is 'integer';

    column wait         => type is 'integer';
    column exit         => type is 'integer';

    column elapsed      => type is 'integer';
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
            $self->as_superuser->set_queued_at( Jifty::DateTime->now );

            # If we had a result for this already, we need to clean its status
            # out of the memcached cache.  Remove both the cache on the commit,
            # as well as this smoke.
            Smokingit->memcached->delete( $self->commit->status_cache_key );
            Smokingit->memcached->delete( $self->status_cache_key );
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

    # Properties to extract from the aggregator
    my @props =
        qw/failed
           parse_errors
           passed
           planned
           skipped
           todo
           todo_passed
           wait
           exit/;

    # Aggregator might not exist if we had a configure failure
    require TAP::Parser::Aggregator;
    my $a = $result{aggregator};
    if ($a) {
        $result{$_} = $a->$_ for @props;
        $result{is_ok}      = not($a->has_problems);
        $result{elapsed}    = $a->elapsed->[0];
        $result{error}      = undef;
    } else {
        # Unset the existing data if there was a fail
        $result{$_} = undef for @props, "is_ok", "elapsed";
    }
    $result{submitted_at} = Jifty::DateTime->now;

    # Find the smoke
    Jifty->handle->begin_transaction;
    my $smokeid = delete $result{smoke_id};
    $self->load( $smokeid );
    if (not $self->id) {
        return (0, "Invalid smoke ID: $smokeid");
    } elsif (not $self->queue_status) {
        return (0, "Smoke report on $smokeid which wasn't being smoked? (last report at @{[$self->submitted_at]})");
    }

    # Update with the new data
    for my $key (keys %result) {
        my $method = "set_$key";
        $self->$method($result{$key});
    }
    # Mark as no longer smoking
    $self->set_queue_status(undef);

    # And commit all of that
    Jifty->handle->commit;

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

