use strict;
use warnings;

package Smokingit::Dispatcher;
use Jifty::Dispatcher -base;

# Auto redirect after create, to the project
on '' => run {
    my $res = Jifty->web->response->result('create-project');
    return unless $res and $res->content('id');
    my $project = Smokingit::Model::Project->new;
    $project->load( $res->content('id') );
    redirect '/project/' . $project->name . "/";
};

under '/project/*' => [
    run {
        my $project = Smokingit::Model::Project->new;
        $project->load_by_cols( name => $1 );
        show '/errors/404' unless $project->id;
        set project => $project;
    },

    on '' => run {
        my $project = get('project');
        if ($project->configurations->count) {
            show '/project';
        } else {
            show '/new-configuration';
        }
    },

    on 'branch/**' => run {
        my $name = $1;
        $name =~ s{/+}{/}g;
        $name =~ s{/$}{};
        my $branch = Smokingit::Model::Branch->new;
        $branch->load_by_cols(
            name => $name,
            project_id => get('project')->id,
        );
        show '/errors/404' unless $branch->id;
        set branch => $branch;
        show '/branch';
    },

    on 'config/**' => run {
        my $name = $1;
        $name =~ s{/+}{/}g;
        $name =~ s{/$}{};
        my $config = Smokingit::Model::Configuration->new;
        $config->load_by_cols(
            name => $name,
            project_id => get('project')->id,
        );
        show '/errors/404' unless $config->id;
        set config => $config;
        show '/config';
    },

    on 'new-configuration' => run {
        show '/new-configuration';
    },
];

# Shortcut URLs, of /projectname/branchname
on '/*/**' => run {
    my ($pname, $bname) = ($1, $2);
    my $project = Smokingit::Model::Project->new;
    $project->load_by_cols( name => $pname );
    return unless $project->id;

    my $branch = Smokingit::Model::Branch->new;
    $bname =~ s{/+}{/}g;
    $bname =~ s{/$}{};
    $branch->load_by_cols( name => $bname, project_id => $project->id );
    return unless $branch->id;

    redirect '/project/' . $project->name . '/branch/' . $branch->name;
};


# GitHub post-receive-hook support
on '/github' => run {
    show '/github';
};

1;
