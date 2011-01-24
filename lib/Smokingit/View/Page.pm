use strict;
use warnings;

package Smokingit::View::Page;

use base qw(Jifty::Plugin::ViewDeclarePage::Page);
use Jifty::View::Declare::Helpers;

sub render_page {
    my $self = shift;
    my $title = shift;
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
        h1 { attr { class => 'header' }; hyperlink( url => $url, label => $title) };
    }

    Jifty->web->render_messages;

    return '';
}

1;
