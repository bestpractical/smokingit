use strict;
use warnings;

package Smokingit::IRC;
use String::IRC;

use Moose;
extends 'IM::Engine';

has '+interface_args' => (
    required => 0,
    default  => sub {
        my %config = %{ Jifty->config->app('irc') || {} };
        return {
            protocol => 'IRC',
            credentials => {
                server   => $config{host},
                port     => $config{port},
                nick     => $config{nick} || 'anna',
                channels => [$config{channel}],
            },
        };
    },
);

sub BUILD {
    my $self = shift;

    $self->interface->incoming_callback(
        sub { $self->incoming(@_) },
    );

    $self->interface->irc->reg_cb(
        registered => sub {
            my $sub = Jifty->bus->new_listener;
            $sub->subscribe(Jifty->bus->topic("test_result"));
            $sub->poll( sub { $self->test_progress(@_) } );
        },
    );
}

sub error_reply {
    my($incoming, $msg) = @_;
    return $incoming->reply(
        String::IRC->new( $msg )->maroon->stringify,
    );
}

sub incoming {
    my $self = shift;
    my $incoming = shift;
    Jifty::Record->flush_cache if Jifty::Record->can('flush_cache');

    # Skip messages from the system
    if ($incoming->sender->name =~ /\./) {
        warn $incoming->sender->name . ": " .
            $incoming->message;
        return;
    } elsif ($incoming->command eq "NOTICE") {
        # NOTICE's are required to never trigger auto-replies
        return;
    }

    my $msg = $incoming->message;
    my $nick = $self->interface->irc->nick;
    return if $incoming->isa("IM::Engine::Incoming::IRC::Channel")
        and not $msg =~ s/^\s*$nick(?:\s*[:,])?\s*(?:please\s+)?//i;

    if ($msg =~ /^retest\s+(.*)/) {
        return $self->do_retest($incoming, $1);
    } elsif ($msg =~ /^status\s+(?:of\s+)?(.*)/) {
        return $self->do_status($incoming, $1);
    } elsif ($msg =~ /^(?:re)?sync(?:\s+(.*))?/) {
        return $self->do_sync($incoming, $1);
    } else {
        return $incoming->reply( "What?" );
    }
}

sub do_retest {
    my $self = shift;
    my ($incoming, $what) = @_;
    my $action = Smokingit::Action::Test->new(
        current_user => Smokingit::CurrentUser->superuser,
        arguments    => { commit => $what },
    );
    $action->validate;
    return error_reply(
        $incoming => $action->result->field_error("commit"),
    ) unless $action->result->success;

    $action->run;
    return error_reply(
        $incoming => $action->result->error,
    ) if $action->result->error;

    return $incoming->reply( $action->result->message );
}

sub do_status {
    my $self = shift;
    my ($incoming, $what) = @_;
    if ($what =~ /^\s*([a-fA-F0-9]{5,})\s*$/) {
        my $commits = Smokingit::Model::CommitCollection->new;
        $commits->limit( column => "sha", operator => "like", value => "$what%" );
        my @matches = @{ $commits->items_array_ref };
        if (not @matches) {
            return error_reply(
                $incoming => "No such SHA!"
            );
        } elsif (@matches > 0) {
            return error_reply(
                $incoming => "Found ".(@matches+0)." matching SHAs!",
            );
        }

        $what = $matches[0];
    } else {
        my ($project, $branch) = $what =~ /^\s*(?:(\S+):)?(\S+)\s*$/;
        my $branches = Smokingit::Model::BranchCollection->new;
        $branches->limit( column => "name", value => "$branch" );

        if ($project) {
            my $project_obj = Smokingit::Model::Project->new;
            $project_obj->load_by_cols( name => $project );
            if (not $project_obj->id) {
                return error_reply(
                    $incoming => "No such project $project!",
                );
            }
            $branches->limit( column => "project_id", value => $project_obj->id );
        }

        my @matches = @{ $branches->items_array_ref };
        if (not @matches) {
            return error_reply(
                $incoming => "No branch $branch found",
            );
        } elsif (@matches > 1) {
            return error_reply(
                $incoming => "Found $branch in ".
                    join(", ", map {$_->project->name} @matches).
                    ".  Try, $matches[0]:$branch"
            );
        }

        # Need to re-parse if this got any updates
        return $self->do_status($incoming, $what)
            if $matches[0]->project->as_superuser->sync;

        $what = $matches[0]->current_commit;
    }
    return $incoming->reply( $what->short_sha . " is " . $what->status );
}

