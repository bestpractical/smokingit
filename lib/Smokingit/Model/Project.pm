use strict;
use warnings;

package Smokingit::Model::Project;
use Jifty::DBI::Schema;

use Smokingit::Record schema {
    column "name" =>
        type is 'text',
        is mandatory,
        is distinct,
        is indexed,
        label is _("Project name");

    column repository_url =>
        type is 'text',
        is mandatory,
        label is _("Repository URL");
};

use IO::Handle;
use Git::PurePerl;

sub create {
    my $self = shift;
    my %args = (
        @_,
    );

    my $repo = eval { Git::PurePerl::Protocol->new(
        remote => $args{repository_url},
    ) };
    return (0, "Repository validation failed") unless $repo;

    my ($ok, $msg) = $self->SUPER::create(%args);
    return ($ok, $msg) unless $ok;

    # Kick off the clone in the background
    Smokingit->gearman->dispatch_background(
        sync_project => $self->name,
    );

    return ($ok, $msg);
}

sub repository_path {
    my $self = shift;
    return Jifty::Util->app_root . "/var/repos/" . $self->name;
}

sub repository {
    my $self = shift;
    return $self->{repository} ||= Git::PurePerl->new(
        gitdir => $self->repository_path,
    );
}

sub sha {
    my $self = shift;
    my $sha = shift;
    local $ENV{GIT_DIR} = $self->repository_path;
    my $commit = Smokingit::Model::Commit->new;
    $commit->load_or_create( project_id => $self->id, sha => $sha );
    return $commit;
}

sub configurations {
    my $self = shift;
    my $configs = Smokingit::Model::ConfigurationCollection->new;
    $configs->limit(
        column => 'project_id',
        value => $self->id,
    );
    $configs->order_by( column => "id" );
    return $configs;
}

sub branches {
    my $self = shift;
    my $branches = Smokingit::Model::BranchCollection->new;
    $branches->limit(
        column => 'project_id',
        value => $self->id,
    );
    $branches->order_by( column => "name" );
    return $branches;
}

sub tested_heads {
    my $self = shift;
    my $tested = Smokingit::Model::TestedHeadCollection->new;
    $tested->limit(
        column => 'project_id',
        value => $self->id,
    );
    return $tested;
}

sub planned_tests {
    my $self = shift;
    my $tests = Smokingit::Model::SmokeResultCollection->new;
    $tests->limit(
        column => "gearman_process",
        operator => "IS NOT",
        value => "NULL"
    );
    $tests->limit( column => "project_id", value => $self->id );
    my @tests = @{ $tests->items_array_ref };
    @tests = sort { $b->gearman_status->running     <=>  $a->gearman_status->running
                or ($b->gearman_status->percent||0) <=> ($a->gearman_status->percent||0)
                or  $a->id                          <=>  $b->id} @tests;
    return @tests;
}

sub update_repository {
    my $self = shift;
    local $ENV{GIT_DIR} = $self->repository_path;
    `git fetch --all --prune --quiet`;
}

sub sync_branches {
    my $self = shift;
    warn "sync_branches called with no row lock!"
        unless $self->row_lock;

    local $ENV{GIT_DIR} = $self->repository_path;

    my %branches;
    for ($self->repository->ref_names) {
        next unless s{^refs/heads/}{};
        $branches{$_}++;
    }

    my $branches = $self->branches;
    while (my $branch = $branches->next) {
        if (not $branches{$branch->name}) {
            $branch->delete;
            next;
        }
        delete $branches{$branch->name};
        my $new_ref = $self->repository->ref_sha1("refs/heads/" . $branch->name);
        my $old_ref = $branch->current_commit->sha;
        next if $new_ref eq $old_ref;

        warn "Update @{[$branch->name]} $old_ref -> $new_ref\n";
        my @revs = map {chomp; $_} `git rev-list ^$old_ref $new_ref`;
        $self->sha( $_ ) for reverse @revs;
        $branch->set_current_commit_id($self->sha($new_ref)->id);
    }

    for my $name (keys %branches) {
        warn "New branch $name\n";
        my $trunk = ($name eq "master");
        my $sha = $self->repository->ref_sha1("refs/heads/$name");
        my $branch = Smokingit::Model::Branch->new;
        my ($ok, $msg) = $branch->create(
            project_id    => $self->id,
            name          => $name,
            sha           => $sha,
            status        => $trunk ? "master" : "ignore",
            long_status   => "",
            to_merge_into => undef,
        );
        warn "Create failed: $msg" unless $ok;
    }
    $self->schedule_tests;
}

sub schedule_tests {
    my $self = shift;
    warn "schedule_tests called with no row lock!"
        unless $self->row_lock;

    local $ENV{GIT_DIR} = $self->repository_path;

    # Determine the possible tips to test
    my %branches;
    my $branches = $self->branches;
    while (my $branch = $branches->next) {
        $branches{$branch->current_commit->sha}++
            if $branch->is_tested;
    }

    # Bail early if there are no testable branches
    return unless keys %branches;

    my $smokes = 0;
    my $configs = $self->configurations;
    while (my $config = $configs->next) {
        # Find the set of already-covered commits
        my %tested;
        my $tested = $self->tested_heads;
        $tested->limit( column => 'configuration_id', value => $config->id );
        while (my $head = $tested->next) {
            $tested{$head->commit->sha} = $head;
        }

        warn "Looking for possible @{[$config->name]} tests\n";
        my @filter = (keys(%branches), map "^$_", keys %tested);
        my @lines = split /\n/, `git rev-list --reverse --parents @filter`;
        for my $l (@lines) {
            # We only want to test it if both parents have existing tests
            my ($commit, @shas) = split ' ', $l;
            my @tested = grep {defined} map {$tested{$_}} @shas;
            warn "Looking at $commit (parents @shas)\n";
            if (@tested < @shas) {
                warn "  Parents which are not tested\n";
                next;
            }
            my @pending = grep {$_->gearman_process} map {$_->smoke_result} @tested;
            if (@pending) {
                warn "  Parents which are still testing\n";
                next;
            }

            warn "  Sending to testing.\n";

            my $to_test = Smokingit::Model::Commit->new;
            $to_test->load_by_cols( project_id => $self->id, sha => $commit );

            $_->delete for @tested;
            my $head = Smokingit::Model::TestedHead->new;
            $head->create(
                project_id       => $self->id,
                configuration_id => $config->id,
                commit_id        => $to_test->id,
            );
            $smokes += $to_test->run_smoke($config);
        }
    }

    # As a fallback, ensure that all testable heads have been tested,
    # even if they are kids of existing testedhead objects
    while (my $config = $configs->next) {
        for my $sha (keys %branches) {
            my $commit = Smokingit::Model::Commit->new;
            $commit->load_by_cols( project_id => $self->id, sha => $sha );

            my $existing = Smokingit::Model::SmokeResult->new;
            $existing->load_by_cols(
                project_id       => $self->id,
                configuration_id => $config->id,
                commit_id        => $commit->id,
            );
            next if $existing->id;
            warn "Smoking untested head ".join(":",$config->name,$commit->short_sha)."\n";
            $smokes += $commit->run_smoke($config);
        }
    }

    return $smokes;
}

1;

