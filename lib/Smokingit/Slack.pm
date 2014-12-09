use strict;
use warnings;

package Smokingit::Slack;
use AnyEvent::WebSocket::Client;
use AnyEvent::HTTP;
use LWP::UserAgent;
use JSON;

use Moose;

has 'name' => (
    is      => 'rw',
    isa     => 'Str',
);
has 'slack_properties' => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
);

has 'connection' => (
    is      => 'rw',
    isa     => 'Maybe[AnyEvent::WebSocket::Connection]',
);

has 'next_id' => (
    is      => 'rw',
    isa     => 'Int',
    default => 1,
);
sub get_id {
    my $self = shift;
    my $id = $self->next_id;
    $self->next_id( $id + 1 );
    return $id;
}
has 'pending_reply' => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
);

has 'ping'      => ( is => 'rw', );
has 'reconnect' => ( is => 'rw', );


sub run {
    my $self = shift;

    my $token = Jifty->config->app('slack')->{token};
    $self->reconnect(undef);

    # XXX use AnyEvent::HTTP
    http_request GET => "https://slack.com/api/rtm.start?token=" . $token,
        headers => {"user-agent" => "smokingit/$Smokingit::VERSION"},
        timeout => 30,
        sub {
            my ($body, $hdr) = @_;
            die "Slack API request failed: ".$hdr->{Reason} . "\n" . $body
                unless $hdr->{Status} =~ /^2/;

            my $data = eval { decode_json( $body ) };
            die "Failed to decode API response: $body"
                unless $data;

            die "API response failed: $body"
                unless $data->{ok};

            $self->name( $data->{self}{name} );
            $self->slack_properties( $data->{self} );

            my $client = AnyEvent::WebSocket::Client->new;
            Jifty->log->info( "Connecting to ".$data->{url} );
            $client->connect( $data->{url} )->cb( sub {
                # This will die if the connection attempt fails
                $self->connection( eval { shift->recv } );
                if ($@) {
                    Jifty->log->warn("Failed to connect to websocket: $@; retrying in 5s");
                    $self->reconnect( AE::timer( 5, 0, sub { $self->run } ) );
                }

                my $sub = Jifty->bus->new_listener;
                $sub->subscribe(Jifty->bus->topic("test_result"));
                $sub->poll( sub { $self->test_progress(@_) } );

                $self->connection->on( each_message => sub {$self->each_message(@_)});
                $self->connection->on( finish       => sub {$self->finish(@_)});

                $self->heartbeat;
            } );
        };
}

sub send {
    my $self = shift;
    my (%msg) = @_;

    $msg{id} = $self->get_id;

    my $done = AnyEvent->condvar;
    $self->pending_reply->{$msg{id}} = $done;

    Jifty->log->debug( "Sending: ".encode_json(\%msg) );

    $self->connection->send( AnyEvent::WebSocket::Message->new(
        body => encode_json( \%msg )
    ) );

    unless (defined wantarray) {
        $done->cb( sub {
            my ($body) = $_[0]->recv;
            Jifty->log->warn( "$msg{type} $msg{id} failed: ".encode_json($body->{error}) )
                unless $body->{ok};
        });
    }
    return $done;
}

sub send_to {
    my $self = shift;
    my ($channel, $msg) = @_;
    $msg =~ s/&/&amp;/g;
    $msg =~ s/</&lt;/g;
    $msg =~ s/>/&gt;/g;
    $self->send( type => "message", channel => $channel, text => $msg );
}

sub heartbeat {
    my $self = shift;

    $self->ping( AE::timer( 10, 10, sub {
        $self->send( type => "ping", ok => 1 );
    } ) );
}

sub each_message {
    my $self = shift;
    my ($c, $m) = @_;

    Jifty::Record->flush_cache if Jifty::Record->can('flush_cache');

    if ($m->is_close) {
        Jifty->log->warn("Websocket closed by remote server");
    } elsif ($m->is_text) {
        my $body = eval { decode_json($m->body) };
        if ($@) {
            Jifty->log->warn("Failed to decode body: ". $m->body);
            return;
        }

        return unless $self->connection;
        $self->heartbeat;

        Jifty->log->debug( "Got: ".encode_json($body) );
        if ($body->{reply_to}) {
            my $call = delete $self->pending_reply->{$body->{reply_to}};
            $call->send( $body ) if $call;
        } else {
            my $call = $self->can( "recv_" . $body->{type} );
            $call->( $self, $body ) if $call;
        }
    }
}

