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

1;
