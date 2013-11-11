use strict;
use warnings;

package Smokingit::Model::Commit;
use Jifty::DBI::Schema;

use Smokingit::Record schema {
    column project_id =>
        references Smokingit::Model::Project;

    column sha =>
        type is 'text',
        is immutable,
        is mandatory,
        is unique,
        is case_sensitive,
        is indexed;

    column author =>
        type is 'text',
        is immutable;

    column authored_time =>
        is timestamp,
        is immutable;

    column committer =>
        type is 'text',
        is immutable;

    column committed_time =>
        is timestamp,
        is immutable;

    column parents =>
        type is 'text',
        is immutable;

    column subject =>
        type is 'text',
        is immutable;

    column body =>
        type is 'text',
        is immutable;
};
sub is_protected {1}

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

sub is_merge {
    my $self = shift;
    my @parents = $self->parents;
    return unless @parents > 1;
    return $1 if $self->subject =~ /^Merge branch '(.*?)'/;
    return 'Unknown branch';
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
    my $smoke = Smokingit::Model::SmokeResult->new(
        current_user => Smokingit::CurrentUser->superuser,
    );
    $smoke->load_by_cols( %lookup );
    return 0 if $smoke->id;

    $smoke->create(
        %lookup,
        branch_name => $branch->name,
    );
    return $smoke->run_smoke;
}

sub smoke_results {
    my $self = shift;
    my $results = Smokingit::Model::SmokeResultCollection->new;
    $results->limit( column => "commit_id", value => $self->id );
    $results->limit( column => "project_id", value => $self->project->id );
    $results->limit( column => "queue_status", operator => "IS", value => "NULL" );
    return $results;
}

sub hash_results {
    my $self = shift;
    my $results = shift || $self->prefetched( "smoke_results" );
    return unless $results;
    $self->{results} = {};
    $self->{results}{$_->configuration->id} = $_
        for @{$results->items_array_ref};
}

sub status {
    my $self = shift;
    my $on = shift;

    my $memcached = Smokingit->memcached;
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

        return ("untested", "") unless $result->id;

        my $cache_value = $memcached->get( $result->status_cache_key );
        return @{$cache_value} if $cache_value;

        my @return;
        if (my $status = $result->queue_status) {
            if ($status =~ /^(\d+%) complete$/) {
                return ("testing", $status, $1);
            } elsif ($status eq "queued") {
                return ("queued", "Queued to test");
            } elsif ($status eq "broken") {
                return ("broken", "Failed to queue!");
            } else {
                return ("testing", $status, undef);
            }
        } elsif ($result->error) {
            @return = ("errors", $result->short_error);
        } elsif ($result->is_ok) {
            @return = ("passing", $result->passed . " OK");
        } elsif ($result->failed) {
            @return = ("failing", $result->failed . " failed");
        } elsif ($result->parse_errors) {
            @return = ("parsefail", $result->parse_errors . " parse errors");
        } elsif ($result->exit) {
            @return = ("failing", "Bad exit status (".$result->exit.")");
        } elsif ($result->wait) {
            @return = ("failing", "Bad wait status (".$result->wait.")");
        } elsif ($result->todo_passed) {
            @return = ("todo", $result->todo_passed . " TODO passed");
        } else {
            @return = ("failing", "Unknown failure");
        }
        $memcached->set( $result->status_cache_key, \@return );
        return @return;
    } elsif (my $cache_value = $memcached->get( $self->status_cache_key ) ) {
        return $cache_value;
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
        my $status = "untested";
        for my $st (qw/broken errors failing todo passing parsefail testing queued/) {
            next unless $results{$st};
            $status = $st;
            last;
        }
        $memcached->set( $self->status_cache_key, $status)
            unless $results{broken} or $results{testing} or $results{queued}
                or $status eq "untested";
        return $status;
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

sub is_fully_smoked {
    my $self = shift;

    my $smoked = Smokingit::Model::SmokeResultCollection->new;
    $smoked->limit( column => "commit_id", value => $self->id );
    $smoked->limit( column => "project_id", value => $self->project->id );
    $smoked->limit(
        column => "queue_status",
        operator => "IS",
        value => "NULL"
    );

    my $configs = $self->project->configurations;

    my %need;
    $need{$_->id} = 1 for @{ $configs->items_array_ref };
    delete $need{$_->configuration->id} for @{ $smoked->items_array_ref };

    return 0 if keys %need;
    return 1;
}

sub parents {
    my $self = shift;
    return map {$self->project->sha($_)} split ' ', $self->_value('parents');
}

sub branches {
    my $self = shift;

    my $sha = $self->sha;

    local $ENV{GIT_DIR} = $self->project->repository_path;
    my @branches = map {s/^\s*(\*\s*)?//;chomp;$_}
        `git branch --contains $sha`;

    return @branches;
}

sub status_cache_key {
    my $self = shift;
    return "status-" . $self->sha;
}

sub current_user_can {
    my $self  = shift;
    my $right = shift;
    my %args  = (@_);

    return 1 if $right eq 'read';

    return $self->SUPER::current_user_can($right => %args);
}

sub jifty_serialize_format {
    my $self = shift;
    my $data = $self->SUPER::jifty_serialize_format(@_);
    $data->{status}      = $self->status;
    $data->{long_status} = $self->long_status;
    return $data;
}

1;

