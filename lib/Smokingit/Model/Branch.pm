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

    column last_status_update =>
        references Smokingit::Model::Commit;

    column status =>
        type is 'text',
        is mandatory,
        valid_values are qw(ignore hacking needs-tests needs-review awaiting-merge merged master releng);

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
    my $tip = Smokingit::Model::Commit->new;
    $tip->load_or_create( project_id => $args{project_id}, sha => delete $args{sha} );
    $args{current_commit_id} = $tip->id;
    $args{first_commit_id} = $tip->id;
    $args{owner} = $tip->committer;

    my ($ok, $msg) = $self->SUPER::create(%args);
    unless ($ok) {
        Jifty->handle->rollback;
        return ($ok, $msg);
    }

    # For the tip, add skips for all configurations
    warn "Current head @{[$self->name]} is @{[$self->current_commit->short_sha]}\n";
    my $configs = $self->project->configurations;
    while (my $config = $configs->next) {
        my $head = Smokingit::Model::TestedHead->new;
        $head->load_or_create(
            project_id       => $self->project->id,
            configuration_id => $config->id,
            commit_id        => $tip->id,
        );
    }

    return ($ok, $msg);
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

