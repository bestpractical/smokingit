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

            my $out = IM::Engine::Outgoing::IRC::Channel->new(
                channel => Jifty->config->app('irc')->{channel},
                message => "I'm going to ban so hard",
                command => "NOTICE",
            );
            $self->interface->send_message($out);
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
    $msg =~ s/\s*$//;
    my $nick = $self->interface->irc->nick;
    return if $incoming->isa("IM::Engine::Incoming::IRC::Channel")
        and not $msg =~ s/^\s*$nick(?:\s*[:,])?\s*(?:please\s+)?//i;

    if ($msg =~ /^retest\s+(.*)/) {
        return $self->do_retest($incoming, $1);
    } elsif ($msg =~ /^status\s+(?:of\s+)?(.*)/) {
        return $self->do_status($incoming, $1);
    } elsif ($msg =~ /^(?:re)?sync(?:\s+(.*))?/) {
        return $self->do_sync($incoming, $1);
    } elsif ($msg =~ /^queued?(?:\s+(.*))?/) {
        return $self->do_queued($incoming, $1);
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
    my $self     = shift;
    my $incoming = shift;
    my $what     = $self->lookup_commitish($incoming, @_);
    if ($what->isa("Smokingit::Model::Commit")) {
        my $msg = $what->short_sha . " is " . $what->status;
        $msg = $what->short_sha . " is " . $self->describe_fail($what)
            if $what->status eq "failing";

        $msg .= "; " . $self->queue_status($what)
            if $what->status eq "queued";

        $msg .= " - " .  Jifty->web->url(path => "/test/".$what->short_sha);

        return $incoming->reply( $msg );
    } else {
        return $what;
    }
}

sub lookup_commitish {
    my $self = shift;
    my ($incoming, $what) = @_;
    if ($what =~ s/^\s*([a-fA-F0-9]{5,})\s*$/lc $1/e) {
        my $commits = Smokingit::Model::CommitCollection->new;
        $commits->limit( column => "sha", operator => "like", value => "$what%" );
        my @matches = @{ $commits->items_array_ref };
        if (not @matches) {
            return error_reply(
                $incoming => "No such SHA!"
            );
        } elsif (@matches > 1) {
            return error_reply(
                $incoming => "Found ".(@matches+0)." matching SHAs!",
            );
        }

        return $matches[0];
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
            @matches = map {$_->project->name} @matches;
            return error_reply(
                $incoming => "Found $branch in ".
                    join(", ", @matches).
                    ".  Try, $matches[0]:$branch"
            );
        }

        # Need to re-parse if this got any updates
        return $self->lookup_commitish($incoming, $what)
            if $matches[0]->as_superuser->sync;

        return $matches[0]->current_commit;
    }
}

sub do_sync {
    my $self = shift;
    my ($incoming, $what) = @_;

    if (defined $what and $what =~ /^\s*(.*?)\s*$/) {
        $what = $1;
        my $project = Smokingit::Model::Project->new;
        $project->load_by_cols( name => $what );
        if (not $project->id) {
            return error_reply(
                $incoming => "No such project $what!",
            );
        }
        my @results = $project->as_superuser->sync;
        return $incoming->reply("No changes") unless @results;
        return $incoming->reply(join("; ", @results));
    } else {
        my $projects = Smokingit::Model::ProjectCollection->new;
        $projects->unlimit;
        while (my $p = $projects->next) {
            $p->as_superuser->sync;
        }
        return $incoming->reply("Synchronized ".$projects->count." projects");
    }
}

sub do_queued {
    my $self = shift;
    my ($incoming, $what) = @_;

    if ($what) {
        $what = $self->lookup_commitish($incoming, $what);
        return $what unless $what->isa("Smokingit::Model::Commit");
    }

    my $queued = Smokingit::Model::SmokeResultCollection->queued;
    my $count  = $queued->count;
    my $msg    = "$count test". ($count == 1 ? "" : "s") ." queued";

    $msg .= join(" ", ";", $what->short_sha, $self->queue_status($what, $queued))
        if $what;

    return $incoming->reply($msg);
}

