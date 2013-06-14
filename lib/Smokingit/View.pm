use strict;
use warnings;

package Smokingit::View;
use Jifty::View::Declare -base;

require Smokingit::View::Project;
alias Smokingit::View::Project under '/';

require Smokingit::View::Branch;
alias Smokingit::View::Branch under '/';

require Smokingit::View::Configuration;
alias Smokingit::View::Configuration under '/';

require Smokingit::View::Commit;
alias Smokingit::View::Commit under '/';

require Smokingit::View::GitHub;
alias Smokingit::View::GitHub under '/';


template '/index.html' => page {
    page_title is 'Projects';

    div {
        id is "project-list";
        my $projects = Smokingit::Model::ProjectCollection->new;
        $projects->unlimit;
        if ($projects->count) {
            h2 { "Existing projects" };
            ul {
                while (my $p = $projects->next) {
                    li {
                        hyperlink(
                            label => $p->name,
                            url => "/project/".$p->name."/",
                        );
                    }
                }
            };
        }
    };

    div {
        id is "right-bar";
        render_region(
            name => "planned",
            path => "/fragments/planned",
        );
    };

    my $project = Smokingit::Model::Project->new;
    return unless $project->current_user_can("create");

    div {
        { id is "create-project"; };
        h2 { "Add a project" };
        form {
            my $create = new_action(
                class => "CreateProject",
                moniker => "create-project",
            );
            render_param( $create => 'name' );
            render_param( $create => 'repository_url' );
            form_submit( label => _("Create") );
        };
    };
};

template '/fragments/planned' => sub {
    my $planned = Smokingit::Model::SmokeResultCollection->queued;
    div {
        id is "all-planned-tests";
        h2 { "Planned tests" };
        span {
            class is "commitlist";
            while (my $test = $planned->next) {
                test_result($test, show_project => 1);
            }
        };
    };
    Jifty->subs->update_on( topic => "test_queued" );
    Jifty->subs->update_on( topic => "test_result" );
};

sub test_result {
    my $test = shift;
    my %opts = ( show_project => 0, @_ );
    my ($status, $msg, $in) = $test->commit->status($test);
    div {
        class is $test->commit->sha." config-".$test->configuration->id." commit $status";
        if ($status =~ /^(untested|queued|testing|broken)$/) {
            span {
                attr { class => "spacer" };
                outs_raw("&nbsp;")
            } if Jifty->web->current_user->id;
            span {
                attr { class => "okbox $status config-".$test->configuration->id, title => $msg };
                outs_raw($in || "&nbsp;")
            };
            span {
                attr { class => "sha", title => $msg };
                $test->commit->short_sha
            };
        } else {
            span {
                { class is "retestme" };
                my $sha = $test->commit->sha;
                my $config = $test->configuration->id;
                js_handlers {
                    onclick => "pubsub.send({type:'jifty.action',class:'Test',arguments:{commit:'$sha\[$config]'}})"
                };
                outs_raw "&nbsp;";
            } if Jifty->web->current_user->id;
            hyperlink(
                class   => "okbox $status",
                label   => "&nbsp;",
                escape_label => 0,
                url     => "/test/".$test->commit->sha."/".$test->configuration->name,
                tooltip => $msg,
            );
            hyperlink(
                tooltip => $msg,
                class   => "sha",
                url     => "/test/".$test->commit->sha."/".$test->configuration->name,
                label   => $test->commit->short_sha,
            );
        }
        my $branchname = $test->branch_name;
        $branchname = $test->project->name.":$branchname"
            if $opts{show_project};
        outs( " on $branchname using ".$test->configuration->name );
    }
};


1;
