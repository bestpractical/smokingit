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
            id is "recent-tests";
            class is "commitlist";
            h2 { "Recent tests" };
            my $tests = Smokingit::Model::SmokeResultCollection->new;
            $tests->limit(
                column => "gearman_process",
                operator => "IS",
                value => "NULL"
            );
            $tests->limit( column => "project_id", value => get('project')->id );
            $tests->order_by( { column => "submitted_at", order  => "desc" },
                              { column => "id",           order  => "desc" } );
            $tests->rows_per_page(10);
            while (my $test = $tests->next) {
                my ($status, $msg) = $test->commit->status($test->configuration);
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
                    outs( $test->configuration->name );
                }
            }
        };

        my @planned = get('project')->planned_tests;
        if (@planned) {
            div {
                id is "planned-tests";
                class is "commitlist";
                h2 { "Planned tests" };
                for my $test (@planned) {
                    my ($status, $msg) = $test->commit->status($test->configuration);
                    div {
                        class is "commit $status";
                        span {
                            attr { class => "okbox $status", title => $msg };
                            outs_raw("&nbsp;")
                        };
                        span {
                            attr { class => "sha", title => $msg };
                            $test->commit->short_sha
                        };
                        outs( $test->configuration->name );
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
        $branches->order_by( column => "name" );
        ul {
            while (my $b = $branches->next) {
                li {
                    hyperlink(
                        label => $b->name,
                        url => "branch/" . $b->name,
                    );
                    my $sub = Smokingit::Model::BranchCollection->new;
                    $sub->limit( column => "project_id", value => get('project_id') );
                    $sub->limit( column => "status", operator => "!=", value => "ignore", entry_aggregator => "AND");
                    $sub->limit( column => "status", operator => "!=", value => "master", entry_aggregator => "AND");
                    $sub->limit( column => "to_merge_into", value => $b->id );
                    branchlist($sub);
                };
            }
        };

        $branches->unlimit;
        $branches->limit( column => "project_id", value => get('project_id') );
        $branches->limit( column => "to_merge_into", operator => "IS", value => "NULL" );
        $branches->limit( column => "status", operator => "!=", value => "ignore", entry_aggregator => "AND" );
        $branches->limit( column => "status", operator => "!=", value => "master", entry_aggregator => "AND" );
        branchlist($branches, 1);

        $branches->unlimit;
        $branches->limit( column => "project_id", value => get('project_id') );
        $branches->limit( column => "status", operator => "=", value => "ignore" );
        branchlist($branches, 1);
    };
};

sub branchlist {
    my ($branches, $hline) = @_;
    $branches->order_by( column => "name" );
    if ($branches->count) {
        if ($hline) {
            div { { class is "hline" } }
        }
        ul {
            while (my $b = $branches->next) {
                li {
                    hyperlink(
                        label => $b->name,
                        url => "branch/" . $b->name,
                    );
                }
            }
        }
    }
}

1;