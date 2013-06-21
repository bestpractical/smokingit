use strict;
use warnings;

package Smokingit::View::Commit;
use Jifty::View::Declare -base;

template '/commit' => page {
    redirect '/' unless get('commit');
    page_title is get('commit')->short_sha;
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

