use strict;
use warnings;

=head1 NAME

Smokingit::Action::Test

=cut

package Smokingit::Action::Test;
use base qw/Smokingit::Action/;

use Jifty::Param::Schema;
use Jifty::Action schema {
    param 'commit' =>
        label is 'Commit to test',
        is mandatory;
};

sub validate_commit {
    my $self = shift;
    my $arg = shift;

    unless ($arg =~ m{^\s*([0-9a-f]+|(?:\S+?:)?\S+?)(?:\s*\[\s*([^\]]+)\s*\])?(?:\s*\{\s*[^\}]+\s*\})?\s*$}i) {
        return $self->validation_error(
            commit => "That doesn't look like a valid ref" );
    }
    my ($ref,$config_text, $branch_text) = ($1, $2, $3);

    my $commit;
    if ($ref =~ /^[0-9a-f]+$/) {
        my $commits = Smokingit::Model::CommitCollection->new;
        $commits->limit( column => "sha", operator => "like", value => "$ref%" );
        return $self->validation_error(
            commit => "Unknown SHA $ref"
        ) if $commits->count == 0;
        return $self->validation_error(
            commit => "Ambiguous SHA (".$commits->count." matches)"
        ) if $commits->count > 1;
        $commit = $commits->first;
    } else {
        my ($project, $branch) = $ref =~ /^\s*(?:(\S+):)?(\S+)\s*$/;
        my $branches = Smokingit::Model::BranchCollection->new;
        $branches->limit( column => "name", value => "$branch" );

        if ($project) {
            my $project_obj = Smokingit::Model::Project->new;
            $project_obj->load_by_cols( name => $project );
            return $self-> validation_error(
                commit => "No such project $project"
            ) unless $project_obj->id;
            $branches->limit( column => "project_id", value => $project_obj->id );
        }

        return $self->validation_error(
            commit => "No branch $branch found",
        ) if $branches->count == 0;
        return $self->validation_error(
            commit => "Ambiguous branch (".$branches->count." matches)"
        ) if $branches->count > 1;

        $commit = $branches->first->current_commit;
        $branch_text ||= $branches->first->name;
    }


    my $sha = $commit->sha;

    if (not $config_text) {
        # We'll do all of them
    } elsif ($config_text =~ /^\d+$/) {
        my $config = Smokingit::Model::Configuration->new;
        $config->load( $config_text );
        return $self->validation_error( commit => "Invalid configuration id" )
            unless $config->id and $config->project->id == $commit->project->id;
    } else {
        my $configs = $commit->project->configurations;
        $configs->limit( column => "name", operator => "MATCHES", value => $config_text );
        return $self->validation_error( commit => "Invalid configuration name" )
            unless $configs->count == 1;
        $config_text = $configs->first->id;
    }

    my $existing = Smokingit::Model::SmokeResultCollection->new;
    $existing->limit(
        column => "project_id",
        value  => $commit->project->id
    );
    $existing->limit(
        column => "commit_id",
        value => $commit->id
    );
    $existing->limit(
        column => "configuration_id",
        value => $config_text
    ) if $config_text;

    if ($existing->count) {
        # Re-testing the existing smokes
        undef $branch_text;
    } else {
        my @branches = $commit->branches;
        if ($branch_text) {
            if ($branch_text =~ /^\d+$/) {
                my $branch = Smokingit::Model::Branch->new;
                $branch->load($branch_text);
                return $self->validation_error( commit => "Invalid branch id" )
                    unless $branch->id;
                $branch_text = $branch->name;
            }
            return $self->validation_error( commit => "Invalid branch name" )
                unless grep {$_ eq $branch_text} @branches;
        } elsif (@branches == 1) {
            $branch_text = $branches[0];
        } else {
            return $self->validation_error( commit => "Can't determine which branch to test on" );
        }
    }

    $sha .= "[$config_text]" if $config_text;
    $sha .= "{$branch_text}" if $branch_text;
    $self->argument_value( commit => $sha );
    return $self->validation_ok( "commit" );
}

sub take_action {
    my $self = shift;

    my $arg = $self->argument_value("commit");
    my ($sha, $config, $branchname) =
        $arg =~ /^([0-9a-fA-F]+)(?:\[(\d+)\])?(?:\{(.*)\})?$/;

    my $commit = Smokingit::Model::Commit->new;
    $commit->load_by_cols( sha => $sha );

    if ($branchname) {
        # Testing new commits
        my $branch = Smokingit::Model::Branch->new;
        $branch->load_by_cols( name => $branchname, project_id => $commit->project->id);

        my $configs = $commit->project->configurations;
        if ($config) {
            $configs->limit( column => "id", value => $config );
        } else {
            $configs->limit( column => "auto", value => 1 );
        }

        while (my $config = $configs->next) {
            $commit->run_smoke( $config, $branch );
        }
        $self->result->message(
            "Testing "
              . $configs->count
              . " configurations of "
              . $commit->short_sha
          );
    } else {
        # Re-testing old commits
        my $existing = Smokingit::Model::SmokeResultCollection->new;
        $existing->limit(
            column => "project_id",
            value  => $commit->project->id,
        );
        $existing->limit(
            column => "commit_id",
            value => $commit->id,
        );
        $existing->limit(
            column => "queue_status",
            operator => "IS",
            value => "NULL",
        );
        $existing->limit(
            column => "configuration_id",
            value => $config,
        ) if $config;
        $existing->order_by( column => 'queued_at' );

        while (my $smoke = $existing->next) {
            $smoke->as_superuser->set_submitted_at(undef);
            $smoke->as_superuser->set_queue_status(undef);
            $smoke->run_smoke;
        }

        if ($existing->count == 0) {
            $self->result->message("Commits already queued for testing");
        } else {
            $self->result->message(
                "Retesting "
                  . $existing->count
                  . " configurations of "
                  . $commit->short_sha
              );
        }

    }
}

1;