sub finish {
    my $self = shift;

    $self->connection( undef );
    $self->ping( undef );

    Jifty->log->warn( "Disconnected from websocket; reconnecting in 5s..." );
    $self->reconnect( AE::timer( 5, 0, sub { $self->run } ) );
}

sub recv_message {
    my $self = shift;

    my ($body) = @_;
    return if $body->{hidden};

    my $nick = $self->name;

    my $msg = $body->{text};
    return if $body->{channel} =~ /^C/
        and not $msg =~ s/^\s*$nick(?:\s*[:,])?\s*(?:please\s+)?//i;

    if ($msg =~ /^(?:re)?test\s+(.*)/) {
        return $self->do_test($body->{channel}, $1);
    } elsif ($msg =~ /^status\s+(?:of\s+)?(.*)/) {
        return $self->do_status($body->{channel}, $1);
    } elsif ($msg =~ /^(?:re)?sync(?:\s+(.*))?/) {
        return $self->do_sync($body->{channel}, $1);
    } elsif ($msg =~ /^queued?(?:\s+(.*))?/) {
        return $self->do_queued($body->{channel}, $1);
    } else {
        $self->send_to( $body->{channel} => "What?" );
    }
}

sub do_test {
    my $self = shift;
    my ($channel, $what) = @_;
    my $action = Smokingit::Action::Test->new(
        current_user => Smokingit::CurrentUser->superuser,
        arguments    => { commit => $what },
    );
    $action->validate;
    return $self->send_to(
        $channel => $action->result->field_error("commit"),
    ) unless $action->result->success;

    $action->run;
    return $self->send_to(
        $channel => $action->result->error,
    ) if $action->result->error;

    return $self->send_to(
        $channel => $action->result->message
    );
}

sub do_status {
    my $self     = shift;
    my $channel  = shift;
    my $what = $self->lookup_commitish($channel, @_) or return;

    my $msg = $what->short_sha . " is " . $what->status;
    $msg = $what->short_sha . " is " . $self->describe_fail($what)
        if $what->status eq "failing";

    $msg .= "; " . $self->queue_status($what)
        if $what->status eq "queued";

    $msg .= " - " .  Jifty->web->url(path => "/test/".$what->short_sha);

    $self->send_to( $channel => $msg );
}

sub lookup_commitish {
    my $self = shift;
    my ($channel, $what) = @_;
    if ($what =~ s/^\s*([a-fA-F0-9]{5,})\s*$/lc $1/e) {
        my $commits = Smokingit::Model::CommitCollection->new;
        $commits->limit( column => "sha", operator => "like", value => "$what%" );
        my @matches = @{ $commits->items_array_ref };
        if (not @matches) {
            $self->send_to(
                $channel => "No such SHA!"
            );
            return;
        } elsif (@matches > 1) {
            $self->send_to(
                $channel => "Found ".(@matches+0)." matching SHAs!",
            );
            return;
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
                $self->send_to(
                    $channel => "No such project $project!",
                );
                return;
            }
            $branches->limit( column => "project_id", value => $project_obj->id );
        }

        my @matches = @{ $branches->items_array_ref };
        if (not @matches) {
            $self->send_to(
                $channel => "No branch $branch found",
            );
            return;
        } elsif (@matches > 1) {
            @matches = map {$_->project->name} @matches;
            $self->send_to(
                $channel => "Found $branch in ".
                    join(", ", @matches).
                    ".  Try, $matches[0]:$branch"
            );
            return;
        }

        # Need to re-parse if this got any updates
        return $self->lookup_commitish($channel, $what)
            if $matches[0]->as_superuser->sync;

        return $matches[0]->current_commit;
    }
}

