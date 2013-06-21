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

1;