sub queue_status {
    my ($self, $commit, $queued) = @_;
    $queued ||= Smokingit::Model::SmokeResultCollection->queued;

    my ($before, $found) = (0, undef);
    while (my $test = $queued->next) {
        $found = 1, last if $test->commit->sha eq $commit->sha;
        $before++;
    }

    if ($found) {
        if ($before == 0) {
            return "first in line";
        } elsif ($before == 1) {
            return "up next";
        } else {
            return "behind $before test".($before == 1 ? "" : "s");
        }
    } else {
        return "not queued!";
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


sub enum {
    my ($sep, @lst) = @_;
    $lst[-1] = "and $lst[-1]" if @lst > 1;
    return join("$sep ", @lst);
}

sub describe_fail {
    my $self = shift;

    my ($commit) = @_;

    my $fails = Smokingit::Model::SmokeFileResultCollection->new;
    my $results = $fails->join(
        alias1  => "main",
        column1 => "smoke_result_id",
        table2  => "smoke_results",
        column2 => "id",
        is_distinct => 1,
    );
    $fails->limit(
        alias => $results,
        column => "commit_id",
        value  => $commit->id,
    );
    $fails->limit(
        column => "is_ok",
        value  => 0,
    );
    $fails->prefetch( name => "smoke_result" );

    my %testnames;
    my %configs;
    while (my $fail = $fails->next) {
        my $config = $fail->smoke_result->configuration->name;
        $testnames{$fail->filename}{$config} = 1;
        $configs{$config}{$fail->filename} = 1;
    }

    # Are all of the fails across all configurations?
    my %tested_configs;
    $tested_configs{$_->configuration->id}++ for @{ $commit->smoke_results->items_array_ref };
    my $config_count = keys %tested_configs;
    if (scalar values %testnames == grep {keys(%{$_}) == $config_count} values %testnames) {
        return "failing ".enum(",", sort keys %testnames);
    }

    # Are all of the fails in just one configuration?
    if (scalar keys %configs == 1) {
        return "failing @{[keys %configs]} tests: ".enum(",", sort keys %testnames);
    }

    # Something else; pull out all of the ones which apply to all
    # configs first, then go through the remaining ones
    my @all = sort grep {keys(%{$testnames{$_}}) == $config_count} keys %testnames;
    for my $c (keys %configs) {
        delete $configs{$c}{$_} for @all;
    }
    my @ret;
    push @ret, enum(",", @all)." on all" if @all;

    for my $config (sort grep {keys %{$configs{$_}}} keys %configs) {
        push @ret, enum(",", sort keys %{delete $configs{$config}})." on $config";
    }

    return "failing " . enum(";", @ret);
}

sub do_analyze {
    my $self = shift;
    my ($smoke) = @_;

    my $commit = $smoke->commit;
    my $project = $smoke->project;

    my $author = $commit->author;
    $author = $1 if $author =~ /<(.*?)@/;

    # If this is an on-demand configuration, report it
    if (not $smoke->configuration->auto) {
        my ($status) = $commit->status($smoke);
        if ($status eq "passing") {
            $status = String::IRC->new("passes tests")->green;
        } else {
            my $fails = Smokingit::Model::SmokeFileResultCollection->new;
            $fails->limit(
                column => "smoke_result_id",
                value  => $smoke->id,
            );
            $fails->limit(
                column => "is_ok",
                value  => 0,
            );
            $status = "is failing " . enum(", ", sort map {$_->filename} @{$fails->items_array_ref});
            $status = String::IRC->new($status)->red . " - $url");
        }
        my $url = Jifty->web->url(path => "/test/".$commit->short_sha);
        return $smoke->configuration->name " of ".$commit->short_sha . " on ".$smoke->branch_name
            ." $status";
    }

    # First off, have we tested all configurations?
    return unless $commit->is_fully_smoked;

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

    my $url = Jifty->web->url(path => "/test/".$commit->short_sha);

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
              String::IRC->new($self->describe_fail($commit))->red . " - $url";
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
                String::IRC->new($self->describe_fail($commit))->red .
                ", although both parents were passing - $url";
        } elsif ($trunk_good and not $branch_good) {
            return "$author merged $mergename (".
              String::IRC->new($self->describe_fail($commit))->red.
              ") into $branchname, which is now ".
              String::IRC->new($self->describe_fail($commit))->red . " - $url";
        } elsif (not $trunk_good and not $branch_good) {
            return "$author merged $mergename (".
              String::IRC->new($self->describe_fail($commit))->red.
              ") into $branchname, which is still ".
              String::IRC->new($self->describe_fail($commit))->red . " - $url";
        } else {
            return "$author merged $mergename".
              " into $branchname, which is still ".
              String::IRC->new($self->describe_fail($commit))->red . " - $url";
        }
    } elsif ($commit->status ne "passing") {
        # A new commit on an existing branch, which fails tests.  Let's
        # check if this is better or worse than the previous commit.
        if (@tested_parents == grep {$_->status eq "passing"} @tested_parents) {
            return "$branchname by $author began ".
                String::IRC->new($self->describe_fail($commit))->red .
                " as of ".$commit->short_sha. " - $url";
        } else {
            # Was failing, still failing?  Let's not spam about it
            return;
        }
    } elsif (grep {$_->status ne "passing"} @tested_parents) {
        # A new commit on an existing branch, which passes tests but
        # whose parents didn't!
        return "$branchname by $author now ".
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
