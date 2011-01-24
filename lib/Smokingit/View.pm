use strict;
use warnings;

package Smokingit::View;
use Jifty::View::Declare -base;

require Smokingit::View::Project;
alias Smokingit::View::Project under '/';

require Smokingit::View::Branch;
alias Smokingit::View::Branch under '/';

require Smokingit::View::Configuration;
alias Smokingit::View::Configuration under '/';

require Smokingit::View::GitHub;
alias Smokingit::View::GitHub under '/';

template '/index.html' => page {
    page_title is 'Projects';
    my $projects = Smokingit::Model::ProjectCollection->new;
    $projects->unlimit;
    if ($projects->count) {
        h2 { "Existing projects" };
        ul {
            while (my $p = $projects->next) {
                li {
                    hyperlink(
                        label => $p->name,
                        url => "/project/".$p->name."/",
                    );
                }
            }
        };
    }

    div {
        { id is "create-project"; };
        h2 { "Add a project" };
        form {
            my $create = new_action(
                class => "CreateProject",
                moniker => "create-project",
            );
            render_param( $create => 'name' );
            render_param( $create => 'repository_url' );
            form_submit( label => _("Create") );
        };
    };
};

1;
