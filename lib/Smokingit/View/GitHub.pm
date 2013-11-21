use strict;
use warnings;

package Smokingit::View::GitHub;
use Jifty::View::Declare -base;

use Jifty::JSON qw/decode_json/;

template '/github' => sub {
    my $ret = eval {
        die "Wrong method\n" unless Jifty->web->request->method eq "POST";
        die "No payload\n"   unless get('payload');
        my $json = eval { decode_json(get('payload')) }
            or die "Bad JSON: $@\n" . get('payload');

        my $name = $json->{repository}{name}
            or die "No repository name found\n";
        my $project = Smokingit::Model::Project->new;
        $project->load_by_cols( name => $name );
        $project->id
            or return "No such project: $name\n";

        my $bname = $json->{ref}
            or die "No branch ref found\n";
        $bname =~ s{^refs/heads/}{}
            or die "Branch $bname not under /ref/heads/\n";
        my $branch = Smokingit::Model::Branch->new;
        $branch->load_by_cols( project_id => $project->id, name => $bname );

        if ($json->{before} ne "0"x40) {
            $branch->id
                or return "No such branch\n";
            $branch->is_tested
                or return "Branch is not currently tested\n";
        }

        Jifty->rpc->call(
            name => "sync_project",
            args => $project->name,
        );
        return undef;
    };
    if ($@) {
        warn "Failed to sync: $@";
        outs "ERROR: $@"
    } elsif ($ret) {
        outs "Ignored: $ret";
    } else {
        outs "OK!\n";
    }
};

1;
