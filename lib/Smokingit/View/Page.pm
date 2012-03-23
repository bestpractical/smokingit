use strict;
use warnings;

package Smokingit::View::Page;

use base qw(Jifty::Plugin::ViewDeclarePage::Page);
use Jifty::View::Declare::Helpers;

sub render_page {
    my $self = shift;
    my $title = shift;

    div {
        { id is 'authbox' };
        if (Jifty->web->current_user->id) {
            div {
                { class is 'username' };
                js_handlers {
                    onclick => "jQuery('#authbox .logout').toggle()" };
                outs(Jifty->web->current_user->username);
                div {
                    { class is 'logout' };
                    form {
                        my $logout = new_action(
                            class => "Logout",
                            moniker => "logout"
                        );
                        form_submit( submit => $logout, label => "Log out" );
                    }
                }
            }
        } else {
            div {
                { class is 'prompt' };
                js_handlers {
                    onclick => [
                        "jQuery('#authbox .prompt').hide()",
                        "jQuery('#authbox .loginform').show()",
                        "jQuery('.loginform input.argument-username').focus()",
                    ],
                };
                "Login";
            };
            div {
                { class is 'loginform' };
                form {
                    my $login = new_action(
                        class => "Login",
                        moniker => "login",
                    );
                    render_param( $login => $_ )
                        for qw/username password token hashed_password/;
                    render_param(
                        $login => "remember",
                        render_as => 'hidden',
                        default_value => 1
                    );
                    form_submit( label => "Login", onclick => "return getPasswordToken('login');" );
                };
            }
        }
    }

    div {
        { id is 'content' };
        $self->instrument_content;
        $self->render_jifty_page_detritus;
    };
    div { class is "clear" };
    div {
        { id is "footer"};
        div { {id is "corner"} };
    };
}

sub render_title_inhead {
    my ($self, $title) = @_;
    my @titles = (Jifty->config->framework('ApplicationName'), $title);
    title { join " - ", grep { defined and length } reverse @titles };
    return '';
}

sub render_title_inpage {
    my $self  = shift;
    my $title = shift;

    if ( $title ) {
        my $url = "/";
        $url = "/project/".get('project')->name."/" if get('branch');
        $url = "/project/".get('commit')->project->name."/" if get('commit');
        h1 {
            attr { class => 'header' };
            hyperlink( url => $url, label => $title)
        };
    }

    Jifty->web->render_messages;

    return '';
}

1;