sub do_sync {
    my $self = shift;
    my ($channel, $what) = @_;

    if (defined $what and $what =~ /^\s*(.*?)\s*$/) {
        $what = $1;
        my $project = Smokingit::Model::Project->new;
        $project->load_by_cols( name => $what );
        if (not $project->id) {
            $self->send_to( $channel => "No such project $what!" );
        } else {
            my @results = $project->as_superuser->sync;
            if (@results) {
                $self->send_to( $channel => join("; ", @results));
            } else {
                $self->send_to( $channel => "No changes" );
            }
        }
    } else {
        my $projects = Smokingit::Model::ProjectCollection->new;
        $projects->unlimit;
        while (my $p = $projects->next) {
            $p->as_superuser->sync;
        }
        $self->send_to(
            $channel => "Synchronized ".$projects->count." projects"
        );
    }
}

sub do_queued {
    my $self = shift;
    my ($channel, $what) = @_;

    if ($what) {
        $what = $self->lookup_commitish($channel, $what) or return;
    }

    my $queued = Smokingit::Model::SmokeResultCollection->queued;
    my $count  = $queued->count;
    my $msg    = "$count test". ($count == 1 ? "" : "s") ." queued";

    $msg .= join(" ", ";", $what->short_sha, $self->queue_status($what, $queued))
        if $what;

    $self->send_to( $channel => $msg );
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

        $self->send_to( Jifty->config->app('slack')->{channel} => $message );
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
    for my $result (@{ $commit->smoke_results->items_array_ref }) {
        my $config = $result->configuration;
        $tested_configs{$config->id}++;

        my $short = $result->short_error;
        next unless $short;
        $short =~ s/^Configuration failed/configuration/;
        $testnames{$short}{$config->name} = 1;
    }
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
            $status = "passes tests";
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
            my $url = Jifty->web->url(path => "/test/".$commit->short_sha);
            $status .= " - $url";
        }
        return $smoke->configuration->name . " of ".$commit->short_sha . " on ".$smoke->branch_name
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
            return "New branch $branchname passes tests";
        } else {
            return "$author pushed a new branch $branchname which is " .
              "$commit - $url";
        }
    } elsif ($commit->is_merge){
        my $mergename = $commit->is_merge;
        if ($commit->status eq "passing") {
            return "Merged $mergename into $branchname, passes tests";
        }

        # So the merge commit is fail: there are four possibilities,
        # based on which of trunk/branch were passing previous to the
        # commit.  We assume here that there are no octopus commits.
        my ($trunk_commit, $branch_commit) = $commit->parents;
        my $trunk_good  = $trunk_commit->status eq "passing";
        my $branch_good = $branch_commit->status eq "passing";

        if ($trunk_good and $branch_good) {
            return "$author merged $mergename into $branchname, which is $commit" .
                ", although both parents were passing - $url";
        } elsif ($trunk_good and not $branch_good) {
            return "$author merged $mergename (".
              $self->describe_fail($branch_commit).
              ") into $branchname, which is now ".
              $self->describe_fail($commit) . " - $url";
        } elsif (not $trunk_good and not $branch_good) {
            return "$author merged $mergename (".
              $self->describe_fail($branch_commit).
              ") into $branchname, which is still ".
              $self->describe_fail($commit) . " - $url";
        } else {
            return "$author merged $mergename".
              " into $branchname, which is still ".
              $self->describe_fail($commit) . " - $url";
        }
    } elsif ($commit->status ne "passing") {
        # A new commit on an existing branch, which fails tests.  Let's
        # check if this is better or worse than the previous commit.
        if (@tested_parents == grep {$_->status eq "passing"} @tested_parents) {
            return "$branchname by $author began ".
                $self->describe_fail($commit) .
                " as of ".$commit->short_sha. " - $url";
        } else {
            # Was failing, still failing?  Let's not spam about it
            return;
        }
    } elsif (grep {$_->status ne "passing"} @tested_parents) {
        # A new commit on an existing branch, which passes tests but
        # whose parents didn't!
        return "$branchname by $author now passes tests".
            " as of ".$commit->short_sha;
    } else {
        # A commit which passes, and whose parents all passed.  Go them?
        return;
    }
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;
