use strict;
use warnings;

package Smokingit::View::Configuration;
use Jifty::View::Declare -base;

template '/config' => page {
    my $c = get('config');
    redirect '/' unless $c;
    page_title is $c->name;
    div {{class is "subtitle"} $c->project->name };
    form {
        my $config = new_action(
            class => "UpdateConfiguration",
            moniker => "update-configuration",
            record => $c,
        );
        my $update = new_action(
            class => "UpdateProject",
            moniker => "update-project",
            record => get('project'),
        );
        render_param( $config => "name" );
        render_param( $config => "configure_cmd" );
        render_param( $config => "env" );

        render_param( $update => "test_glob" );
        render_param( $update => "parallel" );
        form_submit( label => _("Update"), url => "/project/". $c->project->name . "/");
    };
};

template '/new-configuration' => page {
    redirect '/' unless get('project');
    page_title is get('project')->name;
    div {{class is "subtitle"} "New configuration" };
    form {
        my $create = new_action(
            class => "CreateConfiguration",
            moniker => "create-configuration",
        );
        my $name = get('project')->configurations->count ? "" : "Default";
        render_hidden( $create => "project_id" => get('project')->id );
        render_param( $create => "name", default_value => $name );
        render_param( $create => "configure_cmd" );
        render_param( $create => "env" );
        render_param( $create => "test_glob" );
        render_param( $create => "parallel" );
        form_submit( label => _("Create"), url => "/project/" . get('project')->name . "/" );
    };
};

1;
