use strict;
use warnings;

package Smokingit::Model::Configuration;
use Jifty::DBI::Schema;

use Smokingit::Record schema {
    column project_id =>
        references Smokingit::Model::Project;

    column name =>
        is mandatory,
        label is "Name",
        type is "text";

    column configure_cmd =>
        type is 'text',
        label is "Configuration commands",
        default is 'perl Makefile.PL && make',
        render_as 'Textarea';

    column env =>
        type is 'text',
        label is "Environment variables",
        render_as 'Textarea';

    column test_glob =>
        type is 'text',
        label is 'Glob of test files',
        default is "t/*.t";

    column parallel =>
        is boolean,
        label is 'Parallel testing?',
        default is 't';
};

sub create {
    my $self = shift;
    my ($ok, $msg) = $self->SUPER::create(@_);
    return ($ok, $msg) unless $ok;

    Smokingit->gearman->dispatch_background(
        sync_project => $self->project->name,
    );

    return ($ok, $msg);
}

1;

