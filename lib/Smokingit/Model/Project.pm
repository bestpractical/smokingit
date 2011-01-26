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
    @tests = sort { $a->gearman_status->known       <=>  $b->gearman_status->known
                or  $b->gearman_status->running     <=>  $a->gearman_status->running
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
    return $self->schedule_tests;
}

sub schedule_tests {
    my $self = shift;

    local $ENV{GIT_DIR} = $self->repository_path;

    my $smokes = 0;
    warn "Scheduling tests";

    # Go through branches, masters first
    my @branches;
    my $branches = $self->branches;
    $branches->limit( column => "status", value => "master" );
    push @branches, @{$branches->items_array_ref};
    $branches = $self->branches;
    $branches->limit( column => "status", operator => "!=", value => "master", entry_aggregator => "AND" );
    $branches->limit( column => "status", operator => "!=", value => "ignore", entry_aggregator => "AND" );
    push @branches, @{$branches->items_array_ref};
    warn "Branches: @{[map {$_->name} @branches]}\n";
    return unless @branches;

    my @configs = @{$self->configurations->items_array_ref};

    for my $branch (@branches) {
        # If there's nothing else happening, ensure that the tip is tested
        if ($branch->current_commit->id == $branch->tested_commit->id) {
            $smokes += $branch->current_commit->run_smoke($_, $branch) for @configs;
            next;
        }

        # Go looking for other commits to run
        my @filter = (      $branch->current_commit->sha,
                      "^" . $branch->tested_commit->sha);

        my @shas = map {$self->sha($_)} split /\n/, `git rev-list --reverse @filter`;

        for my $sha (@shas) {
            for my $config (@configs) {
                warn "Testing @{[$sha->short_sha]} on @{[$branch->name]} using @{[$config->name]}\n";
                $smokes += $sha->run_smoke($config, $branch);
            }
        }

        $branch->set_tested_commit_id($branch->current_commit->id);
    }

    return $smokes;
}

1;