sub do_sync {
    my $self = shift;
    my ($incoming, $what) = @_;

    if ($what) {
        my $project = Smokingit::Model::Project->new;
        $project->load_by_cols( name => $what );
        if (not $project->id) {
            return error_reply(
                $incoming => "No such project $what!",
            );
        }
        my @results = $project->sync;
        return $incoming->reply("No changes") unless @results;
        return $incoming->reply(join("; ", @results));
    } else {
        my $projects = Smokingit::Model::ProjectCollection->new;
        $projects->unlimit;
        while (my $p = $projects->next) {
            $p->sync;
        }
        return $incoming->reply("Synchronized ".$projects->count." projects");
    }
}

sub test_progress {
    my $self = shift;
    my $msg = shift;
    Jifty::Record->flush_cache if Jifty::Record->can('flush_cache');

    eval {
        my %message = %{ $msg };

        my $smoke = Smokingit::Model::SmokeResult->new;
        $smoke->load( $message{smoke_id} );
        return unless $smoke->id;

        my $message = $self->do_analyze($smoke);
        return unless $message;

        my $out = IM::Engine::Outgoing::IRC::Channel->new(
            channel => Jifty->config->app('irc')->{channel},
            message => $message,
            command => "NOTICE",
        );
        $self->interface->send_message($out);
    };
    warn "$@" if $@;
}

sub do_analyze {
    my $self = shift;
    my ($smoke) = @_;

    my $commit = $smoke->commit;
    my $project = $smoke->project;

    warn "Got test result for ".$commit->short_sha;

    # First off, have we tested all configurations?
    return unless $commit->smoke_results->count == $project->configurations->count;

    warn "Have tested all configs";

    # See if we can find the branch for this commit
    my $branch = Smokingit::Model::Branch->new;
    $branch->load_by_cols(
        project_id => $project->id,
        name       => $smoke->branch_name,
    );
    my $branchname = $branch->name;
    return unless $branch->id;

    # Make sure the branch actually still contains the commit
    return unless $branch->contains($commit);

    my $author = $commit->author;
    $author = $1 if $author =~ /<(.*?)@/;

    # If this is the first commit on the branch, _or_ we haven't tested
    # some configuration of each parent of this commit, then this is
    # first news we have of the branch.
    my @tested_parents = grep {$_->smoke_results->count} $commit->parents;
    if (($branch->first_commit and $commit->sha eq $branch->first_commit->sha)
            or not @tested_parents) {
        if ($commit->status eq "passing") {
            return "New branch $branchname " .
              String::IRC->new("passes tests")->green;
        } else {
            return "$author pushed a new branch $branchname which is " .
              String::IRC->new("failing tests")->red;
        }
    } elsif ($commit->is_merge){
        my $mergename = $commit->is_merge;
        if ($commit->status eq "passing") {
            return "Merged $mergename into $branchname, " .
              String::IRC->new("passes tests")->green;
        }

        # So the merge commit is fail: there are four possibilities,
        # based on which of trunk/branch were passing previous to the
        # commit.  We assume here that there are no octopus commits.
        my ($trunk_commit, $branch_commit) = $commit->parents;
        my $trunk_good  = $trunk_commit->status eq "passing";
        my $branch_good = $branch_commit->status eq "passing";

        if ($trunk_good and $branch_good) {
            return "$author merged $mergename into $branchname, which is " .
                String::IRC->new("failing tests")->red .
                ", although both parents were passing";
        } elsif ($trunk_good and not $branch_good) {
            return "$author merged $mergename (".
              String::IRC->new("failing tests")->red.
              ") into $branchname, which is now ".
              String::IRC->new("failing tests")->red;
        } elsif (not $trunk_good and not $branch_good) {
            return "$author merged $mergename (".
              String::IRC->new("failing tests")->red.
              ") into $branchname, which is still ".
              String::IRC->new("failing tests")->red;
        } else {
            return "$author merged $mergename".
              " into $branchname, which is still ".
              String::IRC->new("failing tests")->red;
        }
    } elsif ($commit->status ne "passing") {
        # A new commit on an existing branch, which fails tests.  Let's
        # check if this is better or worse than the previous commit.
        if (@tested_parents == grep {$_->status eq "passing"} @tested_parents) {
            return "$branchname by $author began ".
                String::IRC->new("failing tests")->red .
                " as of ".$commit->short_sha;
        } else {
            # Was failing, still failing?  Let's not spam about it
            return;
        }
    } elsif (grep {$_->status ne "passing"} @tested_parents) {
        # A new commit on an existing branch, which passes tests but
        # whose parents didn't!
        return "$branchname by $author ".
            String::IRC->new("passes tests")->green .
            " as of ".$commit->short_sha;
    } else {
        # A commit which passes, and whose parents all passed.  Go them?
        return;
    }
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
