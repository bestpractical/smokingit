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

    my ($ok, $msg) = $self->SUPER::create(%args);
    return ($ok. $msg) unless $ok;
}

sub short_sha {
    my $self = shift;
    return substr($self->sha,0,7);
}

sub is_smoked {
    my $self = shift;
    return $self->smoked->count > 0;
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
        from_branch_id => $branch->id,
    );
    return $smoke->run_smoke;
}

sub status {
    my $self = shift;
    my $config = shift;

    if ($config) {
        my $result = Smokingit::Model::SmokeResult->new;
        $result->load_by_cols(
            project_id => $self->project->id,
            configuration_id => $config->id,
            commit_id => $self->id,
        );
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
            return ("failing", $result->parse_errors . " parse errors");
        } elsif ($result->exit) {
            return ("failing", "Bad exit status (".$result->exit.")");
        } elsif ($result->wait) {
            return ("failing", "Bad wait status (".$result->wait.")");
        } elsif ($result->todo_passed) {
            return ("todo", $result->todo_passed . " TODO passed");
        } else {
            return ("failing", "Unknown failure");
        }
    } else {
        my $smoked = $self->smoked;
        my $passing = 0;
        if ($smoked->count) {
            while (my $smoke = $smoked->next) {
                next if $smoke->gearman_process;
                return "failing" unless $smoke->is_ok;
                $passing++;
            }
            return $passing ? "passing" : "testing";
        }

        return "untested";
    }
}

sub smoked {
    my $self = shift;
    my $config = shift;
    if ($config) {
        my $smoke = Smokingit::Model::SmokeResult->new;
        $smoke->load_by_cols(
            project_id => $self->project->id,
            commit_id => $self->id,
            configuration_id => $config->id,
        );
        return $smoke;
    } else {
        my $smoked = Smokingit::Model::SmokeResultCollection->new;
        $smoked->limit( column => "commit_id", value => $self->id );
        $smoked->limit( column => "project_id", value => $self->project->id );
        return $smoked;
    }
}

sub parents {
    my $self = shift;
    return map {$self->project->sha($_)} split ' ', $self->_value('parents');
}

1;

