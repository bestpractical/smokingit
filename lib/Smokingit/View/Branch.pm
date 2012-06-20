use strict;
use warnings;

package Smokingit::View::Branch;
use Jifty::View::Declare -base;

template '/branch' => page {
    my $b = get('branch');
    redirect '/' unless $b;
    page_title is $b->name;
    div {
        { class is "subtitle" }
        hyperlink(
            label => $b->project->name,
            url => "/project/".$b->project->name."/",
        );
    };

    render_region(
        name => "properties",
        path => "/fragments/branch/properties",
        defaults => { branch_id => $b->id },
    );

    div { { class is "hline" } };

    my $configs = $b->project->configurations;
    my $x = 0;
    my @configs;
    if ($configs->count > 1) {
        div {
            { id is "branch-title" }
            while (my $c = $configs->next) {
                push @configs, $c;
                div {
                    attr { style => "padding-left: ".($x++*32)."px" };
                    $c->name
                }
            }
        }
    } else {
        @configs = ($configs->next);
    }

    my $project_id = $b->project->id;
    my @commits = $b->commit_list;
    my $branchpoint = $b->branchpoint(@commits+1);
    div {
        id is "branch-commits";
        class is "commitlist biglist";
        for my $commit (@commits) {
            $commit->hash_results;
            my $merge = $commit->subject =~ /^Merge branch /
                ? "merge" : "nonmerge";
            div {
                {class is $commit->sha." $merge commit ".$commit->status};
                for my $config (@configs) {
                    my ($status, $msg, $in) = $commit->status($config);
                    if ($status =~ /^(untested|testing|queued)$/) {
                        span {
                            attr { class => "okbox $status config-".$config->id, title => $msg };
                            outs_raw($in ||"&nbsp;")
                        };
                    } else {
                        hyperlink(
                            class => "okbox $status config-".$config->id,
                            label => "&nbsp;",
                            escape_label => 0,
                            url   => "/test/".$commit->sha."/".$config->name,
                            tooltip => $msg,
                        );
                    }
                }
                if ($commit->status =~ /^(untested|testing|queued)$/) {
                    span {
                        { class is "sha" };
                        $commit->short_sha
                    }
                } else {
                    hyperlink(
                        tooltip => $commit->long_status,
                        class => "sha",
                        url => "/test/".$commit->sha."/",
                        label => $commit->short_sha,
                    );
                }
                span {{class is "subject"} $commit->subject };
            };
            if ($branchpoint and $branchpoint->id == $commit->id) {
                div { { class is "branchpoint" } };
            }
        }
    };
};

template '/fragments/branch/properties' => sub {
    my $b = Smokingit::Model::Branch->new;
    $b->load( get('branch_id') );
    table {
        { id is "branch-properties" };
        js_handlers {
            onclick => {replace_with => "/fragments/branch/edit" }
        } if $b->current_user_can("update");

        row {
            th { "Status" };
            cell {
                span { {class is "status"} $b->display_status };
                if ($b->status ne "master") {
                    if (not $b->last_status_update->id
                            or $b->current_commit->id != $b->last_status_update->id) {
                        span { {class is "updated"} "(Needs update)"}
                    }
                }
            };
        };

        if ($b->status ne "master") {
            row {
                th { "Owner" };
                cell { $b->owner };
            };
        }

        if ($b->status ne "master" and $b->status ne "releng") {
            row {
                th { "Merge into" };
                cell { $b->to_merge_into->id ? $b->to_merge_into->name : "None" };
            };
        }

        if ($b->is_under_review) {
            row {
                th { "Review by" };
                cell { $b->review_by };
            };
        }
    };
    div {
        js_handlers {
            onclick => {replace_with => "/fragments/branch/edit" }
        };
        id is "long-status";
        class is $b->status;
        outs_raw( $b->long_status_html );
    };
};

template '/fragments/branch/edit' => sub {
    my $b = Smokingit::Model::Branch->new;
    $b->load( get('branch_id') );

    redirect "/fragments/branch/properties"
        unless $b->current_user_can("update");

    my $status = $b->status;
    form {
        my $update = $b->as_update_action( moniker => "update" );
        render_hidden( $update => last_status_update => $b->current_commit->id );
        table {
            { id is "branch-properties"; class is $status };

            row {
                th { "Status" };
                cell { render_param(
                    $update => "status",
                    label => "",
                    onchange => "narrow(this)"
                ) };
            };

            row { { class is "owner" };
                th { "Owner" };
                cell { render_param( $update => "owner", label => "" ) };
            };

            row { { class is "to_merge_into" };
                th { "Merge into" };
                cell { render_param( $update => "to_merge_into", label => "" ) };
            };

            row { { class is "review_by" };
                th { "Review by" };
                cell { render_param( $update => "review_by", label => "") };
            };
        };
        div {
            { id is "long-status" };
            render_param( $update => "long_status", label => "")
        };
        div {
            { id is "branch-buttons" };
            form_submit(
                class => "branch-save-button",
                label => "Save",
                onclick => {
                    submit => $update,
                    replace_with => "/fragments/branch/properties",
                }
            );
            form_submit(
                class => "branch-cancel-button",
                label => "Cancel",
                submit => [],
                onclick => {
                    replace_with => "/fragments/branch/properties",
                }
            );
        };
    };
};

1;
