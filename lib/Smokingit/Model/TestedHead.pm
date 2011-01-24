use strict;
use warnings;

package Smokingit::Model::TestedHead;
use Jifty::DBI::Schema;

use Smokingit::Record schema {
    column project_id =>
        is mandatory,
        references Smokingit::Model::Project;

    column configuration_id =>
        is mandatory,
        references Smokingit::Model::Configuration;

    column commit_id =>
        is mandatory,
        references Smokingit::Model::Commit;
};

sub smoke_result {
    my $self = shift;
    my $result = Smokingit::Model::SmokeResult->new;
    $result->load_by_cols(
        project_id       => $self->project->id,
        configuration_id => $self->configuration->id,
        commit_id        => $self->commit->id,
    );
    return $result;
}

1;

