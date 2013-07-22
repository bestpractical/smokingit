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

    require TAP::Parser;
    require TAP::Parser::Aggregator;

    # We use low-level DBI calls to speed up the creation
    my $table = Smokingit::Model::SmokeFileResultCollection->new( current_user => $super )->table;
    my $sth = Jifty->handle->dbh->prepare(
        "INSERT INTO $table (smoke_result_id, filename, elapsed, is_ok, tests_run, raw_tap) "
        ."VALUES (?,?,?,?,?,?)"
    );

    # Go through and inflate all of the old aggregators into test result
    # rows; do this in batches of 100, to save on memory.
    my $max = 0;
    do {
        my $tests = Smokingit::Model::SmokeResultCollection->new( current_user => $super );
        $tests->limit( column => "id", operator => ">", value => $max );
        $tests->order_by( { column => "id", order  => "asc" } );
        $tests->rows_per_page(100);
        $tests->columns( "id", "aggregator" );
        $max = 0;
        while (my $test = $tests->next) {
            $max = $test->id;
            warn "$max\n";
            my $aggregator = $test->_value('aggregator');
            next unless $aggregator;
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

                $sth->execute(
                    $test->id,
                    $filename,
                    ($parser->end_time - $parser->start_time),
                    ($parser->has_problems ? 'f' : 't'),
                    $parser->tests_run,
                    $tap,
                );
            }
        }
    } while ($max);
};

1;
