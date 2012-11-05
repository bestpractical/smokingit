use strict;
use warnings;

package Smokingit::View::Configuration;
use Jifty::View::Declare -base;

template '/config' => page {
    my $c = get('config');
    redirect '/' unless $c;

    redirect "/project/". $c->project->name . "/"
        unless $c->current_user_can("update");

    page_title is $c->name;
    div {{class is "subtitle"} $c->project->name };
    form {
        my $update = new_action(
            class => "UpdateConfiguration",
            moniker => "update-configuration",
            record => $c,
        );
        render_param( $update => "name" );
        render_param( $update => "configure_cmd" );
        render_param( $update => "env" );
        render_param( $update => "test_glob" );
        render_param( $update => "parallel" );
        form_submit( label => _("Update"), url => "/project/". $c->project->name . "/");
    };
};

template '/new-configuration' => page {
    redirect '/' unless get('project');

    my $config = Smokingit::Model::Configuration->new;
    redirect "/project/". get('project')->name . "/"
        unless $config->current_user_can("create");

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
