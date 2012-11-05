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
    Jifty->rpc->call(
        name => "sync_project",
        args => $self->name,
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
    $commit->load_by_cols( project_id => $self->id, sha => $sha );
    return $commit if $commit->id;

    $commit->as_superuser->create( project_id => $self->id, sha => $sha );
    $commit->load_by_cols( project_id => $self->id, sha => $sha );
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

sub trunks {
    my $self = shift;
    my $trunks = $self->branches;
    $trunks->limit( column => "status", value => "master" );
    return $trunks;
}

sub trunk_or_relengs {
    my $self = shift;
    my $branches = $self->branches;
    $branches->limit( column => "status", value => "master", entry_aggregator => "or" );
    $branches->limit( column => "status", value => "releng", entry_aggregator => "or" );
    return $branches;
}

sub planned_tests {
    my $self = shift;
    my $tests = Smokingit::Model::SmokeResultCollection->new;
    $tests->limit(
        column => "queue_status",
        operator => "IS NOT",
        value => "NULL"
    );
    $tests->limit( column => "project_id", value => $self->id );
    $tests->order_by(
        { column => "queued_at", order  => "asc" },
        { column => "id",        order  => "asc" },
    );
    $tests->prefetch( name => "commit" );
    return $tests;
}

sub finished_tests {
    my $self = shift;
    my $tests = Smokingit::Model::SmokeResultCollection->new;
    $tests->limit(
        column => "queue_status",
        operator => "IS",
        value => "NULL"
    );
    $tests->limit( column => "project_id", value => $self->id );
    $tests->order_by(
        { column => "submitted_at", order  => "desc" },
        { column => "id",           order  => "desc" },
    );
    $tests->prefetch( name => "commit" );
    return $tests;
}

sub update_repository {
    my $self = shift;
    local $ENV{GIT_DIR} = $self->repository_path;
    `git fetch --all --prune --quiet`;
}

sub sync {
    my $self = shift;

    # Start a txn
    Jifty->handle->begin_transaction;

    # Make sure we have a repository
    if (-d $self->repository_path) {
        warn "Updating " . $self->name ."\n";
        $self->update_repository;
    } else {
        warn "Cloning " . $self->name."\n";
        system("git", "clone", "--quiet", "--mirror",
               $self->repository_url,
               $self->repository_path);
    }

    # Sync up the branches
    local $ENV{GIT_DIR} = $self->repository_path;

    my %branches;
    for ($self->repository->ref_names) {
        next unless s{^refs/heads/}{};
        $branches{$_}++;
    }

    my @messages;
    my $branches = $self->branches;
    while (my $branch = $branches->next) {
        if (not $branches{$branch->name}) {
            $branch->delete;
            push @messages, $branch->name." deleted";
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
        push @messages, $branch->name." updated with @{[scalar @revs]} commits";
    }

    my $test_new = $branches->count ? 1 : 0;
    my $has_master = delete $branches{master};

    for my $name (($has_master ? ("master") : ()), sort keys %branches) {
        warn "New branch $name\n";
        my $trunk = ($name eq "master");
        my $sha = $self->repository->ref_sha1("refs/heads/$name");
        my $branch = Smokingit::Model::Branch->new;
        my $status = $trunk    ? "master"  :
                     $test_new ? "hacking" :
                                 "ignore";
        my ($ok, $msg) = $branch->create(
            project_id    => $self->id,
            name          => $name,
            sha           => $sha,
            status        => $status,
            long_status   => "",
            to_merge_into => undef,
            plan_tests    => 0,
        );
        warn "Create failed: $msg" unless $ok;
        push @messages, $branch->name." created, status $status";
    }

    my $tests = $self->schedule_tests;
    Jifty->handle->commit;

    push @messages, "$tests commits scheduled for testing" if $tests;
    return map {$self->name.": $_"} @messages;
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
        my @filter = (    $branch->current_commit->sha,
                       map {"^".$_->tested_commit->sha} @branches );

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

sub current_user_can {
    my $self  = shift;
    my $right = shift;
    my %args  = (@_);

    return 1 if $right eq 'create' and $self->current_user->id;
    return 1 if $right eq 'read';
    return 1 if $right eq 'update' and $self->current_user->id;
    return 1 if $right eq 'delete' and $self->current_user->id;

    return $self->SUPER::current_user_can($right => %args);
}

1;

