use strict;
use warnings;

package Smokingit::View::Commit;
use Jifty::View::Declare -base;

template '/commit' => page {
    redirect '/' unless get('commit');
    page_title is get('commit')->short_sha;

    my $commit = get('commit');

    span {
        class is "commitlist";
        my $configs = $commit->project->configurations;
        while (my $config = $configs->next) {
            my $smoke = Smokingit::Model::SmokeResult->new;
            $smoke->load_by_cols(
                project_id       => $commit->project->id,
                configuration_id => $config->id,
                commit_id        => $commit->id,
            );
            next unless $smoke->id;
            Smokingit::View::test_result( $smoke );
        }
    }
};

template '/smoke' => page {
    my $s = get('smoke');
    redirect '/' unless $s;
    class is (($s->is_ok ? "passing" : "failing")."test");
    page_title is $s->commit->short_sha . ", ". $s->configuration->name;

    if ($s->error) {
        pre { $s->error };
        return;
    }

    my $results = Smokingit::Model::SmokeFileResultCollection->new;
    $results->limit( column => "smoke_result_id", value => $s->id );
    $results->order_by( { column => "is_ok" }, { column => "filename" } );
    $results->columns( "id", "filename", "is_ok", "elapsed" );
    while (my $result = $results->next) {
        div {
            class is ($result->is_ok ? "passingfile" : "failingfile");
            outs $result->filename;
            span {
                class is "elapsed";
                outs sprintf "(%.2fs)", $result->elapsed;
            };
            unless ($result->is_ok) {
                pre { $result->raw_tap };
            }
        };
    }
};

1;

