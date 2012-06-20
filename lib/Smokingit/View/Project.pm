use strict;
use warnings;

package Smokingit::View::Project;
use Jifty::View::Declare -base;

template '/project' => page {
    redirect '/' unless get('project');

    Jifty->subs->add( topic => $_ )
        for qw/ test_progress commit_status /;

    page_title is get('project')->name;
    div {{class is "subtitle"} get('project')->repository_url };

    render_region(
        name => "branches",
        path => "/fragments/project/branch-list",
        defaults => { project_id => get('project')->id },
    );

    div {
        id is "right-bar";
        div {
            id is "configuration-list";
            h2 { "Configurations" };
            my $configs = get('project')->configurations;
            ul {
                while (my $c = $configs->next) {
                    li {
                        if ($c->current_user_can("update")) {
                            hyperlink(
                                label => $c->name,
                                url => "config/" . $c->name
                            );
                        } else {
                            outs $c->name;
                        }
                    };
                }
            };
            my $config = Smokingit::Model::Configuration->new;
            hyperlink(
                label => "New configuration",
                url => "new-configuration",
            ) if $config->current_user_can("create");
        };

        div {
            id is "feeds";
            h2 { "Feeds" };
            ul {
                li {
                    hyperlink(
                        label => "What's Cooking",
                        url   => "cooking.txt",
                    );
                };
            };
        };

        render_region(
            name => "finished",
            path => "/fragments/project/finished",
            defaults => { project_id => get('project')->id },
        );

        render_region(
            name => "planned",
            path => "/fragments/project/planned",
            defaults => { project_id => get('project')->id },
        );
    };
};

template '/fragments/project/finished' => sub {
    my $project = Smokingit::Model::Project->new;
    $project->load( get('project_id') );

    my $tests = $project->finished_tests;
    $tests->rows_per_page(10);
    div {
        id is "recent-tests";
        h2 { "Recent tests" };
        span {
            class is "commitlist";
            test_result($_) while $_ = $tests->next;
        };
    };
    Jifty->subs->update_on( topic => "test_queued" );
    Jifty->subs->update_on( topic => "test_result" );
};

template '/fragments/project/planned' => sub {
    my $project = Smokingit::Model::Project->new;
    $project->load( get('project_id') );

    my $planned = $project->planned_tests;
    div {
        id is "planned-tests";
        h2 { "Planned tests" };
        span {
            class is "commitlist";
            test_result($_) while $_ = $planned->next;
        };
    };
    Jifty->subs->update_on( topic => "test_queued" );
    Jifty->subs->update_on( topic => "test_result" );
};

sub test_result {
    my $test = shift;
    my ($status, $msg, $in) = $test->commit->status($test);
    div {
        class is $test->commit->sha." config-".$test->configuration->id." commit $status";
        if ($status =~ /^(untested|queued|testing|broken)$/) {
            span {
                attr { class => "okbox $status config-".$test->configuration->id, title => $msg };
                outs_raw($in || "&nbsp;")
            };
            span {
                attr { class => "sha", title => $msg };
                $test->commit->short_sha
            };
        } else {
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
        outs( " on ".$test->branch_name. " using ".$test->configuration->name );
    }
};

template '/fragments/project/branch-list' => sub {
    div {
        id is "branch-list";
        h2 { "Branches" };
        my $branches = Smokingit::Model::BranchCollection->new;
        $branches->limit( column => "project_id", value => get('project_id') );
        unless ($branches->count) {
            hyperlink(
                class => "no-branches",
                label => "Repository is still loading...",
                onclick => { refresh_self => 1 },
            );
            return;
        }

        $branches->limit( column => "status", value => "master" );
        branchlist($branches, recurse => 1);

        $branches->unlimit;
        $branches->limit( column => "project_id", value => get('project_id') );
        $branches->limit( column => "to_merge_into", operator => "IS", value => "NULL" );
        $branches->limit( column => "status", operator => "!=", value => "ignore", entry_aggregator => "AND" );
        $branches->limit( column => "status", operator => "!=", value => "master", entry_aggregator => "AND" );
        branchlist($branches, hline => 1);

        $branches->unlimit;
        $branches->limit( column => "project_id", value => get('project_id') );
        $branches->limit( column => "status", operator => "=", value => "ignore" );
        branchlist($branches, hline => 1);
    };
};

sub branchlist {
    my ($branches, %args) = @_;
    if ($branches->count) {
        $branches->prefetch( name => "current_commit" );
        my $results = $branches->join(
            type    => "left",
            alias1  => "main",
            column1 => "current_commit_id",
            table2  => "smoke_results",
            column2 => "commit_id",
            is_distinct => 1,
        );
        $branches->limit(
            leftjoin => $results,
            column   => "project_id",
            value    => get('project_id'),
        );
        $branches->prefetch(
            name    => "smoke_results",
            alias   => $results,
            class   => "Smokingit::Model::SmokeResultCollection",
            columns => [qw/id queue_status configuration_id
                           error is_ok exit wait
                           passed failed parse_errors todo_passed/],
        );
        my @order = ({ column   => "name" });
        if (Jifty->web->current_user->id) {
            my $actor = '%<'.Jifty->web->current_user->user_object->email.'>';
            $actor = Jifty->handle->quote_value($actor);
            unshift @order, { function => "main.current_actor like $actor", order => 'DESC' };
        }
        $branches->order_by( @order );
        div { class is "hline"; }
            if $args{hline};
        ul {
            while (my $b = $branches->next) {
                $b->current_commit->hash_results( $b->prefetched("smoke_results") );
                li {
                    { class is $b->test_status . " " . $b->current_commit->sha; }
                    hyperlink(
                        label => $b->name . " (" . $b->format_user('current_actor') . ")",
                        url => "branch/" . $b->name,
                    );
                    branchlist($b->branches, %args)
                        if $args{recurse};
                };
            }
        }
    }
}

use Text::Wrap qw//;
template '/cooking.txt' => sub {
    redirect '/' unless get('project');
    Jifty->web->response->content_type("text/plain");
    my $out = "";
    $out .= "What's cooking in ".get('project')->name . ".git\n";
    $out .= ("-" x (length($out) - 1)) . "\n\n";

    my $trunks = get('project')->trunk_or_relengs;
    while (my $t = $trunks->next) {
        $out .= $t->name." - " . $t->current_commit->long_status . "\n";
        $out .= Text::Wrap::wrap(" "x 4," "x 4,$t->long_status)."\n\n"
            if $t->long_status;

        my $sub = $t->branches;
        $sub->limit( column => "status", operator => "!=", value => "releng", entry_aggregator => "AND");
        $sub->order_by(
            { function => "status = 'releng'", order => "desc"},
            { column   => "current_actor" },
            { column   => "name" },
        );
        while ($b = $sub->next) {
            $out .= " "x 4
                . $b->name." - " . $b->current_commit->long_status
                . "\n";

            $out .= " "x 6 . "[ "
                . $b->display_status ." by ". ($b->current_actor || 'someone')
                . " ]\n";

            $out .= Text::Wrap::wrap(" "x 8," "x 8,$b->long_status)."\n"
                if $b->long_status;
            $out .=  "\n";
        }
        $out .= "\n" if not $t->long_status and not $sub->count;
    }
    outs_raw( $out );
};

1;
