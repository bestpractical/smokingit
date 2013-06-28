use strict;
use warnings;

package Smokingit::View::Commit;
use Jifty::View::Declare -base;

template '/commit' => page {
    redirect '/' unless get('commit');
    page_title is get('commit')->short_sha;

    my $commit = get('commit');

    ul {
        my $configs = $b->project->configurations;
        while (my $config = $configs->next) {
            li {
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

};

1;

