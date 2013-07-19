use warnings;
use strict;

package Smokingit::Upgrade;

use Jifty::Upgrade;
use base qw/Jifty::Upgrade/;

my $super = Smokingit::CurrentUser->superuser;

# Added the concept of the current actor on the branch -- either the
# reviewer, if the branch is under review, otherwise the owner.  Go
# through and force this column to update for each outstanding branch.
since '0.0.3' => sub {
    my $branches = Smokingit::Model::BranchCollection->new( current_user => $super );
    $branches->unlimit;
    while (my $branch = $branches->next) {
        $branch->update_current_actor;
    }
};

# The branch name became a fixed part of the smoke test, and not a
# reference to the branch id; thus, when branches are removed, the smoke
# result still knows what branch it was on originally.
since '0.0.4' => sub {
    my $tests = Smokingit::Model::SmokeResultCollection->new( current_user => $super );
    $tests->unlimit;
    $tests->columns( "id" );
    $tests->prefetch( name => "from_branch" );
    my %branches;
    while (my $test = $tests->next) {
        my $branch = $test->prefetched( "from_branch" );
        $test->set_branch_name($branch->name);
    }
};

since '0.0.8' => sub {
    # Time elapsed became a float
    Jifty->handle->simple_query("ALTER TABLE smoke_results ALTER COLUMN elapsed TYPE float");

    # Go through and inflate all of the old aggregators into test result rows
    my $tests = Smokingit::Model::SmokeResultCollection->new( current_user => $super );
    $tests->unlimit;
    $tests->columns( "id", "aggregator" );
    require TAP::Parser;
    require TAP::Parser::Aggregator;
    while (my $test = $tests->next) {
        my $aggregator = $test->_value('aggregator');
        for my $filename ($aggregator->descriptions) {
            my ($parser) = $aggregator->parsers($filename);

            my $tap = "";
            if ($parser->skip_all) {
                $tap = "1..0 # skipped\n";
            } else {
                $tap = $parser->plan . "\n";
                my %lines;
                $lines{$_}   = "ok $_ # skip" for $parser->skipped;
                $lines{$_} ||= "ok $_ # TODO" for $parser->todo_passed;
                $lines{$_} ||= "not ok $_ # TODO" for $parser->todo;
                $lines{$_} ||= "ok $_" for $parser->actual_passed;
                $lines{$_} ||= "not ok $_" for $parser->actual_failed;
                $tap .= "$lines{$_}\n" for sort {$a <=> $b} keys %lines;
            }

            my $filetest = Smokingit::Model::SmokeFileResult->new( current_user => $super );
            $filetest->create(
                smoke_result_id => $test->id,
                filename        => $filename,
                elapsed         => ($parser->end_time - $parser->start_time),
                is_ok           => !$parser->has_problems,
                tests_run       => $parser->tests_run,
                raw_tap         => $tap,
            );
        }
    }
};

1;
