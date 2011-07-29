use strict;
use warnings;

package Smokingit::Model::Commit;
use Jifty::DBI::Schema;

use Smokingit::Record schema {
    column project_id =>
        references Smokingit::Model::Project;

    column sha =>
        type is 'text',
        is mandatory,
        is unique,
        is case_sensitive,
        is indexed;

    column author =>
        type is 'text';

    column authored_time =>
        is timestamp;

    column committer =>
        type is 'text';

    column committed_time =>
        is timestamp;

    column parents =>
        type is 'text';

    column subject =>
        type is 'text';

    column body =>
        type is 'text';
};

sub create {
    my $self = shift;
    my %args = (
        @_,
    );
    my $str = `git rev-list --format=format:"%aN <%aE>%n%at%n%cN <%cE>%n%ct%n%P%n%s%n%b" $args{sha} -n1`;
    (undef, @args{qw/author authored_time committer committed_time parents subject body/})
        = split /\n/, $str, 8;
    $args{$_} = Jifty::DateTime->from_epoch( $args{$_} )
        for qw/authored_time committed_time/;

    $args{sha} = lc $args{sha};
    die "Not a full SHA!" unless length $args{sha} == 40;
    my ($ok, $msg) = $self->SUPER::create(%args);
    return ($ok. $msg) unless $ok;
}

sub load_by_cols {
    my $self = shift;
    my %cols = @_;
    $cols{sha} = lc $cols{sha} if $cols{sha};
    return $self->SUPER::load_by_cols(%cols);
}

sub short_sha {
    my $self = shift;
    return substr($self->sha,0,7);
}

sub run_smoke {
    my $self = shift;
    my $config = shift;
    my $branch = shift;

    my %lookup = (
        project_id       => $self->project->id,
        configuration_id => $config->id,
        commit_id        => $self->id,
    );
    my $smoke = Smokingit::Model::SmokeResult->new;
    $smoke->load_by_cols( %lookup );
    return 0 if $smoke->id;

    $smoke->create(
        %lookup,
        branch_name => $branch->name,
    );
    return $smoke->run_smoke;
}

sub hash_results {
    my $self = shift;
    my $results = $self->prefetched( "smoke_results" );
    unless ($results) {
        warn "$self does not have smoke_results prefetched!\n";
        return;
    }
    $self->{results} = {};
    $self->{results}{$_->configuration->id} = $_
        for @{$results->items_array_ref};
}

sub status {
    my $self = shift;
    my $on = shift;

    if ($on) {
        my $result = Smokingit::Model::SmokeResult->new;
        if ($on->isa("Smokingit::Model::SmokeResult")) {
            $result = $on;
        } elsif ($on->isa("Smokingit::Model::Configuration")) {
            if (exists $self->{results}) {
                $result = $self->{results}{$on->id}
                    if exists $self->{results}{$on->id};
            } else {
                $result->load_by_cols(
                    project_id => $self->project->id,
                    configuration_id => $on->id,
                    commit_id => $self->id,
                );
            }
        } else {
            die "Unknown argument to Smokingit::Model::Commit->status: $on";
        }

        if (not $result->id) {
            return ("untested", "");
        } elsif ($result->gearman_process) {
            my $status = $result->gearman_status;
            if (not $status->known) {
                return ("broken", "Unknown");
            } elsif ($status->running) {
                my $percent = defined $status->percent
                    ? int($status->percent*100)."%" : undef;
                my $msg = defined $percent
                    ? "$percent complete"
                        : "Configuring";
                return ("testing", $msg, $percent);
            } else {
                return ("queued", "Queued to test");
            }
        } elsif ($result->error) {
            return ("errors", $result->short_error);
        } elsif ($result->is_ok) {
            return ("passing", $result->passed . " OK")
        } elsif ($result->failed) {
            return ("failing", $result->failed . " failed");
        } elsif ($result->parse_errors) {
            return ("parsefail", $result->parse_errors . " parse errors");
        } elsif ($result->exit) {
            return ("failing", "Bad exit status (".$result->exit.")");
        } elsif ($result->wait) {
            return ("failing", "Bad wait status (".$result->wait.")");
        } elsif ($result->todo_passed) {
            return ("todo", $result->todo_passed . " TODO passed");
        } else {
            return ("failing", "Unknown failure");
        }
    } elsif ($self->{status}) {
        return $self->{status};
    } else {
        my @results;
        if (exists $self->{results}) {
            @results = values %{$self->{results}};
        } else {
            my $smoked = Smokingit::Model::SmokeResultCollection->new;
            $smoked->limit( column => "commit_id", value => $self->id );
            $smoked->limit( column => "project_id", value => $self->project->id );
            @results = @{$smoked->items_array_ref};
        }
        my %results;
        for my $result (@results) {
            my ($status) = $self->status($result);
            $results{$status}++;
        }
        for my $st (qw/broken errors failing todo passing parsefail testing queued/) {
            return $self->{status} = $st if $results{$st};
        }
        return $self->{status} = "untested";
    }
}

sub long_status {
    my $self = shift;
    my %long = (
        untested  => "Untested",
        queued    => "Queued for testing",
        testing   => "Running tests",
        passing   => "Passing all tests",
        todo      => "TODO tests unexpectedly passed",
        parsefail => "Parse failures!",
        failing   => "Failing tests!",
        errors    => "Configuration errors!",
        broken    => "Unknown failure!"
    );
    return $long{$self->status};
}

sub parents {
    my $self = shift;
    return map {$self->project->sha($_)} split ' ', $self->_value('parents');
}

1;

