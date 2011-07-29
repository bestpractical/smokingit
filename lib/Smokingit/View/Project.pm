use strict;
use warnings;

package Smokingit::View::Project;
use Jifty::View::Declare -base;

template '/project' => page {
    redirect '/' unless get('project');
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
                        hyperlink(
                            label => $c->name,
                            url => "config/" . $c->name,
                        );
                    };
                }
            };
            hyperlink(
                label => "New configuration",
                url => "new-configuration",
            );
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

        my $tests = Smokingit::Model::SmokeResultCollection->new;
        $tests->limit(
            column => "gearman_process",
            operator => "IS",
            value => "NULL"
        );
        $tests->limit( column => "project_id", value => get('project')->id );
        $tests->prefetch( name => "commit" );
        $tests->order_by( { column => "submitted_at", order  => "desc" },
                          { column => "id",           order  => "desc" } );
        $tests->rows_per_page(10);
        if ($tests->count) {
            div {
                id is "recent-tests";
                class is "commitlist";
                h2 { "Recent tests" };
                while (my $test = $tests->next) {
                    my ($status, $msg) = $test->commit->status($test);
                    div {
                        class is "commit $status";
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
                        outs( " on ".($test->from_branch->name || "?") . " using ".$test->configuration->name );
                    }
                }
            };
        }

        my @planned = get('project')->planned_tests;
        if (@planned) {
            div {
                id is "planned-tests";
                class is "commitlist";
                h2 { "Planned tests" };
                for my $test (@planned) {
                    my ($status, $msg, $in) = $test->commit->status($test);
                    div {
                        class is "commit $status";
                        span {
                            attr { class => "okbox $status", title => $msg };
                            outs_raw($in || "&nbsp;")
                        };
                        span {
                            attr { class => "sha", title => $msg };
                            $test->commit->short_sha
                        };
                        outs( " on ".$test->from_branch->name . " using ".$test->configuration->name );
                    }
                }
            }
        }
    };
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
    $branches->order_by( column => "name" );
    if ($branches->count) {
        div { class is "hline"; }
            if $args{hline};
        ul {
            while (my $b = $branches->next) {
                li {
                    { class is $b->test_status; }
                    hyperlink(
                        label => $b->name,
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
