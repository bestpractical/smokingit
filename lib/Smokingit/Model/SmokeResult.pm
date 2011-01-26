use strict;
use warnings;

package Smokingit::Model::SmokeResult;
use Jifty::DBI::Schema;

use Storable qw/freeze/;

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

    column gearman_process =>
        type is 'text';

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

sub short_error {
    my $self = shift;
    my $msg = ($self->error || "");
    $msg =~ s/\n.*//s;
    return $msg;
}

sub gearman_status {
    my $self = shift;
    return undef unless $self->gearman_process;
    return $self->{job_status} ||= Smokingit->gearman->get_status($self->gearman_process);
}

sub run_smoke {
    my $self = shift;

    if ($self->gearman_status->known) {
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

    my $job_id = Smokingit->gearman->dispatch_background(
        "run_tests",
        freeze( {
            smoke_id       => $self->id,

            project        => $self->project->name,
            repository_url => $self->project->repository_url,
            sha            => $self->commit->sha,
            configure_cmd  => $self->configuration->configure_cmd,
            env            => $self->configuration->env,
            parallel       => ($self->configuration->parallel ? 1 : 0),
            test_glob      => $self->configuration->test_glob,
        } ),
        { uniq => $self->id },
    );
    unless ($job_id) {
        warn "Unable to insert run_tests job!\n";
        return 0;
    }
    $self->set_gearman_process($job_id);
    return 1;
}

1;

