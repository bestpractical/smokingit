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

    on 'new-configuration' => run { show '/new-configuration'; },
    on 'cooking.txt'       => run { show '/cooking.txt'; },
];

# Commits and test commits
under '/test/*' => [
    run {
        my $sha = $1;
        if (length($sha) == 40) {
            my $commit = Smokingit::Model::Commit->new;
            $commit->load_by_cols( sha => $sha );
            show '/errors/404' unless $commit->id;
            set( commit => $commit );
        } else {
            my $commits = Smokingit::Model::CommitCollection->new;
            $commits->limit( column => 'sha', operator => 'like', value => "$sha%" );
            show '/errors/404' unless $commits->count == 1;
            set( commit => $commits->first );
        }
    },
    on '' => run {
        my $configs = Smokingit::Model::ConfigurationCollection->new;
        $configs->limit( column => "project_id", value => get('commit')->project_id );
        redirect '/test/' . get('commit')->sha . '/' . $configs->first->name
            if $configs->count == 1;
        show '/commit';
    },
    on '*' => run {
        my $cname = $1;
        my $config = Smokingit::Model::Configuration->new;
        $config->load_by_cols(
            project_id => get('commit')->project,
            name => $cname,
        );
        show '/errors/404' unless $config->id;

        my $result = Smokingit::Model::SmokeResult->new;
        $result->load_by_cols(
            project_id => get('commit')->project,
            commit_id => get('commit')->id,
            configuration_id => $config->id,
        );
        set( smoke => $result );
        show '/smoke';
    },
];

# GitHub post-receive-hook support
on '/github' => run {
    show '/github';
};

# Shortcut URLs, of /projectname and /projectname/branchname and /sha
under '/*' => [
    run {
        my $name = $1;
        my $project = Smokingit::Model::Project->new;
        $project->load_by_cols( name => $name );
        if ($project->id) {
            set project => $project;
            return;
        }

        return unless $name =~ /^[A-Fa-f0-9]+$/;
        my $commits = Smokingit::Model::CommitCollection->new;
        $commits->limit( column => 'sha', operator => 'STARTSWITH', value => lc($name) );
        redirect '/test/' . $commits->first->sha
            if $commits->count == 1;
    },
    on '' => run {
        redirect '/project/'.get('project')->name.'/' if get('project');
    },
    on '**' => run {
        my $bname = $1;
        return unless get('project');
        my $branch = Smokingit::Model::Branch->new;
        $bname =~ s{/+}{/}g;
        $bname =~ s{/$}{};
        $branch->load_by_cols( name => $bname, project_id => get('project')->id );
        redirect '/project/' . get('project')->name . '/branch/' . $branch->name
            if $branch->id;
    },
];

1;
