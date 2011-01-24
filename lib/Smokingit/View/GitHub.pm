use strict;
use warnings;

package Smokingit::View::GitHub;
use Jifty::View::Declare -base;


template '/github' => sub {
    outs("OK");
};

template '/github/error' => sub {
    outs("Error!");
};

1;
