use strict;
use warnings;

package Smokingit::Model::Branch;
use Jifty::DBI::Schema;

use Smokingit::Record schema {
    column project_id =>
        references Smokingit::Model::Project;

    column name =>
        type is 'text',
        is mandatory,
        label is _("Branch name");

    column first_commit_id =>
        references Smokingit::Model::Commit;

    column current_commit_id =>
        references Smokingit::Model::Commit;

    column tested_commit_id =>
        references Smokingit::Model::Commit;

    column last_status_update =>
        references Smokingit::Model::Commit;

    column status =>
        type is 'text',
        is mandatory,
        valid_values are [
            { value => "ignore",         display => "Ignore" },
            { value => "hacking",        display => "Being worked on" },
            { value => "needs-tests",    display => "Needs tests" },
            { value => "needs-review",   display => "Needs review" },
            { value => "awaiting-merge", display => "Needs merge" },
            { value => "merged",         display => "Merged" },
            { value => "master",         display => "Trunk branch" },
            { value => "releng",         display => "Release branch" }];

    column long_status =>
        type is 'text',
        render_as "Textarea";

    column owner =>
        type is 'text';

    column review_by =>
        type is 'text';

    column to_merge_into =>
        references Smokingit::Model::Branch;
};

sub create {
    my $self = shift;
    my %args = (
        plan_tests => 1,
        sha        => undef,
        @_,
    );

    my $plan_tests = delete $args{plan_tests};

    # Ensure that we have a tip commit
    my $project = Smokingit::Model::Project->new;
    $project->load( $args{project_id} );
    my $tip = $project->sha( delete $args{sha} );
    $args{current_commit_id} = $tip->id;
    $args{tested_commit_id}  = $tip->id;
    $args{first_commit_id}   = $tip->id;
    $args{owner} = $tip->committer;

    my ($ok, $msg) = $self->SUPER::create(%args);
    return ($ok, $msg) unless $ok;

    $self->set_to_merge_into( $self->guess_merge_into )
        unless $self->project->branches->count == 1
            or $self->to_merge_into->id;

    Smokingit->gearman->dispatch_background(
        plan_tests => $self->project->name,
    ) if $plan_tests;

    return ($ok, $msg);
}

sub guess_merge_into {
    my $self = shift;

    my @trunks;
    my $branches = $self->project->trunk_or_relengs;
    while (my $b = $branches->next) {
        push @trunks, [$b->id, $b->current_commit->sha, $b->name];
    }

    # Find the commit before the first non-trunk commit, which is the
    # commit this branch was branched off of
    local $ENV{GIT_DIR} = $self->project->repository_path;
    my $topic = $self->current_commit->sha;
    my @revlist = map {chomp; $_} `git rev-list $topic @{[map {"^".$_->[1]} @trunks]}`;
    my $branchpoint;
    if (@revlist) {
        $branchpoint = `git rev-parse $revlist[-1]~`;
        chomp $branchpoint;
    } else {
        $branchpoint = $topic;
    }

    for my $t (@trunks) {
        # Find the first trunk which contains all the branch point
        # (i.e. branchpoint - trunk is the empty set)
        next if `git rev-list --max-count=1 $branchpoint ^$t->[1]` =~ /\S/;
        return $t->[0];
    }
    return undef;
}

sub branches {
    my $self = shift;
    my $branches = Smokingit::Model::BranchCollection->new;
    return $branches unless $self->status eq "master" or $self->status eq "releng";
    $branches->limit( column => "project_id", value => $self->project->id );
    $branches->limit( column => "status", operator => "!=", value => "ignore", entry_aggregator => "AND");
    $branches->limit( column => "status", operator => "!=", value => "master", entry_aggregator => "AND");
    $branches->limit( column => "to_merge_into", value => $self->id );
    $branches->order_by( column => "name" );
    return $branches;
}

sub set_status {
    my $self = shift;
    my $val = shift;
    my $prev_tested = $self->is_tested;

    my @ret = $self->_set(column =>'status', value => $val);

    if (not $prev_tested and $self->is_tested) {
        # It's no longer ignored; start testing where the tip is now,
        # not where it was when we first found it
        $self->set_tested_commit_id( $self->current_commit->id );
        Smokingit->gearman->dispatch_background(
            plan_tests => $self->project->name,
        );
    }

    return @ret;
}

sub display_status {
    my $self = shift;
    my @options = @{$self->column("status")->valid_values};
    my ($match) = grep {$_->{value} eq $self->status} @options;
    return $match->{display};
}

sub long_status_html {
    my $self = shift;
    my $html = Jifty->web->escape($self->long_status);
    $html =~ s{( {2,})}{"&nbsp;" x length($1)}eg;
    $html =~ s{\n}{<br />}g;
    return $html;
}

sub is_tested {
    my $self = shift;
    return $self->status ne "ignore";
}

sub commit_list {
    my $self = shift;
    local $ENV{GIT_DIR} = $self->project->repository_path;

    my $first = $self->first_commit->sha;
    my $last = $self->current_commit->sha;
    my @revs = map {chomp; $_} `git rev-list ^$first $last --max-count=50`;
    my $left = 50 - @revs; $left = 11 if $left > 11;
    push @revs, map {chomp; $_} `git rev-list $first --max-count=$left`
        if $left > 0;

    my $commits = Smokingit::Model::CommitCollection->new;
    $commits->limit( column => "project_id", value => $self->project->id );
    $commits->limit( column => "sha", operator => "IN", value => \@revs);
    my $results = $commits->join(
        type    => "left",
        alias1  => "main",
        column1 => "id",
        table2  => "smoke_results",
        column2 => "commit_id",
        is_distinct => 1,
    );
    $commits->limit(
        leftjoin => $results,
        column   => "project_id",
        value    => $self->project->id
    );
    $commits->prefetch(
        name => "smoke_results",
        alias => $results,
        class => "Smokingit::Model::SmokeResultCollection",
    );
    my %commits;
    $commits{$_->sha} = $_ while $_ = $commits->next;
    return map $commits{$_} || $self->project->sha($_), @revs;
}

sub branchpoint {
    my $self = shift;
    my $max = shift || 100;
    return undef if $self->status eq "master";
    return undef unless $self->to_merge_into->id;

    my $trunk = $self->to_merge_into->current_commit->sha;
    my $tip   = $self->current_commit->sha;

    local $ENV{GIT_DIR} = $self->project->repository_path;
    my @branch = map {chomp; $_} `git rev-list $tip ^$trunk --max-count=$max`;
    return unless @branch;

    my $commit = $self->project->sha( $branch[-1] );
    return $commit->id ? $commit : undef;
}

sub test_status {
    my $self = shift;
    return $self->current_commit->status;
}

1;

