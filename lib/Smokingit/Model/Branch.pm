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
        sha => undef,
        @_,
    );

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

    Smokingit->gearman->dispatch_background(
        plan_tests => $self->project->name,
    );

    return ($ok, $msg);
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
    my @revs = map {chomp; $_} `git rev-list ^$first $last`;
    push @revs, map {chomp; $_} `git rev-list $first --max-count=11`;

    return map {$self->project->sha($_)} @revs;
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

1;

